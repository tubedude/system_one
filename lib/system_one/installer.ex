defmodule SystemOne.Installer do
  @moduledoc """
  Downloads and verifies model bundles.

  A bundle is a directory of model files described by a
  `SystemOne.Bundle.Manifest`. The manifest lists every file with its SHA-256.

  The manifest is trusted only when it comes from the model module
  (`c:SystemOne.Model.manifest/1`), or when its own SHA-256 matches the
  `:manifest_sha256` option. The copy of the manifest saved in an installed
  bundle is never used as a source of checksums.

  Files download into a temporary directory next to the destination. The
  destination changes only after every file is verified. If a forced
  replacement fails, the previous bundle is restored.

  Most applications use `mix system_one.install` instead of this module.
  """

  alias SystemOne.Bundle.Manifest

  @manifest_schema [
    version: [
      type: {:or, [:atom, :string]},
      default: :default,
      doc: "The bundle version. `:default` selects the version the model is built for."
    ],
    manifest: [
      type: :string,
      doc: "An HTTPS URL, `file://` URL, or path of an external manifest."
    ],
    manifest_sha256: [
      type: :string,
      doc: "The SHA-256 of the external manifest. Required with `:manifest`."
    ],
    token: [
      type: :string,
      doc: "A bearer token for downloads. Defaults to the `HF_TOKEN` environment variable."
    ],
    receive_timeout: [
      type: :pos_integer,
      default: 600_000,
      doc: "The HTTP receive timeout, in milliseconds."
    ]
  ]

  @install_schema @manifest_schema ++
                    [
                      destination: [
                        type: :string,
                        required: true,
                        doc: "The directory to install into."
                      ],
                      force: [
                        type: :boolean,
                        default: false,
                        doc: "Replace an existing bundle, even if it is valid."
                      ],
                      progress: [
                        type: {:fun, 1},
                        doc: "A function that receives `t:progress/0` events."
                      ],
                      download: [
                        type: {:fun, 3},
                        doc: """
                        A function `(url, path, opts) -> :ok | {:error, reason}` that
                        replaces the HTTP download. Useful in tests.
                        """
                      ]
                    ]

  @typedoc "An event sent to the `:progress` function."
  @type progress :: {:download, String.t()} | {:verified, String.t()} | {:complete, String.t()}

  @doc """
  Installs the bundle of `model` and returns its expanded path.

  If the destination already holds a valid bundle for the same manifest, it
  is kept and nothing is downloaded. This includes files that were copied
  there by hand: when every checksum matches, the manifest is written and the
  files are kept.

  ## Options

  #{NimbleOptions.docs(@install_schema)}
  """
  @spec install(module(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def install(model, opts \\ []) when is_atom(model) do
    opts =
      opts
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> NimbleOptions.validate!(@install_schema)

    with {:module, ^model} <- Code.ensure_loaded(model),
         {:ok, manifest} <- trusted_manifest(model, opts),
         {:ok, destination} <- destination(opts) do
      install_manifest(manifest, destination, opts)
    end
  end

  @doc """
  Checks that `directory` holds the bundle of `model`.

  Every file is hashed and compared with the trusted manifest.

  ## Options

  #{NimbleOptions.docs(@manifest_schema)}
  """
  @spec verify(module(), String.t(), keyword()) :: :ok | {:error, term()}
  def verify(model, directory, opts \\ []) do
    opts =
      opts
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> NimbleOptions.validate!(@manifest_schema)

    with {:module, ^model} <- Code.ensure_loaded(model),
         {:ok, %Manifest{} = manifest} <- trusted_manifest(model, opts) do
      verify_installed_bundle(manifest, directory)
    end
  end

  defp trusted_manifest(model, opts) do
    with {:ok, %Manifest{} = manifest} <- resolve_manifest(model, opts),
         :ok <- Manifest.validate(manifest),
         :ok <- requested_version(Keyword.fetch!(opts, :version), manifest.version),
         :ok <- ensure_compatible(model, manifest) do
      {:ok, manifest}
    end
  end

  defp install_manifest(manifest, destination, opts) do
    if File.exists?(destination) and not Keyword.fetch!(opts, :force) do
      reuse_installed_bundle(manifest, destination)
    else
      install_new_bundle(manifest, destination, opts)
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp reuse_installed_bundle(manifest, destination) do
    case verify_installed_bundle(manifest, destination) do
      :ok -> {:ok, destination}
      {:error, :enoent} -> adopt_bundle(manifest, destination)
      {:error, reason} -> {:error, {:destination_exists, reason}}
    end
  end

  # Files placed without the installer have no manifest copy. They are kept
  # when every checksum matches the trusted manifest.
  defp adopt_bundle(manifest, destination) do
    with :ok <- verify_manifest(manifest, destination),
         :ok <- write_manifest(destination, manifest) do
      {:ok, destination}
    else
      {:error, reason} -> {:error, {:destination_exists, reason}}
    end
  end

  defp verify_installed_bundle(manifest, directory) do
    path = Manifest.path(directory)

    with {:ok, installed} <- File.read(path),
         {:ok, installed_map} <- Jason.decode(installed),
         {:ok, trusted_map} <- manifest |> Manifest.encode!() |> Jason.decode(),
         true <- installed_map == trusted_map || {:error, :manifest_mismatch} do
      verify_manifest(manifest, directory)
    end
  end

  defp install_new_bundle(manifest, destination, opts) do
    with_stage(destination, fn stage ->
      with :ok <- download_files(manifest.files, manifest, stage, opts),
           :ok <- write_manifest(stage, manifest),
           :ok <- publish(stage, destination),
           :ok <- progress(opts, {:complete, destination}) do
        {:ok, destination}
      end
    end)
  end

  defp with_stage(destination, install) do
    stage = unique_sibling(destination, "install")

    case File.mkdir_p(stage) do
      :ok ->
        try do
          install.(stage)
        after
          File.rm_rf(stage)
        end

      {:error, reason} ->
        {:error, {:stage_failed, reason}}
    end
  end

  defp download_files([], _manifest, _stage, _opts), do: :ok

  defp download_files([entry | remaining], manifest, stage, opts) do
    with :ok <- download_file(manifest, entry, stage, opts) do
      download_files(remaining, manifest, stage, opts)
    end
  end

  defp download_file(manifest, entry, stage, opts) do
    target = safe_join!(stage, entry.path)

    with :ok <- mkdir_parent(target),
         :ok <- progress(opts, {:download, entry.path}),
         :ok <- fetch_file(manifest, entry.path, target, opts),
         :ok <- verify_file(target, entry.sha256),
         :ok <- progress(opts, {:verified, entry.path}) do
      :ok
    end
  end

  defp mkdir_parent(target) do
    case File.mkdir_p(Path.dirname(target)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp fetch_file(manifest, path, target, opts) do
    downloader = Keyword.get(opts, :download, &download/3)

    case downloader.(file_url(manifest, path), target, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:download_failed, path, reason}}
    end
  end

  defp write_manifest(stage, manifest) do
    path = Manifest.path(stage)

    case File.write(path, Manifest.encode!(manifest)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:manifest_write_failed, reason}}
    end
  end

  defp publish(stage, destination) do
    if File.exists?(destination) do
      replace_destination(stage, destination)
    else
      rename(stage, destination, :publish_failed)
    end
  end

  defp replace_destination(stage, destination) do
    backup = unique_sibling(destination, "backup")

    with :ok <- rename(destination, backup, :backup_failed),
         :ok <- promote_or_restore(stage, destination, backup) do
      File.rm_rf(backup)
      :ok
    end
  end

  defp rename(source, destination, error_tag) do
    case File.rename(source, destination) do
      :ok -> :ok
      {:error, reason} -> {:error, {error_tag, reason}}
    end
  end

  defp promote_or_restore(stage, destination, backup) do
    case File.rename(stage, destination) do
      :ok ->
        :ok

      {:error, publish_reason} ->
        case File.rename(backup, destination) do
          :ok -> {:error, {:publish_failed, publish_reason}}
          {:error, restore_reason} -> {:error, {:restore_failed, publish_reason, restore_reason}}
        end
    end
  end

  defp unique_sibling(destination, label) do
    destination <> ".#{label}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp progress(opts, event) do
    if callback = opts[:progress], do: callback.(event)
    :ok
  end

  defp verify_manifest(manifest, directory) do
    verify_files(manifest.files, directory)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp verify_files([], _directory), do: :ok

  defp verify_files([entry | remaining], directory) do
    with :ok <- verify_file(safe_join!(directory, entry.path), entry.sha256) do
      verify_files(remaining, directory)
    end
  end

  defp verify_file(path, expected_sha) do
    if File.regular?(path) do
      actual =
        path
        |> File.stream!(65_536, [])
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      if actual == String.downcase(expected_sha) do
        :ok
      else
        {:error, {:checksum_mismatch, Path.basename(path)}}
      end
    else
      {:error, {:missing_file, Path.basename(path)}}
    end
  end

  defp download(url, target, opts) do
    case Req.get(url,
           headers: auth_headers(opts),
           into: File.stream!(target),
           receive_timeout: Keyword.fetch!(opts, :receive_timeout)
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp destination(opts) do
    case Keyword.get(opts, :destination) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, :destination_required}
    end
  end

  defp requested_version(version, _installed) when version in [:default, "default"], do: :ok
  defp requested_version(version, version), do: :ok

  defp requested_version(version, installed),
    do: {:error, {:version_mismatch, version, installed}}

  defp resolve_manifest(model, opts) do
    resolve_manifest(model, Keyword.get(opts, :manifest), opts)
  end

  defp resolve_manifest(model, nil, opts) do
    if function_exported?(model, :manifest, 1) do
      model.manifest(Keyword.fetch!(opts, :version))
    else
      {:error, {:missing_manifest, model}}
    end
  end

  defp resolve_manifest(model, source, opts),
    do: fetch_external_manifest(model, source, Keyword.get(opts, :manifest_sha256), opts)

  defp fetch_external_manifest(_model, _source, nil, _opts),
    do: {:error, :manifest_sha256_required}

  defp fetch_external_manifest(model, source, expected_sha, opts) do
    with :ok <- validate_sha256(expected_sha),
         {:ok, contents} <- fetch_manifest(source, opts),
         :ok <- verify_contents(contents, expected_sha, :manifest),
         {:ok, manifest} <- Manifest.decode(contents, model) do
      {:ok, manifest}
    end
  end

  defp fetch_manifest(source, opts) do
    uri = URI.parse(source)

    if uri.scheme in ["http", "https"] do
      case Req.get(source,
             headers: auth_headers(opts),
             receive_timeout: Keyword.fetch!(opts, :receive_timeout)
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
          {:ok, body}

        {:ok, %{status: status}} ->
          {:error, {:manifest_http_status, status}}

        {:error, reason} ->
          {:error, {:manifest_download_failed, reason}}
      end
    else
      path = if uri.scheme == "file", do: uri.path, else: source
      File.read(path)
    end
  end

  defp ensure_compatible(model, %Manifest{schema: schema}) do
    expected = if function_exported?(model, :bundle_schema, 0), do: model.bundle_schema(), else: 1
    if schema == expected, do: :ok, else: {:error, {:unsupported_bundle_schema, schema}}
  end

  defp validate_sha256(sha) when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-fA-F]{64}\z/, sha),
      do: :ok,
      else: {:error, :invalid_manifest_sha256}
  end

  defp validate_sha256(_sha), do: {:error, :invalid_manifest_sha256}

  defp verify_contents(contents, expected_sha, label) do
    actual = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

    if actual == String.downcase(expected_sha),
      do: :ok,
      else: {:error, {:checksum_mismatch, label}}
  end

  defp safe_join!(root, relative) do
    expanded_root = Path.expand(root)
    joined = Path.expand(relative, expanded_root)

    if joined == expanded_root or String.starts_with?(joined, expanded_root <> "/") do
      joined
    else
      raise ArgumentError, "bundle path escapes its destination: #{inspect(relative)}"
    end
  end

  defp file_url(%Manifest{base_url: base, revision: nil}, path),
    do: Enum.join([String.trim_trailing(base, "/"), encode_path(path)], "/")

  defp file_url(%Manifest{base_url: base, revision: revision}, path),
    do: Enum.join([String.trim_trailing(base, "/"), revision, encode_path(path)], "/")

  defp encode_path(path) do
    path |> Path.split() |> Enum.map_join("/", &URI.encode/1)
  end

  defp auth_headers(opts) do
    case Keyword.get(opts, :token) || System.get_env("HF_TOKEN") do
      token when is_binary(token) and token != "" -> [{"authorization", "Bearer #{token}"}]
      _ -> []
    end
  end
end
