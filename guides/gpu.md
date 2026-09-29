# Running on a GPU

SystemOne runs models with ONNX Runtime through
[Ortex](https://hexdocs.pm/ortex). By default Ortex is built for the CPU
only. To run on an NVIDIA GPU, you need three things:

  1. An ONNX Runtime build with the CUDA execution provider.
  2. The CUDA 12 and cuDNN 9 libraries.
  3. `execution_providers: [:cuda, :cpu]` on the SystemOne instance.

This guide covers Linux and WSL2. The steps are the same, except for the
driver.

> This guide is version-specific. It was written for Ortex 0.1.10, ONNX
> Runtime 1.19.2, CUDA 12.6, and cuDNN 9. Recheck Ortex and ONNX Runtime
> compatibility before changing any of those versions.

## 1. Driver

On Linux, install the NVIDIA driver as usual.

On WSL2, install the driver **on Windows only**. Do not install a Linux
driver inside WSL. Windows exposes the GPU to WSL through
`/usr/lib/wsl/lib/libcuda.so`. Check that WSL can see the GPU:

```console
$ nvidia-smi
```

## 2. CUDA and cuDNN libraries

The CUDA provider of ONNX Runtime 1.19 loads these libraries:

  * `libcudart.so.12`, `libcublas.so.12`, `libcublasLt.so.12`
  * `libcufft.so.11`, `libcurand.so.10`
  * `libcudnn.so.9`

On Ubuntu, add NVIDIA's CUDA repository (on WSL, use the "WSL-Ubuntu"
distribution, which has no driver package), then install:

```console
$ sudo apt install cuda-toolkit-12-6 cudnn9-cuda-12
```

## 3. ONNX Runtime with CUDA

Ortex 0.1.10 uses `ort` 2.0.0-rc.8, which expects ONNX Runtime 1.19.2. The
prebuilt CUDA binaries that `ort` used to download are no longer published,
so use the official release instead:

```console
$ mkdir -p ~/.cache/onnxruntime && cd ~/.cache/onnxruntime
$ curl -L https://github.com/microsoft/onnxruntime/releases/download/v1.19.2/onnxruntime-linux-x64-gpu-1.19.2.tgz | tar xz
```

Enable the `cuda` feature of Ortex in your application's config:

```elixir
# config/config.exs
config :ortex, Ortex.Native, features: ["cuda"]
```

Then build Ortex against the downloaded runtime:

```console
$ export ORT_STRATEGY=system
$ export ORT_LIB_LOCATION=~/.cache/onnxruntime/onnxruntime-linux-x64-gpu-1.19.2/lib
$ export ORT_PREFER_DYNAMIC_LINK=1
$ mix deps.compile ortex --force
```

These variables are only needed at build time.

## 4. Run

At run time, the dynamic loader must find the CUDA provider of ONNX Runtime
and the libraries it loads:

```console
$ export LD_LIBRARY_PATH=/usr/lib/wsl/lib:/usr/local/cuda-12.6/lib64:~/.cache/onnxruntime/onnxruntime-linux-x64-gpu-1.19.2/lib:$LD_LIBRARY_PATH
```

On plain Linux, leave out `/usr/lib/wsl/lib`.

Set this in your shell profile, not only in one terminal. The Ortex build
finds `libonnxruntime.so` without it, so the application starts normally.
Only the CUDA provider is missing, and the model silently runs on the CPU.
This happens whenever the server is restarted from a shell without the
variable.

For zsh, in `~/.zshrc`:

```zsh
typeset -T LD_LIBRARY_PATH ld_library_path
typeset -U ld_library_path LD_LIBRARY_PATH
ld_library_path=(/usr/lib/wsl/lib /usr/local/cuda-12.6/lib64 $ld_library_path)
ld_library_path+=($HOME/.cache/onnxruntime/onnxruntime-linux-x64-gpu-1.19.2/lib)
export LD_LIBRARY_PATH
```

For bash, add the `export` line above to `~/.bashrc`. In a release, set
`LD_LIBRARY_PATH` in `rel/env.sh.eex`.

If cuDNN or cuRAND is not installed system-wide, copy `libcudnn*.so.9` and
`libcurand.so.10` into the ONNX Runtime `lib` directory. Keep that directory
last in the path, so other GPU tools still find their own cuDNN first.

Start the instance with CUDA first and the CPU as a fallback:

```elixir
{SystemOne,
 name: MyApp.SystemOne,
 model: SystemOne.Models.Laya,
 model_dir: "priv/models/laya",
 execution_providers: [:cuda, :cpu]}
```

## Checking that the GPU is used

If the CUDA provider cannot load, ONNX Runtime falls back to the CPU and
logs nothing. `SystemOne.status/1` still reports `:ready`, and queries
still work, only 15 to 45 times slower.

Check these three things after the model loads:

  * GPU memory grows by about 2 GB:

    ```console
    $ nvidia-smi --query-gpu=memory.used --format=csv
    ```

  * The BEAM process has the CUDA provider loaded. Replace `PID` with the
    process id of your application:

    ```console
    $ grep -o "/.*providers_cuda.so" /proc/PID/maps | sort -u
    ```

  * The process uses little RAM. On the CPU, Laya adds about 1.6 GB of
    resident memory; on the GPU it does not.

If the CUDA provider is missing, find the library it cannot load:

```console
$ ldd ~/.cache/onnxruntime/onnxruntime-linux-x64-gpu-1.19.2/lib/libonnxruntime_providers_cuda.so | grep "not found"
```
