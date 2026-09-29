defmodule Mix.Tasks.SystemOne.InstallTest do
  # Mix.shell/1 is global, so these tests cannot run concurrently.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Mix.Tasks.SystemOne.Install
  alias SystemOne.Bundle.{Lock, Manifest}

  # The task only knows real models, so these tests never download. They place
  # files in the destination first; the installer adopts files whose checksums
  # match the manifest.
  @contents %{"laya.onnx" => "fake-weights", "tokenizer/tokenizer.json" => ~s({"ok":true})}

  setup %{tmp_dir: tmp_dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    %{
      dir: Path.join(tmp_dir, "laya"),
      lock: Path.join(tmp_dir, "system_one_models.lock"),
      manifest: Path.join(tmp_dir, "laya-manifest.json")
    }
  end

  test "requires a model" do
    assert_raise Mix.Error, ~r/model is required/, fn -> Install.run([]) end
  end

  test "rejects an unknown model" do
    assert_raise Mix.Error, "unknown model: nope", fn -> Install.run(["nope"]) end
  end

  test "rejects unknown options" do
    assert_raise OptionParser.ParseError, fn -> Install.run(["laya", "--bogus", "x"]) end
  end

  test "requires --manifest-sha256 with --manifest", ctx do
    assert_raise Mix.Error, "--manifest-sha256 is required with --manifest", fn ->
      Install.run(["laya", "--manifest", ctx.manifest, "--lock", ctx.lock])
    end
  end

  test "installs from an external manifest and records it in the lock", ctx do
    sha = write_manifest(ctx.manifest)
    place_files(ctx.dir)

    Install.run([
      "laya",
      "--dir",
      ctx.dir,
      "--lock",
      ctx.lock,
      "--manifest",
      ctx.manifest,
      "--manifest-sha256",
      String.upcase(sha)
    ])

    expanded_dir = Path.expand(ctx.dir)
    expanded_lock = Path.expand(ctx.lock)
    assert_received {:mix_shell, :info, ["SystemOne laya bundle ready at " <> ^expanded_dir]}
    assert_received {:mix_shell, :info, ["Updated " <> ^expanded_lock]}

    assert {:ok, entry} = Lock.get(ctx.lock, "laya")

    assert entry == %{
             "manifest" => ctx.manifest,
             "manifest_sha256" => sha,
             "schema" => 1,
             "version" => "test",
             "revision" => nil
           }
  end

  test "later runs use the locked manifest", ctx do
    sha = write_manifest(ctx.manifest)
    place_files(ctx.dir)
    install_args = ["laya", "--dir", ctx.dir, "--lock", ctx.lock]

    Install.run(install_args ++ ["--manifest", ctx.manifest, "--manifest-sha256", sha])
    lock_before = File.read!(ctx.lock)
    flush_shell()

    # The built-in Laya manifest does not match these files, so this run only
    # succeeds if it reads the manifest from the lock.
    Install.run(install_args)

    expanded_dir = Path.expand(ctx.dir)
    assert_received {:mix_shell, :info, ["SystemOne laya bundle ready at " <> ^expanded_dir]}
    refute_received {:mix_shell, :info, ["Updated " <> _]}
    assert File.read!(ctx.lock) == lock_before
  end

  test "fails when the locked manifest no longer matches its pin", ctx do
    sha = write_manifest(ctx.manifest)
    :ok = Lock.put(ctx.lock, "laya", %{"manifest" => ctx.manifest, "manifest_sha256" => sha})
    File.write!(ctx.manifest, "tampered")

    assert_raise Mix.Error, ~r/installation failed: \{:checksum_mismatch, :manifest\}/, fn ->
      Install.run(["laya", "--dir", ctx.dir, "--lock", ctx.lock])
    end

    refute File.exists?(ctx.dir)
  end

  test "rejects a malformed lock file", ctx do
    File.write!(ctx.lock, "[]")

    assert_raise Mix.Error, ~r/cannot read .*:invalid_lockfile/, fn ->
      Install.run(["laya", "--dir", ctx.dir, "--lock", ctx.lock])
    end
  end

  test "rejects a lock entry without a manifest", ctx do
    :ok = Lock.put(ctx.lock, "laya", %{"version" => "test"})

    assert_raise Mix.Error, ~r/invalid laya entry/, fn ->
      Install.run(["laya", "--dir", ctx.dir, "--lock", ctx.lock])
    end
  end

  test "does not touch the lock when the install fails", ctx do
    sha = write_manifest(ctx.manifest)
    File.mkdir_p!(ctx.dir)
    File.write!(Path.join(ctx.dir, "laya.onnx"), "wrong weights")

    assert_raise Mix.Error, ~r/installation failed: \{:destination_exists/, fn ->
      Install.run([
        "laya",
        "--dir",
        ctx.dir,
        "--lock",
        ctx.lock,
        "--manifest",
        ctx.manifest,
        "--manifest-sha256",
        sha
      ])
    end

    refute File.exists?(ctx.lock)
  end

  defp write_manifest(path) do
    files =
      Enum.map(@contents, fn {file, contents} -> %{path: file, sha256: sha256(contents)} end)

    contents =
      Manifest.encode!(%Manifest{
        model: "laya",
        version: "test",
        base_url: "https://models.invalid",
        files: files
      })

    File.write!(path, contents)
    sha256(contents)
  end

  defp place_files(dir) do
    for {file, contents} <- @contents do
      path = Path.join(dir, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end
  end

  defp flush_shell do
    receive do
      {:mix_shell, _, _} -> flush_shell()
    after
      0 -> :ok
    end
  end

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
