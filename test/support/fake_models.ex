defmodule SystemOne.TestServing do
  @behaviour Nx.Serving

  alias SystemOne.{Answer, Result}

  @impl true
  def init(_mode, model_name, [_opts]) do
    {:ok, fn input -> {input, model_name} end}
  end

  @impl true
  def handle_batch(batch, _partition, function) do
    {output, model_name} = function.(Nx.Defn.jit_apply(&Function.identity/1, [batch]))
    {:execute, fn -> {output, model_name} end, function}
  end

  def serving(model_name) do
    Nx.Serving.new(__MODULE__, model_name)
    |> Nx.Serving.client_preprocessing(fn query ->
      batch = Nx.Batch.stack([Nx.tensor(1)])
      {batch, query}
    end)
    |> Nx.Serving.client_postprocessing(fn {_output, returned_model}, query ->
      answers =
        Map.new(query.questions, fn question ->
          {question.id,
           %Answer{
             question_id: question.id,
             type: question.type,
             noul: 0.75,
             metadata: %{served_by: returned_model}
           }}
        end)

      %Result{model: returned_model, answers: answers}
    end)
  end
end

defmodule SystemOne.TestModels.Alpha do
  @behaviour SystemOne.Model
  def load(_opts), do: {:ok, SystemOne.TestServing.serving(:alpha), [batch_size: 8]}
end

defmodule SystemOne.TestModels.Beta do
  @behaviour SystemOne.Model
  def load(_opts), do: {:ok, SystemOne.TestServing.serving(:beta), [batch_size: 8]}
end

defmodule SystemOne.TestModels.Failing do
  @behaviour SystemOne.Model
  def load(_opts), do: {:error, :cannot_load}
end

defmodule SystemOne.TestModels.Slow do
  @behaviour SystemOne.Model

  def load(_opts) do
    Process.sleep(150)
    {:ok, SystemOne.TestServing.serving(:slow), [batch_size: 8]}
  end
end

defmodule SystemOne.TestModels.Strict do
  @behaviour SystemOne.Model

  def load(_opts) do
    serving =
      Nx.Serving.new(SystemOne.TestServing, :strict)
      |> Nx.Serving.client_preprocessing(fn _query ->
        raise ArgumentError, "too many questions"
      end)

    {:ok, serving, []}
  end
end

defmodule SystemOne.TestModels.Invalid do
  @behaviour SystemOne.Model
  def load(_opts), do: :invalid
end

defmodule SystemOne.TestModels.Crashing do
  @behaviour SystemOne.Model
  def load(_opts), do: raise("load crashed")
end

defmodule SystemOne.TestModels.Exploding do
  @behaviour SystemOne.Model

  def load(_opts) do
    serving =
      Nx.Serving.new(SystemOne.TestServing, :exploding)
      |> Nx.Serving.client_preprocessing(fn _query -> raise "query crashed" end)

    {:ok, serving, []}
  end
end
