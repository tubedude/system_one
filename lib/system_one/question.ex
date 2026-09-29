defmodule SystemOne.Question do
  @moduledoc """
  A question for the model to answer.

  There are three types:

    * `:choice` - picks one label from `:criteria`. Criteria are a list of
      labels, a list of `{label, description}` tuples, or a map of labels to
      descriptions.

    * `:score` - rates on an ordered scale. Criteria are a list of level
      descriptions, lowest first.

    * `:noul` - answers yes or no. Criteria are optional, and can be a map
      with `true` and `false` keys that describe each answer.

  ## Examples

      SystemOne.Question.new(:sentiment, :choice, "How does this message feel?",
        criteria: ["positive", "neutral", "negative"]
      )

      SystemOne.Question.new(:urgency, :score, "How urgent is this?",
        criteria: ["can wait", "today", "right now"]
      )

      SystemOne.Question.new(:spam, :noul, "Is this spam?")

  """

  @enforce_keys [:id, :type, :instructions]
  defstruct [:id, :type, :instructions, criteria: nil]

  @type question_type :: :choice | :score | :noul

  @type t :: %__MODULE__{
          id: String.t() | atom(),
          type: question_type(),
          instructions: String.t() | map(),
          criteria: term()
        }

  @doc """
  Builds a question.

  `id` is the key of the answer in `SystemOne.Result`. `instructions` is the
  question text, or a map that is encoded as JSON. IDs within a query should
  be unique; because answers are keyed by ID, a duplicate overwrites an
  earlier answer.

  ## Options

    * `:criteria` - the answer options. See the module documentation.

  """
  @spec new(String.t() | atom(), question_type(), String.t() | map(), keyword()) :: t()
  def new(id, type, instructions, opts \\ []) do
    %__MODULE__{
      id: id,
      type: type,
      instructions: instructions,
      criteria: Keyword.get(opts, :criteria)
    }
  end
end
