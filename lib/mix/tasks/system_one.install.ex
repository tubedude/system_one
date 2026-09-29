defmodule Mix.Tasks.SystemOne.Install do
  use Mix.Task

  alias SystemOne.Bundle.Lock

  @shortdoc "Downloads and verifies a model bundle"

  @moduledoc """
  Downloads and verifies a model bundle.

      $ mix system_one.install laya

  Without `--manifest`, the task uses the manifest built into the model
  module. To install another release, pass a manifest and its SHA-256:

      $ mix system_one.install laya \\
          --manifest https://example.com/laya-2026-09.json \\
          --manifest-sha256 3f5a...

  The task then records the manifest in `system_one_models.lock`. Later runs
  use the locked manifest, so commit the lock file.

  ## Options

    * `--dir` - the install directory. Defaults to `priv/models/MODEL`.
    * `--version` - the bundle version. Defaults to the model's version.
    * `--force` - replace an existing bundle.
    * `--token` - a bearer token for downloads. Defaults to `HF_TOKEN`.
    * `--manifest` - a URL or path of an external manifest.
    * `--manifest-sha256` - the SHA-256 of the external manifest.
    * `--lock` - the lock file. Defaults to `system_one_models.lock`.

  """

  @models %{"laya" => SystemOne.Models.Laya}

  @impl true
  def run(args) do
    {opts, positional} =
      OptionParser.parse!(args,
        strict: [
          dir: :string,
          version: :string,
          force: :boolean,
          token: :string,
          manifest: :string,
          manifest_sha256: :string,
          lock: :string
        ]
      )

    model_name = List.first(positional) || Mix.raise("model is required (for example: laya)")
    model = Map.get(@models, model_name) || Mix.raise("unknown model: #{model_name}")
    destination = opts[:dir] || default_destination(model_name)
    lock_path = opts[:lock] || "system_one_models.lock"
    source = manifest_source(model_name, lock_path, opts)

    install_opts =
      [
        destination: destination,
        version: opts[:version] || :default,
        force: Keyword.get(opts, :force, false),
        token: opts[:token],
        manifest: source.manifest,
        manifest_sha256: source.manifest_sha256,
        progress: &report/1
      ]

    {:ok, _} = Application.ensure_all_started(:req)

    case SystemOne.Installer.install(model, install_opts) do
      {:ok, path} ->
        maybe_update_lock(lock_path, model_name, source, path)
        Mix.shell().info("SystemOne #{model_name} bundle ready at #{path}")

      {:error, reason} ->
        Mix.raise("installation failed: #{inspect(reason)}")
    end
  end

  defp default_destination(model_name),
    do: Path.expand(Path.join(["priv", "models", model_name]))

  defp manifest_source(model_name, lock_path, opts) do
    if opts[:manifest] do
      if is_nil(opts[:manifest_sha256]),
        do: Mix.raise("--manifest-sha256 is required with --manifest")

      %{
        manifest: opts[:manifest],
        manifest_sha256: String.downcase(opts[:manifest_sha256]),
        explicit?: true
      }
    else
      case Lock.get(lock_path, model_name) do
        {:ok, %{"manifest" => manifest, "manifest_sha256" => sha}} ->
          %{manifest: manifest, manifest_sha256: sha, explicit?: false}

        :error ->
          %{manifest: nil, manifest_sha256: nil, explicit?: false}

        {:error, reason} ->
          Mix.raise("cannot read #{lock_path}: #{inspect(reason)}")

        {:ok, _entry} ->
          Mix.raise("invalid #{model_name} entry in #{lock_path}")
      end
    end
  end

  defp maybe_update_lock(_lock_path, _model_name, %{explicit?: false}, _path), do: :ok

  defp maybe_update_lock(lock_path, model_name, source, installed_path) do
    metadata =
      installed_path
      |> SystemOne.Bundle.Manifest.path()
      |> File.read!()
      |> Jason.decode!()

    entry =
      Map.merge(
        %{
          "manifest" => source.manifest,
          "manifest_sha256" => source.manifest_sha256
        },
        Map.take(metadata, ["schema", "version", "revision"])
      )

    case Lock.put(lock_path, model_name, entry) do
      :ok -> Mix.shell().info("Updated #{Path.expand(lock_path)}")
      {:error, reason} -> Mix.raise("model installed but lock update failed: #{inspect(reason)}")
    end
  end

  defp report({:download, path}), do: Mix.shell().info("Downloading #{path}")
  defp report({:verified, path}), do: Mix.shell().info("Verified #{path}")
  defp report({:complete, _path}), do: :ok
end
