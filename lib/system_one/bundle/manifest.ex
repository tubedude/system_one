defmodule SystemOne.Bundle.Manifest do
  @moduledoc """
  Describes a model bundle: where its files are and what their checksums are.

  Each file downloads from `base_url/revision/path`, or `base_url/path` when
  `revision` is `nil`. File paths must be relative and stay inside the bundle.

  Manifests are stored as JSON. An installed bundle keeps a copy in
  `system_one_manifest.json`.
  """

  @filename "system_one_manifest.json"

  @enforce_keys [:model, :version, :base_url, :files]
  defstruct [:model, :version, :base_url, :revision, schema: 1, files: []]

  @type file_entry :: %{required(:path) => String.t(), required(:sha256) => String.t()}
  @type t :: %__MODULE__{
          schema: pos_integer(),
          model: atom() | String.t(),
          version: String.t(),
          base_url: String.t(),
          revision: String.t() | nil,
          files: [file_entry()]
        }

  @doc false
  @spec path(String.t()) :: String.t()
  def path(directory), do: Path.join(directory, @filename)

  @doc """
  Decodes a JSON manifest for `model`.

  Returns an error if the manifest names another model or is invalid.
  """
  @spec decode(binary(), module()) :: {:ok, t()} | {:error, term()}
  def decode(contents, model) when is_binary(contents) and is_atom(model) do
    expected = model_name(model)

    with {:ok, raw} when is_map(raw) <- Jason.decode(contents),
         true <- raw["model"] == expected || {:error, {:wrong_model, raw["model"]}},
         {:ok, manifest} <- from_map(raw, expected),
         :ok <- validate(manifest) do
      {:ok, manifest}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_manifest}
    end
  end

  @doc """
  Encodes a manifest as JSON.
  """
  @spec encode!(t()) :: binary()
  def encode!(%__MODULE__{} = manifest) do
    Jason.encode!(%{
      schema: manifest.schema,
      model: manifest.model,
      version: manifest.version,
      base_url: manifest.base_url,
      revision: manifest.revision,
      files: manifest.files
    })
  end

  @doc """
  Checks that all fields are present and that every file has a safe path and
  a SHA-256.
  """
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = manifest) do
    valid? =
      is_integer(manifest.schema) and manifest.schema > 0 and
        (is_atom(manifest.model) or is_binary(manifest.model)) and
        is_binary(manifest.version) and manifest.version != "" and
        is_binary(manifest.base_url) and manifest.base_url != "" and
        (is_nil(manifest.revision) or is_binary(manifest.revision)) and
        manifest.files != [] and Enum.all?(manifest.files, &valid_file?/1)

    if valid?, do: :ok, else: {:error, :invalid_manifest}
  end

  def validate(_manifest), do: {:error, :invalid_manifest}

  defp from_map(raw, expected) when is_map(raw) do
    files =
      Enum.map(raw["files"] || [], fn entry ->
        %{path: entry["path"], sha256: entry["sha256"]}
      end)

    {:ok,
     %__MODULE__{
       schema: raw["schema"] || 1,
       model: expected,
       version: raw["version"],
       base_url: raw["base_url"],
       revision: raw["revision"],
       files: files
     }}
  rescue
    _ -> {:error, :invalid_manifest}
  end

  defp valid_file?(%{path: path, sha256: sha}) do
    is_binary(path) and path != "" and safe_relative_path?(path) and valid_sha256?(sha)
  end

  defp valid_file?(_entry), do: false

  defp safe_relative_path?(path) do
    Path.type(path) != :absolute and
      path |> Path.split() |> Enum.all?(&(&1 not in ["..", "."]))
  end

  defp valid_sha256?(sha) when is_binary(sha), do: Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, sha)
  defp valid_sha256?(_sha), do: false

  defp model_name(model) do
    if function_exported?(model, :model_name, 0) do
      model.model_name()
    else
      model |> Module.split() |> List.last() |> Macro.underscore()
    end
  end
end
