# Running on a GPU

SystemOne runs Laya with [Transmuter](https://hexdocs.pm/transmuter) on
[EXLA](https://hexdocs.pm/exla). EXLA picks its build target when it compiles:

  * With `EXLA_CPU_ONLY=1`, it builds for the CPU only.
  * Without it, it builds for CUDA whenever `nvcc` is on the `PATH`. Setting
    `XLA_TARGET=cpu` alone does not stop this.

For a CPU build on a machine that has CUDA installed, set both variables on
every build, in every Mix environment:

```console
$ export EXLA_CPU_ONLY=1 XLA_TARGET=cpu
```

The `xla` and `exla` packages keep one shared build cache for all Mix
environments, and that cache does not record whether it holds a CPU or a CUDA
build. A single build with only one of the two variables set can replace the
CPU build with a CUDA one. The CUDA build then fails to load with
`libnccl.so.2: cannot open shared object file`.

This guide covers Linux and WSL2. It was tested with EXLA 1.0.0, XLA 0.10.0,
CUDA 12.6, and an RTX 3060 Ti on WSL2.

## 1. Driver

On Linux, install the NVIDIA driver as usual.

On WSL2, install the driver **on Windows only**. Do not install a Linux
driver inside WSL. Check that WSL can see the GPU:

```console
$ nvidia-smi
```

## 2. CUDA libraries

Install the CUDA 12 toolkit. The CUDA build of EXLA also loads libraries that
the toolkit does not ship. The simplest source is NVIDIA's pip wheels,
installed into a local folder:

```console
$ pip3 install --target ~/.cache/exla-cuda-libs \
    nvidia-nccl-cu12 "nvidia-cudnn-cu12==9.*" "nvidia-nvshmem-cu12==3.*" \
    "nvidia-cuda-nvrtc-cu12==12.9.*" nvidia-cusparse-cu12 "nvidia-nvjitlink-cu12==12.9.*"
```

The NVSHMEM wheel names its InfiniBand transport `.so.7`, but EXLA asks for
`.so.3`. A single GPU never uses that transport, so a symlink is enough:

```console
$ cd ~/.cache/exla-cuda-libs/nvidia/nvshmem/lib
$ ln -s nvshmem_transport_ibrc.so.7 nvshmem_transport_ibrc.so.3
```

## 3. Build EXLA for CUDA

```console
$ export XLA_TARGET=cuda12
$ mix deps.compile exla --force
```

## 4. Run

The dynamic loader must find the libraries from step 2:

```console
$ export LD_LIBRARY_PATH=$(find ~/.cache/exla-cuda-libs/nvidia -maxdepth 2 -type d -name lib | tr '\n' ':')/usr/local/cuda/targets/x86_64-linux/lib:/usr/lib/wsl/lib
```

On plain Linux, leave out `/usr/lib/wsl/lib`. In a release, set this in
`rel/env.sh.eex`. Check that nothing is missing:

```console
$ ldd _build/prod/lib/exla/priv/libexla.so | grep "not found"
```

By default, XLA reserves most of the GPU memory when it starts. If another
process already uses part of the GPU, queries can fail with
`CUDA_ERROR_OUT_OF_MEMORY`. Turn preallocation off in your application:

```elixir
# config/config.exs
config :exla, :clients,
  cuda: [platform: :cuda, preallocate: false],
  host: [platform: :host]
```

Start the instance on CUDA:

```elixir
{SystemOne,
 name: MyApp.SystemOne,
 model: SystemOne.Models.Laya,
 model_dir: "priv/models/laya",
 execution_providers: [:cuda]}
```

## Compile time

Transmuter compiles the graph once for each input shape. On a GPU, each shape
takes about 30 seconds the first time. Laya pads batches to a few row counts
and four sequence lengths, so the first queries after a restart are slow.
Later queries of the same shape take tens of milliseconds.

To keep compiled programs across restarts, set `:compile_cache` to a path
prefix in a writable directory:

```elixir
{SystemOne,
 name: MyApp.SystemOne,
 model: SystemOne.Models.Laya,
 model_dir: "priv/models/laya",
 execution_providers: [:cuda],
 compile_cache: "/var/cache/my_app/laya"}
```

On an RTX 3060 Ti, one shape took 29 seconds to compile and 2.7 seconds to
load from this cache. Each shape uses about 2 MB of disk. In a container,
put the cache on a persistent volume, or it is lost on every deploy.
