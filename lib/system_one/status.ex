defmodule SystemOne.Status do
  @moduledoc """
  The status of a SystemOne instance.

  `state` is one of:

    * `:loading` - the model is loading. Queries are refused.
    * `:ready` - the model serves queries. `serving_pid` is set.
    * `:failed` - the load failed or the serving process exited. `error`
      holds the reason.
    * `:stopped` - the model was unloaded with `SystemOne.stop/1`.

  """

  @enforce_keys [:state, :model]
  defstruct [:state, :model, :serving_pid, :error]

  @type state :: :loading | :ready | :stopped | :failed

  @type t :: %__MODULE__{
          state: state(),
          model: module(),
          serving_pid: pid() | nil,
          error: term() | nil
        }
end
