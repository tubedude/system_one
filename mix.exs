defmodule SystemOne.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/tubedude/system_one"

  def project do
    [
      app: :system_one,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [ignore_modules: [SystemOne.Models.Laya]],
      deps: deps(),
      description: "Supervised serving of small local decision models with Nx",
      package: package(),
      docs: docs(),
      name: "SystemOne",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:nx, "~> 0.10"},
      {:ortex, "~> 0.1.10"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:tokenizers, "~> 0.5"},
      {:benchee, "~> 1.3", only: :bench},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib guides notebooks bench/README.md usage-rules.md mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "SystemOne",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/gpu.md",
        "guides/deployment.md",
        "CHANGELOG.md",
        "bench/README.md": [title: "Benchmarks"],
        LICENSE: [title: "License"],
        "usage-rules.md": [title: "LLM usage rules"],
        "notebooks/getting_started.livemd": [title: "Interactive Laya notebook"]
      ],
      groups_for_modules: [
        Queries: [
          SystemOne.Query,
          SystemOne.Question,
          SystemOne.Result,
          SystemOne.Answer,
          SystemOne.Status
        ],
        Models: [
          SystemOne.Model,
          SystemOne.Models.Laya
        ],
        Bundles: [
          SystemOne.Installer,
          SystemOne.Bundle.Manifest
        ]
      ]
    ]
  end
end
