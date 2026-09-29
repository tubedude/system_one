defmodule SystemOne.Query do
  @moduledoc """
  A set of questions about one piece of application state.

  `state` is the data the model reads, such as a message or a map. The model
  answers every question in `questions` against it. Individual model modules
  define their own input limits and serialization requirements.

      SystemOne.Query.new(%{from: "alice", body: "Can we meet today?"}, [
        SystemOne.Question.new(:urgent, :noul, "Is this urgent?")
      ])

  """

  alias SystemOne.Question

  @enforce_keys [:state, :questions]
  defstruct [:state, :questions]

  @type t :: %__MODULE__{state: term(), questions: [Question.t()]}

  @doc """
  Builds a query.
  """
  @spec new(term(), [Question.t()]) :: t()
  def new(state, questions) when is_list(questions) do
    %__MODULE__{state: state, questions: questions}
  end
end
