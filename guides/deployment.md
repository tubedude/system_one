# Deployment notes

SystemOne loads model files from the filesystem when its supervised instance
starts. It does not download weights at application runtime. Install and
verify the bundle during a build or deployment step, and make the resulting
directory available to every application instance.

The Laya bundle is approximately 1.6 GB. Installation temporarily needs room
for both the old and new bundles so a failed forced update can preserve the
working copy. Plan memory separately: CPU inference adds roughly 1.6 GB of
resident memory, while the GPU setup observed in this repository uses about
2 GB of GPU memory.

These notes describe common patterns, but this project has not certified a
particular release system, container base image, orchestrator, or production
topology. Exercise the startup and rollback paths in the environment you use.

## Bundled in an OTP release

Running `mix system_one.install laya` in the consumer application writes to
its `priv/models/laya` directory. A normal Mix release includes application
`priv` files. Resolve that location through the application rather than the
current working directory:

```elixir
model_dir = Application.app_dir(:my_app, "priv/models/laya")

children = [
  {SystemOne,
   name: MyApp.SystemOne,
   model: SystemOne.Models.Laya,
   model_dir: model_dir}
]
```

Replace `:my_app` with the consumer application's OTP name. Install the model
before assembling the release, then inspect the release artifact to confirm
that all files under `priv/models/laya` are present. This makes the release
large but self-contained.

## External directory or mounted volume

Keeping weights outside the release makes application artifacts smaller and
allows one model volume to be managed independently. Use an absolute path
from runtime configuration:

```elixir
# config/runtime.exs
model_dir = System.fetch_env!("SYSTEM_ONE_MODEL_DIR")
config :my_app, :system_one_model_dir, model_dir
```

```elixir
# application.ex
model_dir = Application.fetch_env!(:my_app, :system_one_model_dir)

children = [
  {SystemOne,
   name: MyApp.SystemOne,
   model: SystemOne.Models.Laya,
   model_dir: model_dir}
]
```

Populate the directory before starting the application. Do not let several
instances force-replace the same writable directory concurrently. A safer
deployment promotes one verified, immutable bundle and mounts it read-only
into application instances.

## Containers

Two common approaches are:

  * install the bundle in a build stage and copy `priv/models/laya` into the
    final image; or
  * mount a previously verified bundle at an absolute path and configure
    `SYSTEM_ONE_MODEL_DIR`.

The first is self-contained but adds about 1.6 GB to the image. The second
keeps images smaller but makes model provisioning an external dependency.
Whichever approach you choose, verify that the final image contains the
native libraries required by Ortex and Tokenizers. For CUDA, also reproduce
the runtime library path described in the GPU guide.

## Startup and health checks

Starting the supervision tree only begins loading; it does not mean the model
is ready. Use `SystemOne.await_ready/2` in a deployment smoke test, and base
readiness checks on `SystemOne.status/1`:

```elixir
case SystemOne.status(MyApp.SystemOne) do
  %SystemOne.Status{state: :ready} -> :healthy
  %SystemOne.Status{state: :loading} -> :starting
  %SystemOne.Status{state: state, error: error} -> {:unhealthy, state, error}
end
```

Choose a startup timeout based on measured load time on your own hardware.
Do not route queries to an instance until it reports `:ready`.

## Updates and rollback

`mix system_one.install laya --force` stages and verifies a replacement before
publishing it. For external manifests, supply `--manifest` and its trusted
`--manifest-sha256`; commit the generated `system_one_models.lock` file.

After deploying new files, call `SystemOne.reload/2` or restart the instance.
Keep the previously verified bundle or deployment artifact available until
the new instance has loaded and passed a real query. Avoid changing files in
the active model directory while a process is using them.

## Offline builds

The installer accepts a local manifest path or `file://` URL. For a fully
offline build, stage every bundle file at the destination using the exact
paths in that manifest. The installer verifies those existing files and
adopts the directory without downloading them:

```console
$ mix system_one.install laya \
    --manifest /trusted/manifests/laya.json \
    --manifest-sha256 EXPECTED_SHA256 \
    --dir /opt/models/laya
```

Treat the manifest checksum as deployment configuration: it is the trust pin
for all file checksums in that manifest. If any staged file is absent or has
the wrong checksum, installation fails instead of fetching a replacement.
