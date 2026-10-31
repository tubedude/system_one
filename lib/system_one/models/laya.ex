defmodule SystemOne.Models.Laya do
  @moduledoc """
  Serves the [Laya](https://huggingface.co/receptron/laya-onnx) ONNX model.

  Laya is a small encoder that answers `:choice`, `:score`, and `:noul`
  questions in one forward pass. It runs on ONNX Runtime through Ortex.

  Install the bundle first:

      mix system_one.install laya --dir priv/models/laya

  Then start an instance:

      {SystemOne,
       name: MyApp.SystemOne,
       model: SystemOne.Models.Laya,
       model_dir: "priv/models/laya"}

  ## Options

    * `:model_dir` - required. The installed bundle directory.
    * `:execution_providers` - defaults to `[:cpu]`. See the
      [GPU guide](gpu.md) to use `:cuda`.
    * `:batch_size` - defaults to `64`.
    * `:batch_timeout` - defaults to `10` milliseconds.

  ## Limits

  A query must contain between 1 and 64 questions. A `:choice` or `:score`
  question must have between 1 and 20 options; a `:noul` question always has
  two model options.

  Every question is encoded independently into at most 512 tokens. Its
  instructions and rendered options share a 192-token header budget. Each
  option is initially capped at 48 tokens and may be shortened further to fit
  the header. The serialized state uses the remaining sequence budget and is
  silently truncated when necessary. `result.usage.input_tokens` reports the
  post-truncation total across all questions.

  Question IDs should be unique because answers are returned in a map keyed
  by ID. Duplicate IDs overwrite earlier answers.

  The 512-token limit is applied after serialization and tokenization. Laya
  does not impose a byte or character limit on the original input, so callers
  accepting untrusted data should enforce an application-level request-size
  limit first.

  Each answer has `:act_probability` in its metadata.
  """

  @behaviour SystemOne.Model

  alias SystemOne.{Answer, Preview, Query, Result}
  alias SystemOne.Bundle.Manifest
  alias SystemOne.Models.Laya.Sequence

  @max_questions 64
  @max_options 20
  @bundle_schema 1
  @default_revision "68f27dfe5a27a54fb2b1fefc432f43f972e90868"
  @files [
    %{
      path: "laya.onnx",
      sha256: "a874eb254b58b0fcb1e7ad56fbb188c29d64e08c9a46b689433e1f52c66dba1e"
    },
    %{
      path: "laya.onnx.data",
      sha256: "487746363a8da57bcadb4345352997d22a0fb90d70aa22c6856668d023242aba"
    },
    %{
      path: "laya_config.json",
      sha256: "5049005dc6ae3ca5e82cc7d85c421357d5c543817300c8e8c5281ddbc69bb561"
    },
    %{
      path: "tokenizer/tokenizer.json",
      sha256: "6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30"
    },
    %{
      path: "tokenizer/tokenizer_config.json",
      sha256: "50044de60daaa73df97d262e15a40d4faf0160e7d742df64b377877a1320dd12"
    }
  ]

  @impl true
  def model_name, do: "laya"

  @impl true
  def bundle_schema, do: @bundle_schema

  @impl true
  def manifest(version) when version in [:default, "default", "2026-06"] do
    {:ok,
     %Manifest{
       schema: @bundle_schema,
       model: :laya,
       version: "2026-06",
       base_url: "https://huggingface.co/receptron/laya-onnx/resolve",
       revision: @default_revision,
       files: @files
     }}
  end

  def manifest(version), do: {:error, {:unknown_version, version}}

  @impl true
  def load(opts) do
    with {:ok, directory} <- bundle_dir(opts),
         :ok <- validate_installed_manifest(directory),
         {:ok, config} <- read_config(directory),
         {:ok, tokenizer} <-
           Tokenizers.Tokenizer.from_file(Path.join(directory, "tokenizer/tokenizer.json")),
         {:ok, ids} <- special_ids(tokenizer) do
      model =
        Ortex.load(
          Path.join(directory, "laya.onnx"),
          Keyword.get(opts, :execution_providers, [:cpu])
        )

      runtime = %{config: config, tokenizer: tokenizer, ids: ids}

      serving =
        Nx.Serving.new(Ortex.Serving, model)
        |> Nx.Serving.client_preprocessing(&preprocess(&1, runtime))
        |> Nx.Serving.client_postprocessing(&postprocess/2)

      serving_opts = [
        batch_size: Keyword.get(opts, :batch_size, 64),
        batch_timeout: Keyword.get(opts, :batch_timeout, 10),
        batch_keys: batch_keys(config.max_len),
        preview: fn query -> preview(query, runtime) end
      ]

      {:ok, serving, serving_opts}
    end
  end

  @doc """
  Previews token usage and sequence layout for `query` with Laya.

  Calculates token budgets, limits, and truncation on the CPU without loading
  model weights or touching the GPU.

  `opts` accepts:
    * `:model_dir` - the bundle directory containing `tokenizer/` and `laya_config.json`.
    * `:runtime` - an internal runtime map with preloaded config and tokenizer.
  """
  @impl true
  def preview(query, opts)

  def preview(%Query{} = query, opts) when is_list(opts) do
    case Keyword.get(opts, :runtime) do
      %{config: _, tokenizer: _, ids: _} = runtime ->
        preview(query, runtime)

      nil ->
        with {:ok, directory} <- preview_bundle_dir(opts),
             {:ok, config} <- read_config(directory),
             {:ok, tokenizer} <-
               Tokenizers.Tokenizer.from_file(Path.join(directory, "tokenizer/tokenizer.json")),
             {:ok, ids} <- special_ids(tokenizer) do
          preview(query, %{config: config, tokenizer: tokenizer, ids: ids})
        end
    end
  end

  def preview(%Query{questions: []}, _runtime),
    do: {:error, {:invalid_query, "at least one question is required"}}

  def preview(%Query{questions: questions}, _runtime) when length(questions) > @max_questions,
    do: {:error, {:invalid_query, "Laya accepts at most #{@max_questions} questions"}}

  def preview(%Query{state: state, questions: questions}, runtime) when is_map(runtime) do
    with {:ok, serialized_state} <- Sequence.serialize_state(state) do
      state_ids =
        encode(runtime.tokenizer, Sequence.scrub(serialized_state, runtime.ids.mask_token))

      with {:ok, question_previews} <-
             preview_questions(questions, state_ids, runtime) do
        longest = Enum.map(question_previews, & &1.total_tokens) |> Enum.max()

        target_len =
          Enum.find(batch_keys(runtime.config.max_len), runtime.config.max_len, &(&1 >= longest))

        total_tokens = Enum.sum(Enum.map(question_previews, & &1.total_tokens))
        truncated? = Enum.any?(question_previews, & &1.truncated?)

        preview = %Preview{
          total_tokens: total_tokens,
          target_sequence_length: target_len,
          truncated?: truncated?,
          questions: Map.new(question_previews, &{&1.question_id, &1}),
          ordered_questions: question_previews
        }

        {:ok, preview}
      end
    else
      {:error, reason} ->
        {:error, {:invalid_query, reason}}
    end
  end

  defp preview_bundle_dir(opts) do
    required = ["laya_config.json", "tokenizer/tokenizer.json"]

    case Keyword.get(opts, :model_dir) do
      directory when is_binary(directory) and directory != "" ->
        missing = Enum.reject(required, &File.regular?(Path.join(directory, &1)))
        if missing == [], do: {:ok, directory}, else: {:error, {:missing_bundle_files, missing}}

      _ ->
        {:error, :model_dir_required}
    end
  end

  defp preview_questions(questions, state_ids, runtime) do
    Enum.reduce_while(questions, {:ok, []}, fn raw, {:ok, acc} ->
      case preview_question(raw, state_ids, runtime) do
        {:ok, preview} ->
          {:cont, {:ok, [preview | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_query, reason}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = error -> error
    end
  end

  defp preview_question(raw, state_ids, runtime) do
    with {:ok, question} <- Sequence.normalize(raw),
         :ok <- check_option_count(raw.id, question) do
      Sequence.preview(
        &encode(runtime.tokenizer, &1),
        question,
        state_ids,
        runtime.ids,
        runtime.config
      )
    end
  end

  defp check_option_count(id, question) do
    if length(Sequence.render_options(question)) <= @max_options,
      do: :ok,
      else: {:error, "question #{inspect(id)} has more than #{@max_options} options"}
  end

  defp bundle_dir(opts) do
    required = Enum.map(@files, & &1.path)

    case Keyword.get(opts, :model_dir) do
      directory when is_binary(directory) and directory != "" ->
        missing = Enum.reject(required, &File.regular?(Path.join(directory, &1)))
        if missing == [], do: {:ok, directory}, else: {:error, {:missing_bundle_files, missing}}

      _ ->
        {:error, :model_dir_required}
    end
  end

  defp validate_installed_manifest(directory) do
    path = Manifest.path(directory)

    with {:ok, contents} <- File.read(path),
         {:ok, %Manifest{schema: @bundle_schema}} <- Manifest.decode(contents, __MODULE__) do
      :ok
    else
      {:ok, %Manifest{schema: schema}} -> {:error, {:unsupported_bundle_schema, schema}}
      {:error, :enoent} -> {:error, :missing_bundle_manifest}
      {:error, reason} -> {:error, {:invalid_bundle_manifest, reason}}
    end
  end

  defp read_config(directory) do
    with {:ok, contents} <- File.read(Path.join(directory, "laya_config.json")),
         {:ok, raw} <- Jason.decode(contents),
         {:ok, max_len} <- positive_integer(raw, "max_len"),
         {:ok, head_max_len} <- positive_integer(raw, "head_max_len"),
         true <- head_max_len <= max_len || {:error, :head_max_len_exceeds_max_len},
         {:ok, temperature} <- temperatures(raw["temperature"]),
         {:ok, by_options} <- optional_temperatures(raw["temperature_by_options"] || %{}) do
      {:ok,
       %{
         max_len: max_len,
         head_max_len: head_max_len,
         temperature: temperature,
         temperature_by_options: by_options
       }}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_config}
    end
  end

  defp positive_integer(map, key) do
    case map[key] do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp temperatures([choice, score, noul]) do
    if Enum.all?([choice, score, noul], &positive_number?/1) do
      {:ok, %{choice: choice, score: score, noul: noul}}
    else
      {:error, :invalid_temperatures}
    end
  end

  defp temperatures(_), do: {:error, :invalid_temperatures}

  defp optional_temperatures(map) when is_map(map) do
    if Enum.all?(map, fn {key, value} -> is_binary(key) and positive_number?(value) end),
      do: {:ok, map},
      else: {:error, :invalid_temperature_overrides}
  end

  defp optional_temperatures(_), do: {:error, :invalid_temperature_overrides}
  defp positive_number?(number), do: is_number(number) and number > 0

  defp special_ids(tokenizer) do
    case Enum.map(
           ["[CLS]", "[SEP]", "[MASK]", "[PAD]"],
           &Tokenizers.Tokenizer.token_to_id(tokenizer, &1)
         ) do
      [cls, sep, mask, pad]
      when is_integer(cls) and is_integer(sep) and is_integer(mask) and is_integer(pad) ->
        {:ok, %{cls: cls, sep: sep, mask: mask, pad: pad, mask_token: "[MASK]"}}

      _ ->
        {:error, :missing_special_tokens}
    end
  end

  defp preprocess(%Query{state: state, questions: questions}, runtime) when questions != [] do
    if length(questions) > @max_questions do
      raise ArgumentError, "Laya accepts at most #{@max_questions} questions"
    end

    prepared =
      Enum.map(questions, fn raw ->
        with {:ok, question} <- Sequence.normalize(raw),
             true <- length(Sequence.render_options(question)) <= @max_options,
             {:ok, sequence} <-
               Sequence.build(
                 &encode(runtime.tokenizer, &1),
                 question,
                 state,
                 runtime.ids,
                 runtime.config
               ) do
          %{question: question, sequence: sequence}
        else
          false ->
            raise ArgumentError,
                  "question #{inspect(raw.id)} has more than #{@max_options} options"

          {:error, reason} ->
            raise ArgumentError, "invalid question #{inspect(raw.id)}: #{inspect(reason)}"
        end
      end)

    target_len = target_sequence_length(prepared, runtime.config.max_len)
    tensors = input_tensors(prepared, runtime, target_len)
    batch = Nx.Batch.concatenate([tensors]) |> Nx.Batch.key(target_len)
    tokens = Enum.sum(Enum.map(prepared, &length(&1.sequence.ids)))
    {batch, %{questions: prepared, config: runtime.config, input_tokens: tokens}}
  end

  defp preprocess(%Query{}, _runtime),
    do: raise(ArgumentError, "at least one question is required")

  defp encode(tokenizer, text) do
    {:ok, encoding} = Tokenizers.Tokenizer.encode(tokenizer, text, add_special_tokens: false)
    Tokenizers.Encoding.get_ids(encoding)
  end

  defp input_tensors(prepared, runtime, target_len) do
    n = length(prepared)

    {ids, attention, markers, marker_mask, qtypes} =
      Enum.reduce(prepared, {[], [], [], [], []}, fn item,
                                                     {ids, attention, markers, masks, qtypes} ->
        sequence = item.sequence.ids
        positions = item.sequence.markers
        padding = List.duplicate(runtime.ids.pad, target_len - length(sequence))
        marker_padding = List.duplicate(0, @max_options - length(positions))

        {
          [sequence ++ padding | ids],
          [List.duplicate(1, length(sequence)) ++ List.duplicate(0, length(padding)) | attention],
          [positions ++ marker_padding | markers],
          [
            List.duplicate(1, length(positions)) ++ List.duplicate(0, length(marker_padding))
            | masks
          ],
          [Sequence.qtype(item.question) | qtypes]
        }
      end)

    {
      Nx.tensor(Enum.reverse(ids), type: {:s, 64}) |> Nx.reshape({n, target_len}),
      Nx.tensor(Enum.reverse(attention), type: {:s, 64}) |> Nx.reshape({n, target_len}),
      Nx.tensor(Enum.reverse(markers), type: {:s, 64}) |> Nx.reshape({n, @max_options}),
      Nx.tensor(Enum.reverse(marker_mask), type: {:u, 8}) |> Nx.reshape({n, @max_options}),
      Nx.tensor(Enum.reverse(qtypes), type: {:s, 64}) |> Nx.reshape({n})
    }
  end

  defp target_sequence_length(prepared, max_len) do
    longest = prepared |> Enum.map(&length(&1.sequence.ids)) |> Enum.max()
    Enum.find(batch_keys(max_len), max_len, &(&1 >= longest))
  end

  defp batch_keys(max_len),
    do: [64, 128, 256, max_len] |> Enum.map(&min(&1, max_len)) |> Enum.uniq()

  defp postprocess({{logits, act_probs}, _server_info}, metadata) do
    logits = Nx.to_flat_list(Nx.backend_transfer(logits))
    act_probs = Nx.to_flat_list(Nx.backend_transfer(act_probs))

    answers =
      metadata.questions
      |> Enum.with_index()
      |> Map.new(fn {%{question: question}, row} ->
        labels = Sequence.labels(question)
        values = Enum.slice(logits, row * @max_options, length(labels))
        temperature = temperature(question, length(labels), metadata.config)
        probabilities = softmax(Enum.map(values, &(&1 / temperature)))
        {question.id, answer(question, labels, probabilities, Enum.at(act_probs, row, 0.0))}
      end)

    %Result{
      model: :laya,
      answers: answers,
      usage: %{input_tokens: metadata.input_tokens, output_tokens: 0}
    }
  end

  defp temperature(question, count, config) do
    Map.get(
      config.temperature_by_options,
      Sequence.temperature_bucket(question.type, count),
      Map.fetch!(config.temperature, question.type)
    )
  end

  defp answer(%{type: :choice} = question, labels, probabilities, act_probability) do
    {choice, _} = Enum.zip(labels, probabilities) |> Enum.max_by(&elem(&1, 1))

    %Answer{
      question_id: question.id,
      type: :choice,
      choice: choice,
      probabilities: probability_map(labels, probabilities),
      confidence: round4(Sequence.confidence(probabilities)),
      metadata: %{act_probability: act_probability}
    }
  end

  defp answer(%{type: :score} = question, labels, probabilities, act_probability) do
    score =
      Enum.with_index(probabilities)
      |> Enum.sum_by(fn {probability, index} -> probability * index end)

    %Answer{
      question_id: question.id,
      type: :score,
      score: round4(score),
      probabilities: probability_map(labels, probabilities),
      confidence: round4(Sequence.confidence(probabilities)),
      legend: Map.new(Enum.zip(labels, question.criteria)),
      metadata: %{act_probability: act_probability}
    }
  end

  defp answer(%{type: :noul} = question, labels, probabilities, act_probability) do
    %Answer{
      question_id: question.id,
      type: :noul,
      noul: round4(Enum.at(probabilities, 1)),
      probabilities: probability_map(labels, probabilities),
      metadata: %{act_probability: act_probability}
    }
  end

  defp probability_map(labels, values), do: Map.new(Enum.zip(labels, Enum.map(values, &round4/1)))

  defp softmax(values) do
    maximum = Enum.max(values)
    exponents = Enum.map(values, &:math.exp(&1 - maximum))
    total = Enum.sum(exponents)
    Enum.map(exponents, &(&1 / total))
  end

  defp round4(value), do: Float.round(value, 4)
end
