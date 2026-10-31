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

    assert {:error, :invalid_manifest} = Manifest.decode("[]", InstallableModel)

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

  describe "over HTTP" do
    setup %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "www") |> String.to_charlist()
      File.mkdir_p!(root)

      {:ok, httpd} =
        :inets.start(:httpd,
          port: 0,
          server_name: ~c"system_one_test",
          server_root: root,
          document_root: root,
          bind_address: {127, 0, 0, 1},
          mime_types: [{~c"txt", ~c"text/plain"}, {~c"bin", ~c"application/octet-stream"}]
        )

      on_exit(fn -> :inets.stop(:httpd, httpd) end)
      [{:port, port}] = :httpd.info(httpd, [:port])
      base_url = "http://127.0.0.1:#{port}"

      for {path, contents} <- InstallableModel.contents() do
        target = Path.join(to_string(root), path)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, contents)
      end

      {:ok, base_url: base_url, www: to_string(root)}
    end

    test "downloads a bundle and its manifest with the built-in client", ctx do
      {:ok, manifest} = InstallableModel.manifest(:default)
      manifest = %{manifest | base_url: ctx.base_url <> "/", revision: nil}
      contents = Manifest.encode!(manifest)
      File.write!(Path.join(ctx.www, "manifest.txt"), contents)
      destination = Path.join(ctx.tmp_dir, "http-model")

      assert {:ok, ^destination} =
               Installer.install(InstallableModel,
                 destination: destination,
                 manifest: ctx.base_url <> "/manifest.txt",
                 manifest_sha256: sha256(contents),
                 token: "secret-token"
               )

      for {path, expected} <- InstallableModel.contents() do
        assert File.read!(Path.join(destination, path)) == expected
      end
    end

    test "uses the revision as a path segment and reads file:// manifests", ctx do
      File.mkdir_p!(Path.join(ctx.www, "rev1"))

      for {path, contents} <- InstallableModel.contents() do
        target = Path.join([ctx.www, "rev1", path])
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, contents)
      end

      {:ok, manifest} = InstallableModel.manifest(:default)
      manifest = %{manifest | base_url: ctx.base_url, revision: "rev1"}
      contents = Manifest.encode!(manifest)
      manifest_path = Path.join(ctx.tmp_dir, "rev-manifest.json")
      File.write!(manifest_path, contents)
      destination = Path.join(ctx.tmp_dir, "rev-model")

      assert {:ok, ^destination} =
               Installer.install(InstallableModel,
                 destination: destination,
                 manifest: "file://" <> manifest_path,
                 manifest_sha256: sha256(contents)
               )
    end

    test "reports HTTP status errors for files and manifests", ctx do
      {:ok, manifest} = InstallableModel.manifest(:default)
      manifest = %{manifest | base_url: ctx.base_url <> "/missing", revision: nil}
      contents = Manifest.encode!(manifest)
      File.write!(Path.join(ctx.www, "bad-base.txt"), contents)

      assert {:error, {:download_failed, _path, {:http_status, 404}}} =
               Installer.install(InstallableModel,
                 destination: Path.join(ctx.tmp_dir, "never"),
                 manifest: ctx.base_url <> "/bad-base.txt",
                 manifest_sha256: sha256(contents)
               )

      assert {:error, {:manifest_http_status, 404}} =
               Installer.install(InstallableModel,
                 destination: Path.join(ctx.tmp_dir, "never"),
                 manifest: ctx.base_url <> "/no-such-manifest.txt",
                 manifest_sha256: String.duplicate("a", 64)
               )
    end

    @tag :capture_log
    test "reports transport errors for files and manifests", ctx do
      {:ok, closed} = :gen_tcp.listen(0, [])
      {:ok, closed_port} = :inet.port(closed)
      :ok = :gen_tcp.close(closed)
      dead_url = "http://127.0.0.1:#{closed_port}"

      assert {:error, {:manifest_download_failed, _reason}} =
               Installer.install(InstallableModel,
                 destination: Path.join(ctx.tmp_dir, "never"),
                 manifest: dead_url <> "/manifest.json",
                 manifest_sha256: String.duplicate("a", 64)
               )

      {:ok, manifest} = InstallableModel.manifest(:default)
      manifest = %{manifest | base_url: dead_url, revision: nil}
      contents = Manifest.encode!(manifest)
      manifest_path = Path.join(ctx.tmp_dir, "dead-manifest.json")
      File.write!(manifest_path, contents)

      assert {:error, {:download_failed, _path, _reason}} =
               Installer.install(InstallableModel,
                 destination: Path.join(ctx.tmp_dir, "never"),
                 manifest: manifest_path,
                 manifest_sha256: sha256(contents),
                 receive_timeout: 1_000
               )
    end
  end

  test "reports a destination that cannot be written", %{tmp_dir: tmp_dir} do
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "not a directory")

    download = fn _url, target, _opts -> File.write(target, "x") end

    # The stage directory is a sibling of the destination, so put the
    # destination under a regular file to make every mkdir fail.
    assert {:error, {:stage_failed, :enotdir}} =
             Installer.install(InstallableModel,
               destination: Path.join(blocker, "model"),
               download: download
             )
  end

  test "lock rejects a parent that is a file and merges existing entries", %{tmp_dir: tmp_dir} do
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "not a directory")
    assert {:error, :enotdir} = Lock.put(Path.join(blocker, "x.lock"), "test", %{})

    readonly = Path.join(tmp_dir, "readonly")
    File.mkdir_p!(readonly)
    File.chmod!(readonly, 0o500)
    on_exit(fn -> File.chmod(readonly, 0o700) end)

    assert {:error, message} = Lock.put(Path.join(readonly, "x.lock"), "test", %{})
    assert is_binary(message)

    path = Path.join(tmp_dir, "merge.lock")
    assert :ok = Lock.put(path, "one", %{"a" => 1})
    assert :ok = Lock.put(path, "two", %{"b" => 2})
    assert {:ok, %{"a" => 1}} = Lock.get(path, "one")
    assert {:ok, %{"b" => 2}} = Lock.get(path, "two")
  end

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
