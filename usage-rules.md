# SystemOne usage rules

SystemOne supervises local `Nx.Serving` decision models. It does not provide
an HTTP server, download model files at application startup, or turn `:noul`
answers into booleans.

## Setup

- Install Laya before runtime with `mix system_one.install laya`.
- Do not commit `priv/models/`; the Laya bundle is approximately 1.6 GB.
- In a consumer application, resolve a bundled model with
  `Application.app_dir(:my_app, "priv/models/laya")`. For a mounted model,
  use an absolute path from runtime configuration.
- Add one `{SystemOne, ...}` child per model instance. `:name` must be a unique
  atom and is the handle passed to every public function.
- Laya uses `execution_providers: [:cpu]` by default. Do not add `:cuda`
  unless Ortex was built with CUDA support and the required runtime libraries
  are present.

```elixir
children = [
  {SystemOne,
   name: MyApp.SystemOne,
   model: SystemOne.Models.Laya,
   model_dir: Application.app_dir(:my_app, "priv/models/laya")}
]
```

## Readiness and errors

- Model loading is asynchronous. Starting the supervisor does not mean the
  model is ready.
- Before a synchronous workflow, call
  `SystemOne.await_ready(name, timeout: milliseconds)`.
- For a responsive application, call `SystemOne.subscribe/1` and handle
  `{:system_one, name, %SystemOne.Status{}}` messages.
- Do not blindly match only `{:ok, result}` in request-handling code. Handle:
  - `{:error, {:unavailable, :loading}}`
  - `{:error, {:unavailable, :stopped}}`
  - `{:error, {:unavailable, {:failed, reason}}}`
  - `{:error, {:invalid_query, message}}`
- Inspect `SystemOne.status/1` for lifecycle state and load failures.

## Constructing queries

- Build queries with `SystemOne.Query.new(state, questions)`.
- `state` may be a string or JSON-encodable value for Laya.
- Every question ID must be suitable as a key in `result.answers`; prefer
  stable atoms or strings and do not generate atoms from external input.
- Supported Laya question types are:
  - `:choice`: `criteria` is a non-empty list of labels, a list of
    `{label, description}` tuples, or a map of labels to descriptions.
  - `:score`: `criteria` is a non-empty ordered list, lowest level first.
  - `:noul`: criteria is optional; it may be a map with boolean keys and
    string descriptions.
- Laya requires 1–64 questions per query. `:choice` and `:score` require 1–20
  options; `:noul` always has two model options.
- Each question has a 512-token sequence. Instructions and rendered options
  share a 192-token header; each option is initially capped at 48 tokens and
  may be shortened further. Serialized state uses the remaining tokens and is
  silently truncated.
- `result.usage.input_tokens` is the post-truncation total across questions.
- To inspect token allocations and truncation before querying (e.g. in a UI),
  call `SystemOne.preview(name, query)`. It runs on the CPU without GPU or model
  inference. For offline preview, call `SystemOne.Models.Laya.preview(query, model_dir: path)`.
- There is no pre-tokenization byte limit. Enforce application request-size
  limits before constructing queries from untrusted input.

```elixir
query =
  SystemOne.Query.new(%{message: message}, [
    SystemOne.Question.new(:route, :choice, "Where should this go?",
      criteria: ["support", "sales", "other"]
    ),
    SystemOne.Question.new(:urgent, :noul, "Does this require an urgent response?")
  ])
```

## Reading answers

- Fetch an answer by the exact question ID: `result.answers[:route]` or
  `result.answers["route"]`.
- For `:choice`, use `answer.choice` for the selected label.
- For `:score`, use `answer.score`. It is a fractional expected zero-based
  level, not an integer category. Use `answer.legend` to interpret levels.
- For `:noul`, use `answer.noul`. It is the probability of “yes” from `0.0`
  to `1.0`, not a boolean. Apply an application-specific threshold only when
  the product requirements define one.
- `answer.probabilities` contains all label probabilities.
- `answer.confidence` measures concentration of the distribution; it is not
  correctness, calibration, or a substitute for application validation.
- Preserve `{:error, {:invalid_query, message}}` as a caller/input error.
  Treat `:unavailable` errors as lifecycle or serving failures.

## Lifecycle

- `SystemOne.reload/2` blocks until the replacement is ready or fails. During
  loading, queries are unavailable and a concurrent reload returns
  `{:error, :loading}`.
- `SystemOne.stop/1` unloads the serving but leaves the instance supervised.
  Use `reload/2` to load it again.
- Use `SystemOne.unsubscribe/1` when a long-lived subscribing process no
  longer needs status messages.
- Query telemetry uses the `[:system_one, :query]` span with `:start`, `:stop`,
  and `:exception` events.

## Custom models

- Implement the `SystemOne.Model` behaviour.
- `load/1` runs in a separate process and must return
  `{:ok, nx_serving, serving_options}` or `{:error, reason}`.
- The serving must accept a `SystemOne.Query` and return a
  `SystemOne.Result`.
- Raise `ArgumentError` during client preprocessing to report an invalid
  query. Other exceptions become serving failures.
- Implement `manifest/1` only if the model should integrate with
  `SystemOne.Installer`; optionally implement `model_name/0` and
  `bundle_schema/0`.
