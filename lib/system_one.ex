defmodule SystemOne do
  @option_schema [
    name: [
      type: :atom,
      required: true,
      doc: "The name used to address the instance, such as `MyApp.SystemOne`."
    ],
    model: [
      type: :atom,
      required: true,
      doc: "A module that implements `SystemOne.Model`."
    ],
    model_dir: [
      type: :string,
      doc: "The directory of an installed model bundle."
    ],
    execution_providers: [
      type: {:list, :atom},
      doc: "Where the model runs, such as `[:cuda]` or `[:cpu]`. Laya uses the first entry."
    ],
    batch_size: [
      type: :pos_integer,
      doc: "The maximum number of queries per batch."
    ],
    batch_timeout: [
      type: :non_neg_integer,
      doc: "How long, in milliseconds, to wait for a batch to fill."
    ]
  ]

  @moduledoc """
  Supervised serving of small local decision models.

  SystemOne does not start any processes on its own. Add one child per model
  instance to your supervision tree:

      children = [
        {SystemOne,
         name: MyApp.SystemOne,
         model: SystemOne.Models.Laya,
         model_dir: "priv/models/laya"}
      ]

  The model loads in the background. Queries return
  `{:error, {:unavailable, :loading}}` until it is ready. Use `await_ready/2`
  to block until then, or `subscribe/1` to receive status changes.

  ## Options

  #{NimbleOptions.docs(@option_schema)}

  Options other than `:name` and `:model` are passed to the model's
  `c:SystemOne.Model.load/1`. Models apply their own defaults.

  ## Telemetry

  `query/2` emits a span under `[:system_one, :query]`:

    * `[:system_one, :query, :start]` - metadata: `:name`, `:questions_count`
    * `[:system_one, :query, :stop]` - metadata: `:name`, `:questions_count`,
      and `:status`, which is `:ok` or `:error`
    * `[:system_one, :query, :exception]` - standard span exception metadata

  """

  alias SystemOne.{Manager, Preview, Query, Status}

  @reload_schema @option_schema
                 |> Keyword.delete(:name)
                 |> Enum.map(fn {key, options} -> {key, Keyword.delete(options, :required)} end)

  @await_ready_schema [timeout: [type: :pos_integer, default: 30_000]]

  @typedoc "The name of a SystemOne instance, as given in the `:name` option."
  @type name :: atom()

  @typedoc "The reason a query could not be served."
  @type query_error ::
          {:unavailable, :loading | :stopped | {:failed, term()} | term()}
          | {:invalid_query, String.t()}

  @doc """
  Returns a child specification for a SystemOne instance.

  See the ["Options"](#module-options) section for the options.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = NimbleOptions.validate!(opts, @option_schema)

    %{
      id: Keyword.fetch!(opts, :name),
      start: {SystemOne.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts a SystemOne instance linked to the current process.

  Returns as soon as the instance starts. The model loads in the background.

  See the ["Options"](#module-options) section for the options.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts
    |> NimbleOptions.validate!(@option_schema)
    |> SystemOne.Supervisor.start_link()
  end

  @doc """
  Runs `query` on the instance `name`.

  Concurrent queries are batched together by `Nx.Serving`.

  Returns `{:error, {:unavailable, reason}}` when the model is not ready, and
  `{:error, {:invalid_query, message}}` when the model rejects the query.

  ## Examples

      query =
        SystemOne.Query.new(%{message: "Hello"}, [
          SystemOne.Question.new(:greeting, :noul, "Is this a greeting?")
        ])

      {:ok, result} = SystemOne.query(MyApp.SystemOne, query)
      result.answers.greeting.noul
      #=> 0.97

  """
  @spec query(name(), Query.t()) :: {:ok, SystemOne.Result.t()} | {:error, query_error()}
  def query(name, %Query{} = query) do
    metadata = %{name: name, questions_count: length(query.questions)}

    :telemetry.span([:system_one, :query], metadata, fn ->
      result = run_query(name, query)
      {result, Map.put(metadata, :status, status_for(result))}
    end)
  end

  @doc """
  Previews token usage and sequence layout for `query` on the instance `name`.

  Runs tokenization on the CPU using the instance's loaded tokenizer and
  configuration, without performing model inference or touching the GPU.

  Returns `{:ok, %SystemOne.Preview{}}` or `{:error, reason}`.

  ## Examples

      query =
        SystemOne.Query.new(%{message: "Hello"}, [
          SystemOne.Question.new(:greeting, :noul, "Is this a greeting?")
        ])

      {:ok, preview} = SystemOne.preview(MyApp.SystemOne, query)
      preview.total_tokens
      #=> 24

      preview.questions[:greeting].header_tokens
      #=> 17

      preview.questions[:greeting].truncated?
      #=> false

  """
  @spec preview(name(), Query.t()) :: {:ok, Preview.t()} | {:error, term()}
  def preview(name, %Query{} = query) do
    case :persistent_term.get({SystemOne, name, :preview}, nil) do
      preview_fn when is_function(preview_fn, 1) ->
        preview_fn.(query)

      nil ->
        Manager.preview(name, query)
    end
  end

  @doc """
  Returns the current `SystemOne.Status` of the instance `name`.
  """
  @spec status(name()) :: Status.t()
  def status(name), do: Manager.status(name)

  @doc """
  Subscribes the caller to status changes of the instance `name`.

  The caller receives the current status at once, and again on every change:

      {:system_one, name, %SystemOne.Status{}}

  The subscription ends when the caller exits.
  """
  @spec subscribe(name()) :: :ok
  def subscribe(name), do: Manager.subscribe(name)

  @doc """
  Unsubscribes the caller from status changes of the instance `name`.
  """
  @spec unsubscribe(name()) :: :ok
  def unsubscribe(name), do: Manager.unsubscribe(name)

  @doc """
  Blocks until the instance `name` is ready.

  Returns `{:ok, status}` when the model is ready, `{:error, :timeout}` when
  the timeout expires first, and `{:error, {:unavailable, reason}}` when the
  load fails or the instance is stopped.

  ## Options

    * `:timeout` - how long to wait, in milliseconds. Defaults to `30_000`.

  """
  @spec await_ready(name(), keyword()) :: {:ok, Status.t()} | {:error, term()}
  def await_ready(name, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @await_ready_schema)
    Manager.await_ready(name, opts[:timeout])
  end

  @doc """
  Loads the model again, optionally with new options.

  `overrides` accepts the same options as `start_link/1`, except `:name`.
  They are merged into the current options, so you can switch `:model` or
  `:model_dir` without repeating the rest.

  Blocks until the new model is ready or fails. While it loads, queries
  return `{:error, {:unavailable, :loading}}`. Returns `{:error, :loading}`
  if a load is already in progress.
  """
  @spec reload(name(), keyword()) :: :ok | {:error, term()}
  def reload(name, overrides \\ []) do
    overrides = NimbleOptions.validate!(overrides, @reload_schema)
    Manager.reload(name, overrides)
  end

  @doc """
  Unloads the model of the instance `name`.

  The instance stays in the supervision tree with status `:stopped`, and
  queries return `{:error, {:unavailable, :stopped}}`. Call `reload/2` to
  load the model again.
  """
  @spec stop(name()) :: :ok
  def stop(name), do: Manager.stop(name)

  defp run_query(name, query) do
    case Manager.serving(name) do
      {:ok, serving} ->
        try do
          {:ok, Nx.Serving.batched_run({:local, serving}, query)}
        rescue
          exception in ArgumentError ->
            {:error, {:invalid_query, Exception.message(exception)}}

          exception ->
            {:error, {:unavailable, {:serving_error, Exception.message(exception)}}}
        catch
          :exit, reason -> {:error, {:unavailable, {:serving_exit, reason}}}
        end

      {:error, reason} ->
        {:error, {:unavailable, reason}}
    end
  end

  defp status_for({:ok, _}), do: :ok
  defp status_for({:error, _}), do: :error
end
