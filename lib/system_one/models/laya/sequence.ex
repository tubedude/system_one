defmodule SystemOne.Models.Laya.Sequence do
  @moduledoc false

  alias SystemOne.Question

  @qtypes %{choice: 0, score: 1, noul: 2}

  @spec qtype(Question.t()) :: non_neg_integer()
  def qtype(%Question{type: type}), do: Map.fetch!(@qtypes, type)

  @spec normalize(Question.t()) :: {:ok, Question.t()} | {:error, String.t()}
  def normalize(%Question{type: type, instructions: instructions} = question)
      when type in [:choice, :score, :noul] do
    with {:ok, instructions} <- normalize_instructions(instructions),
         {:ok, criteria} <- normalize_criteria(type, question.criteria) do
      {:ok, %{question | instructions: instructions, criteria: criteria}}
    end
  end

  def normalize(_), do: {:error, "question type must be :choice, :score, or :noul"}

  @spec render_options(Question.t()) :: [String.t()]
  def render_options(%Question{type: :choice, criteria: criteria}) do
    Enum.map(criteria, fn
      {label, nil} -> label
      {label, ""} -> label
      {label, description} -> "#{label}: #{description}"
    end)
  end

  def render_options(%Question{type: :score, criteria: criteria}) do
    criteria
    |> Enum.with_index()
    |> Enum.map(fn {description, index} -> "level #{index}: #{description}" end)
  end

  def render_options(%Question{type: :noul, criteria: criteria}) do
    [
      "false: " <> Map.get(criteria, false, "no, the statement does not hold"),
      "true: " <> Map.get(criteria, true, "yes, the statement holds")
    ]
  end

  @spec labels(Question.t()) :: [String.t()]
  def labels(%Question{type: :choice, criteria: criteria}), do: Enum.map(criteria, &elem(&1, 0))

  def labels(%Question{type: :score, criteria: criteria}) do
    criteria
    |> Enum.with_index()
    |> Enum.map(fn {_criterion, index} -> Integer.to_string(index) end)
  end

  def labels(%Question{type: :noul}), do: ["false", "true"]

  @spec build((String.t() -> [non_neg_integer()]), Question.t(), term(), map(), map()) ::
          {:ok, %{ids: [non_neg_integer()], markers: [non_neg_integer()]}}
          | {:error, String.t()}
  def build(encode, question, state, special_ids, config) do
    with {:ok, header} <- header(encode, question, special_ids, config),
         {:ok, serialized_state} <- serialize_state(state) do
      state_ids =
        encode.(scrub(serialized_state, special_ids.mask_token)) |> Enum.take(header.room)

      ids = header.sequence ++ state_ids ++ [special_ids.sep]
      {:ok, %{ids: ids, markers: Enum.filter(header.markers, &(&1 < config.max_len))}}
    end
  end

  @doc false
  @spec preview(
          (String.t() -> [non_neg_integer()]),
          Question.t(),
          [non_neg_integer()],
          map(),
          map()
        ) :: {:ok, SystemOne.Preview.question_preview()} | {:error, String.t()}
  def preview(encode, question, state_ids, special_ids, config) when is_list(state_ids) do
    with {:ok, header} <- header(encode, question, special_ids, config) do
      header_tokens = length(header.sequence)
      raw_state_tokens = length(state_ids)
      state_tokens = min(header.room, raw_state_tokens)
      truncated_tokens = raw_state_tokens - state_tokens

      {:ok,
       %{
         question_id: question.id,
         type: question.type,
         header_tokens: header_tokens,
         state_tokens: state_tokens,
         raw_state_tokens: raw_state_tokens,
         truncated_tokens: truncated_tokens,
         truncated?: truncated_tokens > 0,
         total_tokens: header_tokens + state_tokens + 1,
         room: header.room
       }}
    end
  end

  # Builds the fixed part of a sequence: [CLS] head [SEP] options... [SEP].
  # `room` is how many state tokens fit after it, leaving one slot for the final [SEP].
  # `build/5` and `preview/5` both use this so their token counts cannot drift apart.
  defp header(encode, question, special_ids, config) do
    option_ids =
      question
      |> render_options()
      |> Enum.map(fn option ->
        [
          special_ids.mask
          | encode.(" " <> scrub(option, special_ids.mask_token)) |> Enum.take(48)
        ]
      end)

    head =
      encode.(
        "#{question.type} question: #{scrub(question.instructions, special_ids.mask_token)}"
      )

    head_max_len = min(config.head_max_len, config.max_len - 4)
    {head, option_ids} = fit_head(head, option_ids, head_max_len)

    if Enum.sum(Enum.map(option_ids, &length/1)) + length(head) > head_max_len do
      {:error, "options do not fit in head_max_len=#{head_max_len} tokens"}
    else
      sequence = [special_ids.cls | head] ++ [special_ids.sep]

      {sequence, markers} =
        Enum.reduce(option_ids, {sequence, []}, fn option, {acc, markers} ->
          {acc ++ option, markers ++ [length(acc)]}
        end)

      sequence = sequence ++ [special_ids.sep]
      room = max(0, config.max_len - length(sequence) - 1)
      {:ok, %{sequence: sequence, markers: markers, room: room}}
    end
  end

  @spec temperature_bucket(atom(), pos_integer()) :: String.t()
  def temperature_bucket(type, count) do
    bucket =
      cond do
        count <= 2 -> "2"
        count <= 5 -> "3-5"
        count <= 10 -> "6-10"
        true -> "11+"
      end

    "#{type}:#{bucket}"
  end

  @spec confidence([float()]) :: float()
  def confidence(probabilities) when length(probabilities) < 2, do: 1.0

  def confidence(probabilities) do
    entropy =
      Enum.reduce(probabilities, 0.0, fn p, acc -> acc - p * :math.log(max(p, 1.0e-12)) end)

    min(1.0, max(0.0, 1.0 - entropy / :math.log(length(probabilities))))
  end

  def serialize_state(state) when is_binary(state), do: {:ok, state}

  def serialize_state(state) do
    case Jason.encode(state) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, "state must be a string or JSON-encodable value"}
    end
  end

  defp normalize_instructions(value) when is_binary(value), do: {:ok, value}

  defp normalize_instructions(value) when is_map(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, "instructions map must be JSON-encodable"}
    end
  end

  defp normalize_instructions(_), do: {:error, "instructions must be a string or map"}

  defp normalize_criteria(:choice, criteria) when is_list(criteria) and criteria != [] do
    normalized =
      Enum.map(criteria, fn
        {label, description}
        when is_binary(label) and (is_binary(description) or is_nil(description)) ->
          {label, description}

        label when is_binary(label) ->
          {label, nil}

        _ ->
          :invalid
      end)

    if :invalid in normalized,
      do: {:error, "choice criteria must be strings or label tuples"},
      else: {:ok, normalized}
  end

  defp normalize_criteria(:choice, criteria) when is_map(criteria) do
    normalize_criteria(:choice, Enum.sort_by(criteria, &elem(&1, 0)))
  end

  defp normalize_criteria(:choice, _), do: {:error, "choice requires non-empty criteria"}

  defp normalize_criteria(:score, criteria) when is_list(criteria) and criteria != [] do
    if Enum.all?(criteria, &is_binary/1),
      do: {:ok, criteria},
      else: {:error, "score criteria must be strings"}
  end

  defp normalize_criteria(:score, _), do: {:error, "score requires ordered criteria"}
  defp normalize_criteria(:noul, nil), do: {:ok, %{}}

  defp normalize_criteria(:noul, criteria) when is_map(criteria) do
    if Enum.all?(criteria, fn {key, value} -> key in [true, false] and is_binary(value) end) do
      {:ok, criteria}
    else
      {:error, "noul criteria supports only boolean keys and string values"}
    end
  end

  defp normalize_criteria(:noul, _), do: {:error, "noul criteria must be a map"}

  defp fit_head(head, option_ids, head_max_len) do
    budget = head_max_len - Enum.sum(Enum.map(option_ids, &length/1))

    {option_ids, budget} =
      if budget < 16 do
        per_option = max(4, div(head_max_len - 16, max(1, length(option_ids))))
        option_ids = Enum.map(option_ids, &Enum.take(&1, per_option))
        {option_ids, head_max_len - Enum.sum(Enum.map(option_ids, &length/1))}
      else
        {option_ids, budget}
      end

    {Enum.take(head, max(8, budget)), option_ids}
  end

  def scrub(string, token), do: String.replace(string, token, " ")
end
