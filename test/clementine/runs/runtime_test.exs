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

    test "refuses an Oban instance on another repo" do
      defmodule OtherRepo do
        use Ecto.Repo, otp_app: :clementine, adapter: Ecto.Adapters.Postgres
      end

      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Clementine.Runs.Supervisor.start_link(repo: OtherRepo)

      assert message =~ "Oban instance Oban uses Clementine.TestRepo"
    end

    test "says to start after Oban when no Oban instance runs" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Clementine.Runs.Supervisor.start_link(repo: TestRepo, oban: NoSuchOban)

      assert message =~ "Start {Clementine, ...} after Oban"
    end

    test "refuses a table behind the code's version, naming the migration to write" do
      Process.flag(:trap_exit, true)

      TestRepo.query!("COMMENT ON TABLE agent_runs IS '1'")

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               Clementine.Runs.Supervisor.start_link(repo: TestRepo)

      assert message =~ "needs the agent_runs table at version 4"
      assert message =~ "has it at version 1"
      assert message =~ "Clementine.Migration.up(from: 1, version: 4)"

      # A table built before stamps, or by hand to match version 1.
      TestRepo.query!("COMMENT ON TABLE agent_runs IS NULL")

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               Clementine.Runs.Supervisor.start_link(repo: TestRepo)

      assert message =~ "with no version stamp (version 1)"
      assert message =~ "Clementine.Migration.up(from: 1, version: 4)"
    end

    test "refuses a missing table, naming the migration to write" do
      Process.flag(:trap_exit, true)

      TestRepo.query!("ALTER TABLE agent_runs RENAME TO agent_runs_elsewhere")

      assert {:error, {%RuntimeError{message: message}, _stack}} =
               Clementine.Runs.Supervisor.start_link(repo: TestRepo)

      assert message =~ "has none"
      assert message =~ "Clementine.Migration.up(version: 4)"
    end

    test "starts against a table ahead of the code's version" do
      TestRepo.query!("COMMENT ON TABLE agent_runs IS '5'")

      assert {:ok, _pid} = start_supervised({Clementine, repo: TestRepo})
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

    test "declares whether the agent's runs are turns" do
      assert Chat.turn()
      assert Handoff.turn()
      refute Echo.turn()
      refute Lookup.turn()
    end

    test "a turn agent must define history/1" do
      assert_raise ArgumentError, ~r/TurnWithoutHistory is a turn agent .* history\/1/, fn ->
        defmodule TurnWithoutHistory do
          use Clementine.Agent, key: "turn_without_history", turn: true, model: :claude_sonnet
        end
      end
    end

    test "a task agent may define history/1 too" do
      defmodule TaskWithHistory do
        use Clementine.Agent, key: "task_with_history", model: :claude_sonnet

        @impl true
        def history(_run), do: [Clementine.LLM.Message.UserMessage.new("Earlier.")]
      end

      refute TaskWithHistory.turn()
      assert [%Clementine.LLM.Message.UserMessage{}] = TaskWithHistory.history(%AgentRun{})
    end

    test "turn: takes a boolean" do
      assert_raise ArgumentError, ~r/takes turn: true or false, got: "yes"/, fn ->
        defmodule TurnString do
          use Clementine.Agent, key: "turn_string", turn: "yes", model: :claude_sonnet
        end
      end
    end
  end

  describe "Clementine.Migration" do
    test "names only versions that exist" do
      assert Clementine.Migration.current_version() == 4

      assert_raise ArgumentError, ~r/versions run 1..4/, fn ->
        Clementine.Migration.up(version: 5)
      end

      assert_raise ArgumentError, ~r/versions run 1..4/, fn ->
        Clementine.Migration.up(from: 3, version: 1)
      end

      assert_raise KeyError, fn -> Clementine.Migration.up([]) end
    end
  end
end
