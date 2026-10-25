if Code.ensure_loaded?(Oban) and Code.ensure_loaded?(Ecto.Query) do
  defmodule Clementine.Runs.CancelRelay do
    @moduledoc false
    # Carries a committed cancel flag to the process running the run, on
    # whichever node runs it, so the run stops mid-response instead of at
    # its next step: the message aborts the model call in flight.
    #
    # A runner subscribes after its claim (Runs.Lifecycle.subscribe_cancel/1):
    # it registers in Clementine.Runs.Registry under {:cancel, run_id}, with
    # the epoch it holds. Once a flag commits, push/2 sends
    # {:clementine, :cancel, reason} to a runner on this node that holds the
    # flagged epoch. With none here, it notifies every node through the Oban
    # instance's notifier (LISTEN/NOTIFY, :pg, or whatever the host's Oban
    # uses), and on each node this process hands the notification to a
    # runner registered there. A notification names only the run: the relay
    # reads the flag from the row, so only a committed flag on the execution
    # a runner holds stops it.
    #
    # Push is best-effort. A lost notification costs latency, never
    # correctness: the runner still polls the flag at every boundary, and a
    # flag that commits before the runner subscribes is there for its first
    # poll, before its first model call.

    use GenServer

    require Logger

    alias Clementine.Lifecycle.Facts
    alias Clementine.Runs.Lifecycle

    @registry Clementine.Runs.Registry
    @channel :clementine_cancel

    # How long the relay waits to listen again when the notifier is down.
    @relisten_ms 1_000

    def start_link(opts) do
      GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :oban),
        name: Keyword.get(opts, :name, __MODULE__)
      )
    end

    @doc false
    # The calling process, a runner holding `epoch`, hears of a cancel of
    # `run_id` from now on.
    @spec subscribe(Ecto.UUID.t(), non_neg_integer()) :: :ok
    def subscribe(run_id, epoch) do
      {:ok, _owner} = Registry.register(@registry, {:cancel, run_id}, epoch)
      :ok
    end

    @doc false
    # The calling process hears of no more cancels of `run_id`, and drops
    # any that arrived after its run stopped listening for them, so a
    # process that executes another run next (a test's perform_job) does not
    # stop that one.
    @spec unsubscribe(Ecto.UUID.t()) :: :ok
    def unsubscribe(run_id) do
      Registry.unregister(@registry, {:cancel, run_id})
      flush()
    end

    defp flush do
      receive do
        {:clementine, :cancel, _reason} -> flush()
      after
        0 -> :ok
      end
    end

    @doc false
    # Takes a flag to its runner, from the facts the flag's write committed.
    @spec push(Facts.t(), term()) :: :ok
    def push(
          %Facts{status: :running, ref: run_id, epoch: epoch, cancel: %{reason: reason}},
          oban
        ) do
      unless deliver(run_id, epoch, reason), do: notify(oban, run_id)
      :ok
    end

    def push(%Facts{}, _oban), do: :ok

    # Sends the cancel to every runner on this node that holds `epoch`;
    # false when there is none.
    defp deliver(run_id, epoch, reason) do
      runners = for {pid, ^epoch} <- Registry.lookup(@registry, {:cancel, run_id}), do: pid
      Enum.each(runners, &send(&1, {:clementine, :cancel, reason}))
      runners != []
    end

    defp notify(oban, run_id) do
      case Oban.Notifier.notify(oban, @channel, %{"run_id" => run_id}) do
        :ok -> :ok
        {:error, error} -> log_notify_failure(run_id, inspect(error))
      end
    rescue
      e -> log_notify_failure(run_id, Exception.message(e))
    catch
      kind, reason -> log_notify_failure(run_id, "#{kind}: #{inspect(reason)}")
    end

    defp log_notify_failure(run_id, why) do
      Logger.warning(
        "could not notify other nodes of a cancel (#{why}); the run stops at its next " <>
          "step instead (run: #{run_id})"
      )
    end

    @impl GenServer
    def init(oban), do: {:ok, %{oban: oban, notifier: nil}, {:continue, :listen}}

    @impl GenServer
    def handle_continue(:listen, state), do: {:noreply, listen(state)}

    @impl GenServer
    def handle_info({:notification, @channel, %{"run_id" => run_id}}, state) do
      relay(run_id)
      {:noreply, state}
    end

    # A notifier that restarts forgets its listeners.
    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{notifier: ref} = state) do
      {:noreply, listen(%{state | notifier: nil})}
    end

    def handle_info(:listen, %{notifier: nil} = state), do: {:noreply, listen(state)}

    def handle_info(_message, state), do: {:noreply, state}

    defp listen(%{oban: oban} = state) do
      notifier = Oban.Registry.whereis(oban, Oban.Notifier)

      if is_pid(notifier) and listen_on(oban) == :ok do
        %{state | notifier: Process.monitor(notifier)}
      else
        Process.send_after(self(), :listen, @relisten_ms)
        state
      end
    end

    defp listen_on(oban) do
      Oban.Notifier.listen(oban, [@channel])
    rescue
      _e -> :error
    catch
      _kind, _reason -> :error
    end

    defp relay(run_id) do
      if Registry.lookup(@registry, {:cancel, run_id}) != [] do
        case fetch(run_id) do
          {:ok, %Facts{status: :running, epoch: epoch, cancel: %{reason: reason}}} ->
            deliver(run_id, epoch, reason)

          _not_flagged ->
            :ok
        end
      end

      :ok
    end

    defp fetch(run_id) do
      Lifecycle.fetch(run_id, nil)
    rescue
      e ->
        Logger.warning(
          "could not read a cancelled run (#{Exception.message(e)}); it stops at its next " <>
            "step instead (run: #{run_id})"
        )

        {:error, :unreadable}
    end
  end
end
