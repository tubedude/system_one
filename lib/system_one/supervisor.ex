defmodule SystemOne.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(name))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    serving_supervisor = serving_supervisor_name(name)

    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: serving_supervisor},
      {SystemOne.Manager, Keyword.put(opts, :serving_supervisor, serving_supervisor)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp supervisor_name(name), do: Module.concat(name, Supervisor)
  defp serving_supervisor_name(name), do: Module.concat(name, ServingSupervisor)
end
