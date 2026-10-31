defmodule SystemOneTest do
  use ExUnit.Case, async: false

  alias SystemOne.{Preview, Query, Question, Status}

  alias SystemOne.TestModels.{
    Alpha,
    Beta,
    Crashing,
    Exploding,
    Failing,
    Invalid,
    Slow,
    Strict,
    WithPreview
  }

  test "validates required child options" do
    assert_raise NimbleOptions.ValidationError, fn ->
      SystemOne.child_spec(model: Alpha)
    end
  end

  test "validates runtime option types" do
    assert_raise NimbleOptions.ValidationError, fn ->
      SystemOne.child_spec(name: __MODULE__, model: Alpha, batch_size: 0)
    end
  end

  test "starts directly through the public API" do
    name = Module.concat(__MODULE__, DirectStart)
    assert {:ok, pid} = SystemOne.start_link(name: name, model: Alpha)
    assert {:ok, %Status{state: :ready}} = SystemOne.await_ready(name, timeout: 1_000)
    Supervisor.stop(pid)
  end

  test "the consumer supervises a named model instance" do
    name = Module.concat(__MODULE__, ConsumerOwned)
    start_supervised!({SystemOne, name: name, model: Alpha})
    assert_eventually_ready(name)

    query = Query.new(%{message: "hello"}, [Question.new(:safe, :noul, "Is it safe?")])

    assert {:ok, result} = SystemOne.query(name, query)
    assert result.model == :alpha
    assert result.answers[:safe].noul == 0.75
    assert result.answers[:safe].metadata.served_by == :alpha
  end

  test "different model implementations can be selected and reloaded" do
    name = Module.concat(__MODULE__, MultipleModels)
    start_supervised!({SystemOne, name: name, model: Alpha})
    assert_eventually_ready(name)

    query = Query.new("state", [Question.new("route", :noul, "Route?")])
    assert {:ok, %{model: :alpha}} = SystemOne.query(name, query)

    assert :ok = SystemOne.reload(name, model: Beta)
    assert {:ok, %{model: :beta}} = SystemOne.query(name, query)
  end

  test "a model load failure is represented in public status" do
    name = Module.concat(__MODULE__, FailedModel)
    start_supervised!({SystemOne, name: name, model: Failing})

    assert %Status{state: :failed, model: Failing, error: :cannot_load} =
             await_status(name, :failed)

    assert {:error, {:unavailable, {:failed, :cannot_load}}} =
             SystemOne.query(name, Query.new("state", [Question.new(:q, :noul, "Question?")]))

    assert {:error, {:unavailable, {:failed, :cannot_load}}} =
             SystemOne.await_ready(name, timeout: 10)
  end

  test "invalid and crashing model loaders become failed statuses" do
    invalid_name = Module.concat(__MODULE__, InvalidModel)
    start_supervised!({SystemOne, name: invalid_name, model: Invalid})

    assert %Status{state: :failed, error: {:invalid_model_load_result, :invalid}} =
             await_status(invalid_name, :failed)

    crashing_name = Module.concat(__MODULE__, CrashingModel)
    start_supervised!({SystemOne, name: crashing_name, model: Crashing})

    assert %Status{state: :failed, error: "load crashed"} = await_status(crashing_name, :failed)
  end

  test "returns model argument errors as invalid queries" do
    name = Module.concat(__MODULE__, StrictModel)
    start_supervised!({SystemOne, name: name, model: Strict})
    assert {:ok, _status} = SystemOne.await_ready(name, timeout: 1_000)

    assert {:error, {:invalid_query, "too many questions"}} =
             SystemOne.query(name, Query.new("state", [Question.new(:q, :noul, "Question?")]))
  end

  test "returns unexpected model errors as serving errors" do
    name = Module.concat(__MODULE__, ExplodingModel)
    start_supervised!({SystemOne, name: name, model: Exploding})
    assert {:ok, _status} = SystemOne.await_ready(name, timeout: 1_000)

    assert {:error, {:unavailable, {:serving_error, "query crashed"}}} =
             SystemOne.query(name, Query.new("state", [Question.new(:q, :noul, "Question?")]))
  end

  test "reports stopped instances as unavailable" do
    name = Module.concat(__MODULE__, StoppedModel)
    start_supervised!({SystemOne, name: name, model: Alpha})
    assert_eventually_ready(name)
    assert :ok = SystemOne.stop(name)

    assert {:error, {:unavailable, :stopped}} =
             SystemOne.query(name, Query.new("state", [Question.new(:q, :noul, "Question?")]))

    assert {:error, {:unavailable, :stopped}} = SystemOne.await_ready(name, timeout: 10)
  end

  test "subscribes to lifecycle status changes" do
    name = Module.concat(__MODULE__, SubscribedModel)
    start_supervised!({SystemOne, name: name, model: Alpha})
    assert :ok = SystemOne.subscribe(name)

    assert_receive {:system_one, ^name, %Status{state: :ready}}

    receive do
      {:system_one, ^name, %Status{state: :loading}} -> :ok
    after
      0 -> :ok
    end

    assert :ok = SystemOne.unsubscribe(name)
    assert :ok = SystemOne.unsubscribe(name)
    assert :ok = SystemOne.reload(name, model: Beta)
    refute_receive {:system_one, ^name, _}, 20
  end

  test "rejects a second reload while loading" do
    name = Module.concat(__MODULE__, ConcurrentReload)
    start_supervised!({SystemOne, name: name, model: Alpha})
    assert_eventually_ready(name)

    reload = Task.async(fn -> SystemOne.reload(name, model: Slow) end)
    assert %Status{state: :loading} = await_status(name, :loading)
    assert {:error, :loading} = SystemOne.reload(name, model: Beta)
    assert :ok = Task.await(reload)
  end

  test "awaits readiness" do
    name = Module.concat(__MODULE__, AwaitedModel)
    start_supervised!({SystemOne, name: name, model: Alpha})

    assert {:ok, %Status{state: :ready}} = SystemOne.await_ready(name, timeout: 1_000)
  end

  test "stays responsive and rejects queries while a model is loading" do
    name = Module.concat(__MODULE__, SlowModel)
    start_supervised!({SystemOne, name: name, model: Slow})

    assert %Status{state: :loading} = SystemOne.status(name)

    assert {:error, {:unavailable, :loading}} =
             SystemOne.query(name, Query.new("state", [Question.new(:q, :noul, "Question?")]))

    assert {:error, :timeout} = SystemOne.await_ready(name, timeout: 10)

    assert {:ok, %Status{state: :ready, model: Slow}} =
             SystemOne.await_ready(name, timeout: 1_000)
  end

  test "awaiting readiness does not remove an explicit subscription" do
    name = Module.concat(__MODULE__, PersistentSubscription)
    start_supervised!({SystemOne, name: name, model: Alpha})
    assert :ok = SystemOne.subscribe(name)
    assert_receive {:system_one, ^name, %Status{state: state}} when state in [:loading, :ready]
    assert {:ok, %Status{state: :ready}} = SystemOne.await_ready(name, timeout: 1_000)

    reload = Task.async(fn -> SystemOne.reload(name, model: Slow) end)
    assert_receive {:system_one, ^name, %Status{state: :loading}}
    assert :ok = Task.await(reload)
    assert_receive {:system_one, ^name, %Status{state: :ready, model: Slow}}
  end

  @tag :capture_log
  test "notifies subscribers when the active serving exits" do
    name = Module.concat(__MODULE__, CrashedServing)
    start_supervised!({SystemOne, name: name, model: Alpha})
    assert {:ok, %Status{state: :ready, serving_pid: pid}} = SystemOne.await_ready(name)
    assert :ok = SystemOne.subscribe(name)
    assert_receive {:system_one, ^name, %Status{state: :ready}}

    Process.exit(pid, :kill)

    assert_receive {:system_one, ^name, %Status{state: :failed, error: {:serving_exit, :killed}}}
  end

  test "preview returns token estimation for preview-capable models" do
    name = Module.concat(__MODULE__, PreviewSupported)
    start_supervised!({SystemOne, name: name, model: WithPreview})
    assert_eventually_ready(name)

    query =
      Query.new(%{message: "hello"}, [
        Question.new(:first, :noul, "Safe?"),
        Question.new(:second, :choice, "Route?", criteria: ["a", "b"])
      ])

    assert {:ok, %Preview{} = preview} = SystemOne.preview(name, query)
    assert preview.total_tokens == 84
    assert preview.target_sequence_length == 64
    assert preview.truncated? == false
    assert preview.questions[:first].header_tokens == 10
    assert preview.questions[:second].header_tokens == 10
    assert length(preview.ordered_questions) == 2
    assert Enum.map(preview.ordered_questions, & &1.question_id) == [:first, :second]
  end

  test "preview returns error when model does not support preview" do
    name = Module.concat(__MODULE__, PreviewUnsupported)
    start_supervised!({SystemOne, name: name, model: Alpha})
    assert_eventually_ready(name)

    query = Query.new("state", [Question.new(:q, :noul, "Question?")])
    assert {:error, :preview_not_supported} = SystemOne.preview(name, query)
  end

  test "preview returns unavailable when instance is stopped or failed" do
    stopped_name = Module.concat(__MODULE__, PreviewStopped)
    start_supervised!({SystemOne, name: stopped_name, model: WithPreview})
    assert_eventually_ready(stopped_name)
    assert :ok = SystemOne.stop(stopped_name)

    query = Query.new("state", [Question.new(:q, :noul, "Question?")])
    assert {:error, {:unavailable, :stopped}} = SystemOne.preview(stopped_name, query)

    failed_name = Module.concat(__MODULE__, PreviewFailed)
    start_supervised!({SystemOne, name: failed_name, model: Failing})
    assert %Status{state: :failed} = await_status(failed_name, :failed)

    assert {:error, {:unavailable, {:failed, :cannot_load}}} =
             SystemOne.preview(failed_name, query)
  end

  defp assert_eventually_ready(name),
    do: assert(%Status{state: :ready} = await_status(name, :ready))

  defp await_status(name, desired, attempts \\ 50)
  defp await_status(name, _desired, 0), do: SystemOne.status(name)

  defp await_status(name, desired, attempts) do
    status = SystemOne.status(name)

    if status.state == desired do
      status
    else
      Process.sleep(10)
      await_status(name, desired, attempts - 1)
    end
  end
end
