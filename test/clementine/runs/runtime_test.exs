defmodule Clementine.Runs.RuntimeTest do
  @moduledoc """
  The glue a host writes: the child spec, `use Clementine.Agent`, and the
  versioned migration.
  """

  use Clementine.RunsCase

  describe "the child spec" do
    @describetag runtime: false

    test "refuses an agent module that is not a Clementine.Agent" do
      assert_raise ArgumentError, ~r/String is not a Clementine.Agent/, fn ->
        Clementine.Runs.Config.new!(repo: TestRepo, agents: [String])
      end
    end

    test "refuses two agents with one key" do
      defmodule EchoTwin do
        use Clementine.Agent, key: "test_echo", model: :claude_sonnet
      end

      assert_raise ArgumentError, ~r/share the agent key "test_echo"/, fn ->
        Clementine.Runs.Config.new!(repo: TestRepo, agents: [Echo, EchoTwin])
      end
    end

    test "refuses a host or repo that does not exist, and an unknown option" do
      assert_raise ArgumentError, ~r/host Nope is unavailable/, fn ->
        Clementine.Runs.Config.new!(repo: TestRepo, host: Nope)
      end

      assert_raise ArgumentError, ~r/repo Nope is unavailable/, fn ->
        Clementine.Runs.Config.new!(repo: Nope)
      end

      assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:reaper\]/, fn ->
        Clementine.Runs.Config.new!(repo: TestRepo, reaper: [interval: 1])
      end
    end

    test "says to start after Oban when no Oban instance runs" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Clementine.Runs.Supervisor.start_link(repo: TestRepo, oban: NoSuchOban)

      assert message =~ "Start {Clementine, ...} after Oban"
    end
  end

  describe "use Clementine.Agent" do
    test "builds the agent from the fields given to use" do
      assert "test_echo" = Echo.key()

      assert %Clementine.Agent{id: "test_echo", model: :claude_sonnet, instructions: "Answer."} =
               Echo.agent(%AgentRun{})
    end

    test "needs a key" do
      assert_raise ArgumentError, ~r/needs a non-empty string key:/, fn ->
        defmodule NoKey do
          use Clementine.Agent, model: :claude_sonnet
        end
      end
    end

    test "fails the build on a field Clementine.Agent does not have" do
      assert_raise KeyError, ~r/:modle/, fn ->
        defmodule Typo do
          use Clementine.Agent, key: "typo", modle: :claude_sonnet
        end
      end
    end
  end

  describe "Clementine.Migration" do
    test "builds agent_runs at version 1" do
      columns =
        TestRepo.query!("""
        SELECT column_name, data_type FROM information_schema.columns
        WHERE table_name = 'agent_runs'
        """).rows
        |> Map.new(fn [name, type] -> {name, type} end)

      assert columns["id"] == "uuid"
      assert columns["agent"] == "text"
      assert columns["subject_id"] == "text"
      assert columns["input"] == "jsonb"
      assert columns["lease_epoch"] == "bigint"
      assert columns["queued_at"] == "timestamp with time zone"
      assert map_size(columns) == 25

      assert [[_index]] =
               TestRepo.query!("""
               SELECT indexdef FROM pg_indexes
               WHERE indexname = 'agent_runs_single_active_run_index'
               """).rows
    end

    test "names only versions that exist" do
      assert Clementine.Migration.current_version() == 1

      assert_raise ArgumentError, ~r/versions run 1..1/, fn ->
        Clementine.Migration.up(version: 2)
      end

      assert_raise KeyError, fn -> Clementine.Migration.up([]) end
    end
  end
end
