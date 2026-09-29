defmodule SystemOne.InstallerTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias SystemOne.Bundle.{Lock, Manifest}
  alias SystemOne.Installer

  defmodule InstallableModel do
    @behaviour SystemOne.Model
    @contents %{"weights.bin" => "model-weights", "tokenizer/config.json" => ~s({"ok":true})}

    def load(_opts), do: {:error, :not_used}
    def model_name, do: "test"
    def bundle_schema, do: 1

    def contents, do: @contents

    def manifest(:default) do
      files =
        Enum.map(@contents, fn {path, contents} ->
          %{path: path, sha256: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)}
        end)

      {:ok,
       %Manifest{
         model: :test,
         version: "1",
         base_url: "https://models.example",
         files: files
       }}
    end
  end

  defmodule NoNameModel do
  end

  test "installs, verifies, and reuses a complete bundle", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "model")
    parent = self()

    download = fn url, target, _opts ->
      relative = String.replace_prefix(url, "https://models.example/", "")
      send(parent, {:downloaded, relative})
      File.write(target, Map.fetch!(InstallableModel.contents(), relative))
    end

    assert {:ok, ^destination} =
             Installer.install(InstallableModel, destination: destination, download: download)

    assert :ok = Installer.verify(InstallableModel, destination)
    assert File.regular?(Manifest.path(destination))
    assert_received {:downloaded, "weights.bin"}
    assert_received {:downloaded, "tokenizer/config.json"}

    assert {:ok, ^destination} =
             Installer.install(InstallableModel, destination: destination, download: download)

    refute_received {:downloaded, _}
  end

  test "adopts matching files that have no manifest", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "model")

    for {path, contents} <- InstallableModel.contents() do
      File.mkdir_p!(Path.dirname(Path.join(destination, path)))
      File.write!(Path.join(destination, path), contents)
    end

    no_download = fn _url, _target, _opts -> flunk("unexpected download") end

    assert {:ok, ^destination} =
             Installer.install(InstallableModel, destination: destination, download: no_download)

    assert :ok = Installer.verify(InstallableModel, destination)

    File.rm!(Manifest.path(destination))
    File.write!(Path.join(destination, "weights.bin"), "tampered")

    assert {:error, {:destination_exists, {:checksum_mismatch, "weights.bin"}}} =
             Installer.install(InstallableModel, destination: destination, download: no_download)
  end

  test "does not publish a partially downloaded bundle", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "model")

    download = fn _url, _target, _opts -> {:error, :offline} end

    assert {:error, {:download_failed, _, :offline}} =
             Installer.install(InstallableModel, destination: destination, download: download)

    refute File.exists?(destination)
    assert Path.wildcard(destination <> ".install-*") == []
  end

  test "preserves the installed bundle when a forced replacement fails", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "model")
    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "keep.txt"), "current bundle")

    assert {:error, {:download_failed, _, :offline}} =
             Installer.install(InstallableModel,
               destination: destination,
               force: true,
               download: fn _url, _target, _opts -> {:error, :offline} end
             )

    assert File.read!(Path.join(destination, "keep.txt")) == "current bundle"
    assert Path.wildcard(destination <> ".install-*") == []
    assert Path.wildcard(destination <> ".backup-*") == []
  end

  test "atomically replaces an installed bundle and reports progress", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "model")
    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "old.bin"), "obsolete")
    parent = self()

    download = fn url, target, _opts ->
      relative = String.replace_prefix(url, "https://models.example/", "")
      File.write(target, Map.fetch!(InstallableModel.contents(), relative))
    end

    assert {:ok, ^destination} =
             Installer.install(InstallableModel,
               destination: destination,
               force: true,
               download: download,
               progress: &send(parent, &1)
             )

    refute File.exists?(Path.join(destination, "old.bin"))
    assert :ok = Installer.verify(InstallableModel, destination)
    assert_received {:download, "weights.bin"}
    assert_received {:verified, "weights.bin"}
    assert_received {:complete, ^destination}
    assert Path.wildcard(destination <> ".backup-*") == []
  end

  test "reports models without a manifest" do
    assert {:error, {:missing_manifest, SystemOne.TestModels.Alpha}} =
             Installer.install(SystemOne.TestModels.Alpha, destination: "tmp/model")
  end

  test "installs a locally pinned external manifest", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "external-model")
    manifest_path = Path.join(tmp_dir, "manifest.json")
    {:ok, manifest} = InstallableModel.manifest(:default)
    contents = Manifest.encode!(%{manifest | version: "2"})
    File.write!(manifest_path, contents)
    checksum = sha256(contents)

    download = fn url, target, _opts ->
      relative = String.replace_prefix(url, "https://models.example/", "")
      File.write(target, Map.fetch!(InstallableModel.contents(), relative))
    end

    assert {:ok, ^destination} =
             Installer.install(InstallableModel,
               destination: destination,
               manifest: manifest_path,
               manifest_sha256: checksum,
               download: download
             )

    assert :ok =
             Installer.verify(InstallableModel, destination,
               version: "2",
               manifest: manifest_path,
               manifest_sha256: checksum
             )

    assert {:error, {:version_mismatch, "1", "2"}} =
             Installer.verify(InstallableModel, destination,
               version: "1",
               manifest: manifest_path,
               manifest_sha256: checksum
             )
  end

  test "does not trust an installed manifest to verify itself", %{tmp_dir: tmp_dir} do
    destination = Path.join(tmp_dir, "external-model")
    manifest_path = Path.join(tmp_dir, "manifest.json")
    {:ok, manifest} = InstallableModel.manifest(:default)
    contents = Manifest.encode!(manifest)
    File.write!(manifest_path, contents)
    checksum = sha256(contents)

    download = fn url, target, _opts ->
      relative = String.replace_prefix(url, "https://models.example/", "")
      File.write(target, Map.fetch!(InstallableModel.contents(), relative))
    end

    assert {:ok, ^destination} =
             Installer.install(InstallableModel,
               destination: destination,
               manifest: manifest_path,
               manifest_sha256: checksum,
               download: download
             )

    tampered = "different weights"
    File.write!(Path.join(destination, "weights.bin"), tampered)

    installed_manifest =
      destination
      |> Manifest.path()
      |> File.read!()
      |> Jason.decode!()

    files =
      Enum.map(installed_manifest["files"], fn
        %{"path" => "weights.bin"} = entry -> Map.put(entry, "sha256", sha256(tampered))
        entry -> entry
      end)

    File.write!(
      Manifest.path(destination),
      Jason.encode!(%{installed_manifest | "files" => files})
    )

    assert {:error, :manifest_mismatch} =
             Installer.verify(InstallableModel, destination,
               manifest: manifest_path,
               manifest_sha256: checksum
             )
  end

  test "rejects an external manifest whose pin does not match", %{tmp_dir: tmp_dir} do
    manifest_path = Path.join(tmp_dir, "manifest.json")
    {:ok, manifest} = InstallableModel.manifest(:default)
    File.write!(manifest_path, Manifest.encode!(manifest))

    assert {:error, {:checksum_mismatch, :manifest}} =
             Installer.install(InstallableModel,
               destination: Path.join(tmp_dir, "model"),
               manifest: manifest_path,
               manifest_sha256: String.duplicate("0", 64)
             )
  end

  test "rejects unsafe paths and unsupported schemas", %{tmp_dir: tmp_dir} do
    {:ok, manifest} = InstallableModel.manifest(:default)

    unsafe =
      Manifest.encode!(%{
        manifest
        | files: [%{path: "../weights.bin", sha256: String.duplicate("0", 64)}]
      })

    unsafe_path = Path.join(tmp_dir, "unsafe.json")
    File.write!(unsafe_path, unsafe)

    assert {:error, :invalid_manifest} =
             Installer.install(InstallableModel,
               destination: Path.join(tmp_dir, "unsafe"),
               manifest: unsafe_path,
               manifest_sha256: sha256(unsafe)
             )

    incompatible = Manifest.encode!(%{manifest | schema: 2})
    incompatible_path = Path.join(tmp_dir, "incompatible.json")
    File.write!(incompatible_path, incompatible)

    assert {:error, {:unsupported_bundle_schema, 2}} =
             Installer.install(InstallableModel,
               destination: Path.join(tmp_dir, "incompatible"),
               manifest: incompatible_path,
               manifest_sha256: sha256(incompatible)
             )
  end

  test "atomically updates and reads a consumer lock", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "system_one_models.lock")
    entry = %{"manifest" => "manifest.json", "manifest_sha256" => String.duplicate("a", 64)}

    assert :ok = Lock.put(path, "test", entry)
    assert {:ok, ^entry} = Lock.get(path, "test")
    assert :error = Lock.get(path, "missing")
    assert Path.wildcard(path <> ".tmp-*") == []
  end

  test "lock handles missing, malformed, and inaccessible paths", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "missing.lock")
    assert :error = Lock.get(missing, "test")

    malformed = Path.join(tmp_dir, "malformed.lock")
    File.write!(malformed, "[]")
    assert {:error, :invalid_lockfile} = Lock.get(malformed, "test")
    assert {:error, :invalid_lockfile} = Lock.put(malformed, "test", %{})

    assert {:error, :eisdir} = Lock.get(tmp_dir, "test")
    assert {:error, :eisdir} = Lock.put(tmp_dir, "test", %{})
  end

  test "manifest decoding and validation reject malformed values" do
    checksum = String.duplicate("a", 64)

    assert {:ok, manifest} =
             Manifest.decode(
               Jason.encode!(%{
                 model: "test",
                 version: "1",
                 base_url: "https://example.test",
                 files: [%{path: "weights.bin", sha256: checksum}]
               }),
               InstallableModel
             )

    assert :ok = Manifest.validate(manifest)

    assert {:ok, %{model: "no_name_model"}} =
             Manifest.decode(
               Jason.encode!(%{
                 model: "no_name_model",
                 version: "1",
                 base_url: "https://example.test",
                 files: [%{path: "weights.bin", sha256: checksum}]
               }),
               NoNameModel
             )

    assert {:error, {:wrong_model, "other"}} =
             Manifest.decode(Jason.encode!(%{model: "other"}), InstallableModel)

    assert {:error, _} = Manifest.decode("not json", InstallableModel)
    assert {:error, :invalid_manifest} = Manifest.decode("[]", InstallableModel)
    assert {:error, :invalid_manifest} = Manifest.validate(:not_a_manifest)
    assert {:error, :invalid_manifest} = Manifest.validate(%{manifest | files: [%{bad: true}]})

    assert {:error, :invalid_manifest} =
             Manifest.validate(%{manifest | files: [%{path: "weights", sha256: 123}]})

    assert {:error, :invalid_manifest} =
             Manifest.validate(%{manifest | files: [%{path: "../weights", sha256: checksum}]})
  end

  test "requires a manifest checksum and destination", %{tmp_dir: tmp_dir} do
    manifest_path = Path.join(tmp_dir, "manifest.json")
    {:ok, manifest} = InstallableModel.manifest(:default)
    File.write!(manifest_path, Manifest.encode!(manifest))

    assert {:error, :manifest_sha256_required} =
             Installer.install(InstallableModel,
               destination: Path.join(tmp_dir, "model"),
               manifest: manifest_path
             )

    assert_raise NimbleOptions.ValidationError, fn -> Installer.install(InstallableModel) end

    assert {:error, :invalid_manifest_sha256} =
             Installer.install(InstallableModel,
               destination: Path.join(tmp_dir, "model"),
               manifest: manifest_path,
               manifest_sha256: "invalid"
             )
  end

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
