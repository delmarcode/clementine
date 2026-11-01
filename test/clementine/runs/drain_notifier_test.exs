defmodule Clementine.Runs.DrainNotifierTest do
  use ExUnit.Case, async: false

  alias Clementine.Runs.DrainNotifier

  test "tells every registered runner to drain when it stops" do
    start_supervised!({DrainNotifier, name: :drain_notifier_test})
    {:ok, _owner} = DrainNotifier.register()

    stop_supervised!(DrainNotifier)

    assert_receive {:clementine, :drain}
  end

  test "the runner registry belongs to Clementine's application, which outlives the host's" do
    assert {:ok, _owner} = DrainNotifier.register()

    # Membership, not the only entry: Worker.perform/1 registers the
    # process that runs the job, the test process under perform_job, and
    # an earlier test's entry outlives that test until the registry
    # handles its exit.
    assert {self(), nil} in Registry.lookup(Clementine.Runs.Registry, :active)

    assert Enum.any?(Supervisor.which_children(Clementine.Supervisor), fn {id, _, _, _} ->
             id == Clementine.Runs.Registry
           end)
  end
end
