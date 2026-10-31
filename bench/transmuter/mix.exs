defmodule TransmuterTry.MixProject do
  use Mix.Project
  def project, do: [app: :transmuter_try, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  def application, do: [extra_applications: [:logger]]
  defp deps, do: [{:transmuter, "~> 2.0"}, {:exla, "~> 1.0"}, {:nx, "~> 1.0"}]
end
