defmodule SystemOne.Result do
  @moduledoc """
  The result of `SystemOne.query/2`.

  `answers` maps each question id to a `SystemOne.Answer`. `usage` and
  `metadata` hold model-specific details.

      {:ok, result} = SystemOne.query(MyApp.SystemOne, query)

      result.answers.sentiment.choice
      #=> "positive"

      result.answers.urgency.score
      #=> 1.24

      result.answers.spam.noul
      #=> 0.03

  """

  alias SystemOne.Answer

  @enforce_keys [:model, :answers]
  defstruct [:model, answers: %{}, usage: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          model: atom() | String.t(),
          answers: %{required(String.t() | atom()) => Answer.t()},
          usage: map(),
          metadata: map()
        }
end
