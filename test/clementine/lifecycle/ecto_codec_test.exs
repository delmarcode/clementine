defmodule Clementine.Lifecycle.Ecto.CodecTest do
  use ExUnit.Case, async: true

  alias Clementine.Lifecycle.Ecto.Codec
  alias Clementine.Lifecycle.Facts
  alias Clementine.LLM.Message.Content.{Text, ToolUse}
  alias Clementine.LLM.Message.{AssistantMessage, UserMessage}

  alias Clementine.{
    ApprovalRequest,
    Checkpoint,
    Error,
    InterruptReason,
    Pending,
    ResumeToken,
    Suspension,
    ToolResult,
    Usage
  }

  # The codec's promise is exactness *through jsonb*: every encode must
  # survive JSON serialization plus Postgres jsonb normalization, so we
  # round-trip through Jason in every assertion.
  defp jsonb_round_trip(encoded), do: encoded |> Jason.encode!() |> Jason.decode!()

  defp assert_exact(kind, value) do
    encoded = apply(Codec, :"encode_#{kind}", [value])
    assert apply(Codec, :"decode_#{kind}", [jsonb_round_trip(encoded)]) == value
  end

  describe "status" do
    test "round-trips every status" do
      for status <- Facts.statuses() do
        assert status |> Codec.encode_status() |> Codec.decode_status() == status
      end
    end

    test "rejects unknown atoms" do
      assert_raise ArgumentError, fn -> Codec.encode_status(:paused) end
    end
  end

  describe "kind" do
    test "round-trips every kind" do
      for kind <- Facts.kinds() do
        assert kind |> Codec.encode_kind() |> Codec.decode_kind() == kind
      end
    end

    test "rejects unknown atoms" do
      assert_raise ArgumentError, fn -> Codec.encode_kind(:cron) end
    end
  end

  describe "term codec" do
    test "JSON-exact values stay inspectable JSON" do
      for value <- ["text", 42, 1.5, true, nil, [1, "two"], %{"k" => [%{"n" => 1}]}] do
        encoded = Codec.encode_term(value)
        assert encoded["t"] == "json"
        assert Codec.decode_term(jsonb_round_trip(encoded)) == value
      end
    end

    test "atoms, tuples, and atom-keyed maps round-trip through ETF" do
      for value <- [:user_requested, {:policy, :budget}, %{by: 42}, [{:a, 1}], <<0xFF>>] do
        encoded = Codec.encode_term(value)
        assert encoded["t"] == "etf"
        assert Codec.decode_term(jsonb_round_trip(encoded)) == value
      end
    end

    test "decodes atoms not yet interned in this VM — a durable row must survive restarts" do
      # As after a restart/deploy: the writing VM interned this atom, the
      # reading VM has not. A :safe decode would raise here and make fetch
      # partial on the codec's own writes.
      name = "cancel_reason_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end

      etf = <<131, 119, byte_size(name), name::binary>>
      encoded = jsonb_round_trip(%{"t" => "etf", "v" => Base.encode64(etf)})

      assert encoded |> Codec.decode_term() |> Atom.to_string() == name
    end
  end

  describe "cancel" do
    test "round-trips reason terms and the requested_at stamp" do
      assert_exact(:cancel, %{
        reason: {:user, 42},
        requested_at: ~U[2026-07-05 12:00:00.123456Z]
      })

      assert Codec.encode_cancel(nil) == nil
      assert Codec.decode_cancel(nil) == nil
    end
  end

  describe "suspension" do
    test "round-trips an approval suspension with a full checkpoint" do
      checkpoint = %Checkpoint{
        rollout_id: "rollout-1",
        iteration: 3,
        messages: [
          UserMessage.new("delete the stale records"),
          %AssistantMessage{
            content: [
              %Text{text: "Deleting."},
              %ToolUse{id: "tu_1", name: "delete_records", input: %{"table" => "events"}}
            ]
          }
        ],
        pending: %Pending.ToolApproval{
          tool_use_id: "tu_1",
          tool_name: "delete_records",
          args: %{"table" => "events"},
          completed_results: %{
            "tu_0" => %ToolResult{content: "ok", is_error: false}
          }
        },
        usage: %Usage{input_tokens: 100, output_tokens: 25},
        cursor: {2, 17}
      }

      suspension = %Suspension{
        reason:
          {:approval,
           %ApprovalRequest{
             tool_use_id: "tu_1",
             tool_name: "delete_records",
             args: %{"table" => "events"}
           }},
        checkpoint: checkpoint,
        token: %ResumeToken{run_ref: 7, epoch: 2, reason_type: :approval}
      }

      assert_exact(:suspension, suspension)
    end

    test "round-trips :until and :external reasons" do
      checkpoint = %Checkpoint{rollout_id: "r", cursor: {1, 0}}
      token = %ResumeToken{run_ref: "run-9", epoch: 1, reason_type: :until}

      assert_exact(:suspension, %Suspension{
        reason: {:until, ~U[2026-07-06 09:00:00.000000Z]},
        checkpoint: checkpoint,
        token: token
      })

      assert_exact(:suspension, %Suspension{
        reason: {:external, {:webhook, "wh_1"}},
        checkpoint: checkpoint,
        token: %ResumeToken{token | reason_type: :external}
      })
    end

    test "keeps the raw envelope when the embedded checkpoint no longer decodes" do
      suspension = %Suspension{
        reason: {:external, :tag},
        checkpoint: %Checkpoint{rollout_id: "r"},
        token: %ResumeToken{run_ref: 1, epoch: 1, reason_type: :external}
      }

      encoded =
        suspension
        |> Codec.encode_suspension()
        |> put_in(["checkpoint", "version"], Checkpoint.version() + 1)
        |> jsonb_round_trip()

      decoded = Codec.decode_suspension(encoded)

      # fetch stays total: the run is still inspectable and cancellable, and
      # the resume path is where :incompatible_checkpoint surfaces.
      assert decoded.reason == {:external, :tag}
      assert decoded.token == suspension.token
      assert %{"version" => _} = decoded.checkpoint
    end
  end

  describe "resume" do
    test "round-trips the normative approval payloads" do
      for payload <- [{:approved, %{by: 42}}, {:denied, %{by: 7, message: "not in prod"}}] do
        assert_exact(:resume, %{payload: payload, resumed_at: ~U[2026-07-05 12:00:00.000001Z]})
      end
    end

    test "round-trips :elapsed and opaque payloads" do
      assert_exact(:resume, %{payload: :elapsed, resumed_at: ~U[2026-07-05 12:00:00Z]})
      assert_exact(:resume, %{payload: %{"cb" => "data"}, resumed_at: nil})
      assert_exact(:resume, %{payload: {:external, self()}, resumed_at: nil})
    end
  end

  describe "error" do
    test "round-trips a normalized error including a non-JSON raw" do
      assert_exact(:error, %Error{
        kind: :provider,
        code: :rate_limited,
        provider: :anthropic,
        message: "HTTP 429",
        retryable?: true,
        raw: {:api_error, 429, %{"error" => %{"message" => "slow down"}}}
      })

      assert_exact(:error, %Error{kind: :runtime, code: :exception, message: "boom"})
    end
  end

  describe "interrupt" do
    test "round-trips every standard code and the app escape hatch" do
      for code <- InterruptReason.codes() do
        assert_exact(:interrupt, InterruptReason.new(code, "detail"))
      end

      assert_exact(:interrupt, InterruptReason.new({:app, {:budget, :tokens}}, nil))
    end
  end

  describe "usage" do
    test "round-trips" do
      assert_exact(:usage, %Usage{input_tokens: 10, output_tokens: 3})
    end
  end

  describe "resolve_fields/2 and to_facts/2" do
    test "merges overrides over recipe defaults" do
      fields = Codec.resolve_fields(:id, epoch: :run_epoch)
      assert fields[:ref] == :id
      assert fields[:epoch] == :run_epoch
      assert fields[:status] == :status
    end

    test "rejects unknown field keys" do
      assert_raise ArgumentError, ~r/unknown lifecycle fields/, fn ->
        Codec.resolve_fields(:id, epok: :run_epoch)
      end
    end

    test "builds facts from a row map" do
      row = %{
        id: 7,
        kind: "loop",
        status: "running",
        lease_epoch: 2,
        executor_id: "oban:1:node",
        heartbeat_at: ~U[2026-07-05 12:00:00.000000Z],
        deadline: ~U[2026-07-05 12:10:00.000000Z],
        cancel: nil,
        suspension: nil,
        resume: nil,
        effects: true,
        usage: %{"input_tokens" => 5, "output_tokens" => 1},
        error: nil,
        interrupt: nil,
        queued_at: ~U[2026-07-05 11:59:00.000000Z],
        finished_at: nil
      }

      facts = Codec.to_facts(row, Codec.resolve_fields(:id, []))

      assert %Facts{
               ref: 7,
               kind: :loop,
               status: :running,
               epoch: 2,
               executor_id: "oban:1:node",
               effects?: true,
               usage: %Usage{input_tokens: 5, output_tokens: 1}
             } = facts
    end
  end
end
