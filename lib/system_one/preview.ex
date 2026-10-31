defmodule SystemOne.Preview do
  @moduledoc """
  The result of a `SystemOne.preview/2` or `SystemOne.Models.Laya.preview/2`.

  Provides token allocation, limits, and truncation details without running
  model inference or touching the GPU.

  ## Fields

    * `:total_tokens` - the total number of input tokens across all questions.
      Matches `result.usage.input_tokens` if the query were executed.
    * `:target_sequence_length` - the padding bucket the model will pad each
      question sequence to (such as 64, 128, 256, or 512).
    * `:truncated?` - boolean indicating if any question's state was truncated.
    * `:questions` - a map of question IDs to their token breakdown.
    * `:ordered_questions` - a list of question breakdowns in the query's original order.

  Each question breakdown map contains:

    * `:question_id` - the ID of the question.
    * `:type` - question type (`:choice`, `:score`, or `:noul`).
    * `:header_tokens` - tokens consumed by prompt header (`[CLS]`, instructions,
      rendered options with `[MASK]`, and separator tokens).
    * `:state_tokens` - tokens of state included after truncation.
    * `:raw_state_tokens` - tokens the state would consume before truncation.
    * `:truncated_tokens` - number of discarded state tokens (`raw_state_tokens - state_tokens`).
    * `:truncated?` - boolean indicating if this question's state was truncated.
    * `:total_tokens` - total sequence tokens (`header_tokens + state_tokens + 1`).
    * `:room` - maximum tokens available for state in this question.

  """

  @type question_preview :: %{
          question_id: String.t() | atom(),
          type: SystemOne.Question.question_type(),
          header_tokens: non_neg_integer(),
          state_tokens: non_neg_integer(),
          raw_state_tokens: non_neg_integer(),
          truncated_tokens: non_neg_integer(),
          truncated?: boolean(),
          total_tokens: non_neg_integer(),
          room: non_neg_integer()
        }

  @type t :: %__MODULE__{
          total_tokens: non_neg_integer(),
          target_sequence_length: pos_integer() | nil,
          truncated?: boolean(),
          questions: %{required(String.t() | atom()) => question_preview()},
          ordered_questions: [question_preview()]
        }

  defstruct [
    :total_tokens,
    :target_sequence_length,
    :truncated?,
    questions: %{},
    ordered_questions: []
  ]
end
