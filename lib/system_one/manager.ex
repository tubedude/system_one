defmodule SystemOne.Manager do
  @moduledoc false
  use GenServer

  alias SystemOne.Status

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def serving(name), do: GenServer.call(name, :serving)
  def status(name), do: GenServer.call(name, :status)
  def subscribe(name), do: GenServer.call(name, {:subscribe, self()})
  def unsubscribe(name), do: GenServer.call(name, {:unsubscribe, self()})
  def await_ready(name, timeout), do: GenServer.call(name, {:await_ready, timeout}, :infinity)
  def reload(name, overrides), do: GenServer.call(name, {:reload, overrides}, :infinity)
  def stop(name), do: GenServer.call(name, :stop)

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name),
      model: Keyword.fetch!(opts, :model),
      opts: opts,
      serving_supervisor: Keyword.fetch!(opts, :serving_supervisor),
      serving_name: Module.concat(Keyword.fetch!(opts, :name), Serving),
      serving_pid: nil,
      serving_ref: nil,
      load_pid: nil,
      load_ref: nil,
      reload_from: nil,
      error: nil,
      status: :loading,
      subscribers: %{},
      waiters: %{}
    }

    {:ok, state, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state), do: {:noreply, start_load(state)}

  @impl true
  def handle_call(:serving, _from, %{status: :ready} = state) do
    if is_pid(state.serving_pid) and Process.alive?(state.serving_pid) do
      {:reply, {:ok, state.serving_name}, state}
    else
      state = fail(state, :serving_stopped)
      {:reply, {:error, unavailable(state)}, state}
    end
  end

  def handle_call(:serving, _from, state), do: {:reply, {:error, unavailable(state)}, state}

  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        ref = Process.monitor(pid)
        %{state | subscribers: Map.put(state.subscribers, pid, ref)}
      end

    send(pid, status_message(state))
    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:await_ready, _timeout}, _from, %{status: :ready} = state),
    do: {:reply, {:ok, build_status(state)}, state}

  def handle_call({:await_ready, _timeout}, _from, %{status: status} = state)
      when status in [:failed, :stopped],
      do: {:reply, {:error, {:unavailable, unavailable(state)}}, state}

  def handle_call({:await_ready, timeout}, from, %{status: :loading} = state) do
    waiter_ref = make_ref()
    timer_ref = Process.send_after(self(), {:await_ready_timeout, waiter_ref}, timeout)
    waiters = Map.put(state.waiters, waiter_ref, {from, timer_ref})
    {:noreply, %{state | waiters: waiters}}
  end

  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call({:reload, _overrides}, _from, %{status: :loading} = state),
    do: {:reply, {:error, :loading}, state}

  def handle_call({:reload, overrides}, from, state) do
    opts = Keyword.merge(state.opts, overrides)

    next = %{
      state
      | opts: opts,
        model: Keyword.fetch!(opts, :model),
        status: :loading,
        error: nil,
        reload_from: from
    }

    {:noreply, next |> notify() |> start_load()}
  end

  def handle_call(:stop, _from, state) do
    state =
      state
      |> cancel_load(:stopped)
      |> terminate_serving()
      |> Map.merge(%{serving_pid: nil, serving_ref: nil, status: :stopped, error: nil})
      |> settle_waiters({:error, {:unavailable, :stopped}})
      |> notify()

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:model_loaded, pid, result}, %{load_pid: pid} = state) do
    Process.demonitor(state.load_ref, [:flush])
    state = %{state | load_pid: nil, load_ref: nil}

    case result do
      {:ok, serving, serving_opts} -> finish_load(state, serving, serving_opts)
      {:error, reason} -> {:noreply, fail(state, reason)}
      other -> {:noreply, fail(state, {:invalid_model_load_result, other})}
    end
  end

  def handle_info({:model_loaded, _pid, _result}, state), do: {:noreply, state}

  def handle_info({:await_ready_timeout, waiter_ref}, state) do
    case Map.pop(state.waiters, waiter_ref) do
      {nil, _waiters} ->
        {:noreply, state}

      {{from, _timer_ref}, waiters} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{load_ref: ref, load_pid: pid} = state),
    do:
      {:noreply,
       state |> Map.merge(%{load_pid: nil, load_ref: nil}) |> fail({:load_exit, reason})}

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{serving_ref: ref, serving_pid: pid} = state
      ) do
    state = %{state | serving_pid: nil, serving_ref: nil}
    {:noreply, fail(state, {:serving_exit, reason})}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        ^ref -> Map.delete(state.subscribers, pid)
        _ -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp start_load(state) do
    manager = self()
    model = state.model
    opts = model_opts(state.opts)

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            model.load(opts)
          rescue
            exception -> {:error, Exception.message(exception)}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(manager, {:model_loaded, self(), result})
      end)

    %{state | load_pid: pid, load_ref: ref}
  end

  defp finish_load(state, serving, serving_opts) do
    state = terminate_serving(state)

    case start_serving(state, serving, serving_opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state =
          state
          |> Map.merge(%{serving_pid: pid, serving_ref: ref, status: :ready, error: nil})
          |> reply_reload(:ok)
          |> settle_waiters_with_status()
          |> notify()

        {:noreply, state}

      {:error, reason} ->
        {:noreply, fail(state, reason)}
    end
  end

  defp start_serving(state, serving, serving_opts) do
    opts = [serving: serving, name: state.serving_name] |> Keyword.merge(serving_opts)

    {Nx.Serving, opts}
    |> Supervisor.child_spec(restart: :temporary)
    |> then(&DynamicSupervisor.start_child(state.serving_supervisor, &1))
  end

  defp terminate_serving(%{serving_pid: nil} = state), do: state

  defp terminate_serving(state) do
    if state.serving_ref, do: Process.demonitor(state.serving_ref, [:flush])
    _ = DynamicSupervisor.terminate_child(state.serving_supervisor, state.serving_pid)
    %{state | serving_pid: nil, serving_ref: nil}
  end

  defp cancel_load(%{load_pid: nil} = state, _reason), do: state

  defp cancel_load(state, reason) do
    Process.demonitor(state.load_ref, [:flush])
    Process.exit(state.load_pid, :kill)

    state
    |> Map.merge(%{load_pid: nil, load_ref: nil})
    |> reply_reload({:error, reason})
  end

  defp fail(state, reason) do
    state
    |> terminate_serving()
    |> Map.merge(%{status: :failed, error: reason})
    |> reply_reload({:error, reason})
    |> settle_waiters({:error, {:unavailable, {:failed, reason}}})
    |> notify()
  end

  defp reply_reload(%{reload_from: nil} = state, _reply), do: state

  defp reply_reload(state, reply) do
    GenServer.reply(state.reload_from, reply)
    %{state | reload_from: nil}
  end

  defp settle_waiters_with_status(state), do: settle_waiters(state, {:ok, build_status(state)})

  defp settle_waiters(state, reply) do
    Enum.each(state.waiters, fn {_ref, {from, timer_ref}} ->
      Process.cancel_timer(timer_ref)
      GenServer.reply(from, reply)
    end)

    %{state | waiters: %{}}
  end

  defp model_opts(opts), do: Keyword.drop(opts, [:name, :model, :serving_supervisor])

  defp build_status(state) do
    %Status{
      state: state.status,
      model: state.model,
      serving_pid: state.serving_pid,
      error: state.error
    }
  end

  defp status_message(state), do: {:system_one, state.name, build_status(state)}

  defp notify(state) do
    message = status_message(state)
    Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, message) end)
    state
  end

  defp unavailable(%{status: :failed, error: reason}), do: {:failed, reason}
  defp unavailable(%{status: status}), do: status
end
