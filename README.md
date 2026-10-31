# SystemOne

Supervised serving of small local decision models with Nx.

SystemOne asks a model typed questions about your application data and
returns probabilities. Queries are batched by `Nx.Serving` and run on your
machine. The first supported model is
[Laya](https://huggingface.co/receptron/laya-onnx), served with
[Transmuter](https://hexdocs.pm/transmuter) on EXLA.

> #### Backend change in v0.2.0 {: .info}
>
> v0.2.0 replaces Ortex with Transmuter. See
> [the comparison report](bench/transmuter/REPORT.md). The last Ortex version
> is v0.1.1, also tagged `ortex`.

## Installation

SystemOne requires Elixir 1.18 or later. Laya's bundle is approximately
1.6 GB, so allow enough disk space for both the download and a temporary
copy while it is installed. CPU inference also adds roughly 1.6 GB of
resident memory. GPU requirements are listed in the [GPU guide](guides/gpu.md).

Add `system_one` to your dependencies:

```elixir
def deps do
  [
    {:system_one, "~> 0.2.1"}
  ]
end
```

Then download the Laya model files:

```console
$ mix system_one.install laya
```

The files go to `priv/models/laya` and are checked against pinned SHA-256
checksums. The directory is intentionally ignored by this repository: do not
commit model weights to Git. See `mix help system_one.install` for alternate
directories, versions, private-download tokens, and pinned external manifests.

## Usage

For an interactive walkthrough, open
[`notebooks/getting_started.livemd`](notebooks/getting_started.livemd) in
[Livebook](https://livebook.dev/).

### AI coding agents

SystemOne ships [`usage-rules.md`](usage-rules.md) for the
[`usage_rules`](https://github.com/ash-project/usage_rules) package. A consumer
can synchronize SystemOne's package-specific guidance into its agent rules:

```elixir
# mix.exs
def project do
  [
    # ...
    usage_rules: [file: "AGENTS.md", usage_rules: [:system_one]]
  ]
end

defp deps do
  [
    {:system_one, "~> 0.2.1"},
    {:usage_rules, "~> 1.1", only: :dev, runtime: false}
  ]
end
```

Then run:

```console
$ mix usage_rules.sync
```

This copies the rules from the installed SystemOne dependency into the
consumer's `AGENTS.md`; SystemOne itself does not depend on `usage_rules` at
runtime.

Add an instance to your supervision tree:

```elixir
children = [
  {SystemOne,
   name: MyApp.SystemOne,
   model: SystemOne.Models.Laya,
   model_dir: Application.app_dir(:my_app, "priv/models/laya")}
]
```

Replace `:my_app` with your OTP application name. During development this
resolves to the same application `priv` directory that Mix populates. Use
`Application.app_dir/2` because relative paths such as `"priv/models/laya"`
may point to the wrong location in a release.

Then ask it questions:

```elixir
alias SystemOne.{Query, Question}

{:ok, _status} = SystemOne.await_ready(MyApp.SystemOne, timeout: 60_000)

query =
  Query.new(%{message: "The server is down again!"}, [
    Question.new(:sentiment, :choice, "How does this message feel?",
      criteria: ["positive", "neutral", "negative"]
    ),
    Question.new(:urgency, :score, "How urgent is this?",
      criteria: ["can wait", "today", "right now"]
    ),
    Question.new(:spam, :noul, "Is this spam?")
  ])

result =
  case SystemOne.query(MyApp.SystemOne, query) do
    {:ok, result} ->
      result

    {:error, {:invalid_query, message}} ->
      raise "invalid question: #{message}"

    {:error, {:unavailable, reason}} ->
      raise "model unavailable: #{inspect(reason)}"
  end

result.answers.sentiment.choice
#=> "negative"

result.answers.urgency.score
#=> 1.82

result.answers.spam.noul
#=> 0.02
```

The model loads in the background. During loading, queries return
`{:error, {:unavailable, :loading}}`. `SystemOne.await_ready/2` is convenient
for boot-time checks; `SystemOne.subscribe/1` is better when an application
must remain responsive while the model loads. Inspect `SystemOne.status/1`
for the current state and load error.

## Answers and limits

Each answer includes the probabilities for all labels and a normalized
confidence value. The primary value depends on the question type:

  * `:choice` returns the most likely label in `answer.choice`.
  * `:score` returns the expected zero-based level in `answer.score`; it can
    be fractional. `answer.legend` maps levels back to their descriptions.
  * `:noul` returns the probability of “yes” in `answer.noul`, not a boolean.

Laya's input limits are:

  * Each query must contain between 1 and 64 questions.
  * A `:choice` or `:score` question must contain between 1 and 20 options.
    A `:noul` question always has two model options.
  * Each question is encoded independently into at most 512 model tokens.
  * The question instructions and all rendered options share a 192-token
    header budget. Each option is initially capped at 48 tokens and may be
    shortened further when all options do not fit.
  * The serialized state receives the tokens left after the header and
    structural tokens. Excess state is silently truncated.

Use a unique ID for every question. Answers are stored in a map keyed by ID,
so a duplicate ID overwrites an earlier answer.

Strings are accepted as state. Other state must be JSON-encodable;
instructions must be a string or JSON-encodable map. SystemOne limits the
encoded model sequence, but it does not impose a byte or character limit
before JSON encoding and tokenization. Applications accepting untrusted input
should enforce an appropriate request-size limit before building a query.

Invalid question counts, option counts, and value shapes return
`{:error, {:invalid_query, message}}`. Token truncation is not an error. The
actual post-truncation token total is available as `result.usage.input_tokens`.

### Token inspection and query preview

To inspect token counts, header budgets, and truncation before querying without
executing model inference or touching the GPU, use `SystemOne.preview/2`:

```elixir
{:ok, preview} = SystemOne.preview(MyApp.SystemOne, query)

preview.total_tokens
#=> 323

preview.target_sequence_length
#=> 512

preview.truncated?
#=> true

preview.questions[:sentiment].header_tokens
#=> 38

preview.questions[:sentiment].state_tokens
#=> 284

preview.questions[:sentiment].truncated_tokens
#=> 66
```

Previews run entirely on the CPU in fractions of a millisecond using the
instance's in-memory tokenizer. You can also run previews offline without
starting a supervised instance via `SystemOne.Models.Laya.preview/2`, which only
requires `tokenizer/tokenizer.json` and `laya_config.json` without loading the
1.6 GB model weights.

## Lifecycle and observability

`SystemOne.reload/2` reloads a model or changes its options without replacing
the supervised instance. `SystemOne.stop/1` unloads it. Status subscribers
receive messages shaped like:

```elixir
{:system_one, MyApp.SystemOne, %SystemOne.Status{state: :ready}}
```

Queries emit `[:system_one, :query, :start | :stop | :exception]` telemetry
events. See the `SystemOne` module documentation for their metadata.

## GPU

Laya runs on the CPU by default. On an NVIDIA GPU, a query with 8 questions
takes about 100 ms instead of 3 s. See the [GPU guide](guides/gpu.md) for
setup on Linux and WSL2, and [bench/](bench/README.md) for the numbers.

## Other models

A model is a module that implements the `SystemOne.Model` behaviour. It
returns an `Nx.Serving` that turns a `SystemOne.Query` into a
`SystemOne.Result`.

At minimum, implement `load/1`:

```elixir
defmodule MyApp.DecisionModel do
  @behaviour SystemOne.Model

  @impl true
  def load(opts) do
    serving =
      Nx.Serving.new(MyApp.DecisionServing, opts)
      |> Nx.Serving.client_preprocessing(&MyApp.DecisionServing.preprocess/1)
      |> Nx.Serving.client_postprocessing(&MyApp.DecisionServing.postprocess/2)

    {:ok, serving,
     batch_size: Keyword.get(opts, :batch_size, 8),
     batch_timeout: Keyword.get(opts, :batch_timeout, 10)}
  end
end
```

The preprocessing callback receives a `SystemOne.Query`; postprocessing must
return a `SystemOne.Result`. Raise `ArgumentError` during preprocessing to
return an `:invalid_query` error to the caller. Implement `manifest/1` as well
if the model should work with `SystemOne.Installer`. See the
`SystemOne.Model` and `SystemOne.Bundle.Manifest` API documentation for the
complete contracts.

## Deployment

Model files must exist before the supervised instance starts. For releases,
containers, external model volumes, and offline installation, see the
[deployment notes](guides/deployment.md). These are deployment patterns to
validate in your own environment, not a claim that a particular container or
release platform has been production-certified.

## Troubleshooting

  * **Queries return `:loading`:** call `await_ready/2`, or subscribe and wait
    for a `:ready` status before sending traffic.
  * **The status is `:failed`:** inspect `SystemOne.status(name).error`. Missing
    files usually mean installation and runtime used different directories.
  * **Checksum or manifest errors:** rerun `mix system_one.install laya`. Use
    `--force` only when you intend to replace the existing verified bundle.
  * **Private download fails:** set `HF_TOKEN` or pass `--token`.
  * **CUDA silently uses the CPU:** follow the verification commands in the
    GPU guide; readiness alone does not prove that CUDA loaded.
  * **A release cannot find the model:** use `Application.app_dir/2` for a
    bundled model or an absolute, configured directory for an external one.

## License

Copyright 2026 SystemOne contributors.

SystemOne is licensed under the Apache License, Version 2.0. See
[LICENSE](LICENSE).

The Laya model is not included in this package. `mix system_one.install`
downloads it from
[`receptron/laya-onnx`](https://huggingface.co/receptron/laya-onnx). Its model
card lists the weights as Apache-2.0. Read the model card before you
distribute the model files.
