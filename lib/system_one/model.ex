defmodule SystemOne.Model do
  @moduledoc """
  A behaviour for models served by `SystemOne`.

  A model builds an `Nx.Serving` that takes a `SystemOne.Query` and returns a
  `SystemOne.Result`. SystemOne starts, supervises, and replaces the serving
  process.

  `SystemOne.Models.Laya` is a complete implementation.

  To reject a query, raise `ArgumentError` in client preprocessing.
  `SystemOne.query/2` returns it as `{:error, {:invalid_query, message}}`.

  To support `SystemOne.Installer` and `mix system_one.install`, also
  implement `c:manifest/1`.
  """

  alias SystemOne.Bundle.Manifest

  @doc """
  Builds the serving.

  Receives the instance options without `:name` and `:model`. Returns the
  serving and the options for `Nx.Serving.start_link/1`, such as
  `:batch_size`, `:batch_timeout`, and `:batch_keys`.

  This callback runs in a separate process, so it may block while it reads
  large files.
  """
  @callback load(opts :: keyword()) :: {:ok, Nx.Serving.t(), keyword()} | {:error, term()}

  @doc """
  Returns the manifest of the bundle `version`.

  `:default` selects the version this module is built for.
  """
  @callback manifest(version :: String.t() | :default) :: {:ok, Manifest.t()} | {:error, term()}

  @doc """
  Returns the name stored in manifests, such as `"laya"`.

  Defaults to the last segment of the module name, in snake case.
  """
  @callback model_name() :: String.t()

  @doc """
  Returns the manifest schema version this module reads. Defaults to `1`.
  """
  @callback bundle_schema() :: pos_integer()

  @doc """
  Previews token usage and sequence layout for `query`.

  Optional. If implemented, allows `SystemOne.preview/2` to preview token usage
  for queries without running model inference.
  """
  @callback preview(query :: SystemOne.Query.t(), opts :: keyword() | map()) ::
              {:ok, SystemOne.Preview.t()} | {:error, term()}

  @optional_callbacks manifest: 1, model_name: 0, bundle_schema: 0, preview: 2
end
