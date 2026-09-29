defmodule SystemOne.Answer do
  @moduledoc """
  The model's answer to one `SystemOne.Question`.

  The field that holds the answer depends on the question type:

    * `:choice` - `choice` is the most likely label.
    * `:score` - `score` is the expected level, from `0` to the number of
      criteria minus one. `legend` maps each level to its criterion.
    * `:noul` - `noul` is the probability that the answer is yes. It is a
      float, not a boolean.

  `probabilities` maps every label to its probability. `confidence`, when
  set, is `1.0` when all probability is on one label and `0.0` when it is
  spread evenly. `metadata` holds model-specific values.
  """

  @enforce_keys [:question_id, :type]
  defstruct [
    :question_id,
    :type,
    :choice,
    :score,
    :noul,
    :confidence,
    probabilities: %{},
    legend: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          question_id: String.t() | atom(),
          type: SystemOne.Question.question_type(),
          choice: String.t() | nil,
          score: float() | nil,
          noul: float() | nil,
          confidence: float() | nil,
          probabilities: %{optional(String.t()) => float()},
          legend: map(),
          metadata: map()
        }
end
