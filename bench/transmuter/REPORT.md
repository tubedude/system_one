# Transmuter vs Ortex on an ONNX classifier (Laya)

Date: 2026-10-31
Author: Roberto Trevisan

> **Update, 2026-10-31.** After the first version of this report, we read
> Transmuter's source and found the EXLA disk cache. It answers questions 2
> and 3 below. Additions are marked "Update". The rest of the report is
> unchanged.

## Summary

Transmuter 2.0.0 runs our ONNX model with no changes to the model and no custom code.

- On the CPU, the outputs match ONNX Runtime (through Ortex) to within 2.2e-5.
- On the GPU, both runtimes drift from the CPU result by a similar small amount. Transmuter drifts by up to 6.0e-3, and ONNX Runtime CUDA by up to 3.1e-3.
- On the GPU, Transmuter is about 15% faster than ONNX Runtime CUDA once warm.
- On the CPU, Transmuter is about 35% slower than ONNX Runtime.
- Transmuter's main cost is the first call: about 30 seconds of CUDA compile for each input shape.
- **Update:** With the EXLA disk cache, a shape that was compiled before loads in 2.7 seconds after a restart.

We are trying a move from Ortex to Transmuter on the `transmuter` branch of this repository. The main reasons are Nx 1.0 support and a pure Nx stack. Speed is a wash on the GPU. The last Ortex version is the `ortex` tag.

## The model

Laya is a multi-question classifier. It is published at
[receptron/laya-onnx](https://huggingface.co/receptron/laya-onnx), revision
`68f27dfe5a27a54fb2b1fefc432f43f972e90868`.

- Graph file `laya.onnx` is 3.8 MB. External weights `laya.onnx.data` are 1.6 GB, in f32.
- Operators we saw in the graph: `Cast`, `Concat`, `Gather`, `GatherND`, `LayerNormalization`, `Reshape`, `Shape`, `Softmax`, `Split`, `Transpose`, plus matmul and elementwise operators.

Inputs:

| Name | Type | Shape |
|---|---|---|
| `input_ids` | s64 | {batch, seq} |
| `attention_mask` | s64 | {batch, seq} |
| `marker_pos` | s64 | {batch, 20} |
| `marker_mask` | u8 | {batch, 20} |
| `qtype` | s64 | {batch} |

Outputs:

| Name | Type | Shape |
|---|---|---|
| `logits` | f32 | {batch, 20} |
| `act_probs` | f32 | {batch, 2} |

## Test setup

- One fixed input: batch 3, sequence length 128. Ortex on the CPU produced the reference outputs from this same input.
- We fed the same input tensors to every runtime.
- "Steady" means the average of 10 runs, after 3 warm-up runs.
- We ran one runtime at a time, so no two runs shared the machine.

| Item | Value |
|---|---|
| CPU | Intel Xeon E5-2670 v3, 24 threads |
| GPU | NVIDIA GeForce RTX 3060 Ti, 8 GB |
| RAM | 8 GB |
| OS | Ubuntu on WSL2, NVIDIA driver 591.59 |
| Elixir / OTP | 1.20.3 / 29 |
| Transmuter | 2.0.0 |
| Nx / EXLA / XLA | 1.0.0 / 1.0.0 / 0.10.0 |
| Ortex | 0.1.10, built with the `cuda` feature for the GPU runs |
| ONNX Runtime | 1.19.2 GPU build, used for both CPU and CUDA execution providers |

## Results

### Accuracy, compared with ONNX Runtime on the CPU

| Runtime | `logits` max abs diff | `act_probs` max abs diff |
|---|---|---|
| ONNX Runtime, CUDA | 3.1e-3 | 0 |
| Transmuter, EXLA CPU | 2.2e-5 | 0 |
| Transmuter, EXLA CUDA | 6.0e-3 | 0 |

The first logits of each row:

```
Ortex         [-4.2693543, -1.4524122, 6.2035465]
              [-2.5082579, -0.08278245, 3.4768045]
              [ 1.5127183,  0.6793078]
EXLA CUDA     [-4.269124,  -1.4522204, 6.203142]
              [-2.5085077, -0.08169109, 3.4759467]
              [ 1.5067148,  0.680585]
```

Both GPU runtimes drift from the CPU result by the same order of magnitude, so this looks like normal GPU math, not a Transmuter bug. The gap does not change any answer in our use. We tried `NVIDIA_TF32_OVERRIDE=0` on the Transmuter run to rule out TF32 matmuls. The gap stayed at 5.7e-3. That setting may not reach XLA, so TF32 is still not ruled out.

### Speed

| Runtime | Load | Compile | First run | Steady |
| --- | --- | --- | --- | --- |
| Ortex, CPU | 3.2 s | none | 1.28 s | 1.04 s |
| Transmuter, EXLA CPU | 5.8 s | 3.0 s | 6.3 s | 1.41 s |
| Ortex, CUDA | 4.7 s | none | 0.91 s | 0.040 s |
| Transmuter, EXLA CUDA | 7.0 s | 30.4 s | 0.28 s | 0.034 s |

On the GPU, the time to the first answer is about 1.9 s for Ortex and about 37 s for Transmuter, counting load, compile, and the first run.

Notes:

- Load and first-run times varied between runs by up to about 3 times. The steady numbers were stable.
- CUDA compile takes about 30 seconds per input shape. We pad to 4 sequence lengths, so warm-up costs about 2 minutes unless the compile cache helps. ONNX Runtime has no such step, so this is the largest practical difference for us.
- During the CUDA compile, `ptxas` reported register spills in several `gemm_fusion_dot` kernels. The worst one spilled 8,936 bytes.

## Update: compile cache on disk

`Transmuter.compile/3` compiles the example inputs right away. Other shapes compile on their first call and stay in a per-segment memory cache, 8 shapes by default (`:cache_size`). With EXLA, a `:cache` path prefix also saves each compiled segment to disk as `<prefix>-<hash>`. The hash covers the graph without its weights, the argument shapes, and the static inputs. A new OS process loads the file instead of compiling.

We tested it on the GPU with the same model and input, in two separate processes:

| Run | Compile | First run |
|---|---|---|
| First process, empty cache | 29.2 s | 0.27 s |
| Second process, cache on disk | 2.7 s | 0.26 s |

One shape used 2.2 MB of disk. The `transmuter` branch of this repository now passes a `:compile_cache` option through to this `:cache` path.

## Problems we hit

None of these are Transmuter bugs. They are all about the EXLA build and CUDA setup. We list them because Transmuter users will hit them too.

1. **The CPU-only build needs `EXLA_CPU_ONLY=1`.** EXLA turns on CUDA when `nvcc` is on the `PATH`. Setting `XLA_TARGET=cpu` alone still produced a CUDA build. That build then failed to load with `undefined symbol: cudaGetErrorString`.
2. **The CUDA build needs several libraries that the CUDA toolkit does not ship.** We installed these from pip into a local folder and put them on `LD_LIBRARY_PATH`:
   `nvidia-nccl-cu12`, `nvidia-cudnn-cu12==9.*`, `nvidia-nvshmem-cu12==3.*`, `nvidia-cuda-nvrtc-cu12==12.9.*`, `nvidia-cusparse-cu12`, `nvidia-nvjitlink-cu12==12.9.*`.
3. **There is an NVSHMEM version mismatch.** The library asks for `nvshmem_transport_ibrc.so.3`. The `nvidia-nvshmem-cu12==3.*` wheel ships `nvshmem_transport_ibrc.so.7`. A symlink from `.so.3` to `.so.7` made it load. This is the InfiniBand transport, which a single GPU does not use.
4. **GPU memory preallocation caused out-of-memory errors.** The desktop already used 3 GB of the 8 GB GPU. With the default settings, the run went out of memory when it copied outputs back to the host. This config fixed it:

   ```elixir
   config :exla, :clients,
     cuda: [platform: :cuda, preallocate: false],
     host: [platform: :host]
   ```

5. **One CUDA build can replace the CPU build.** `xla` and `exla` share one build cache across Mix environments, and the cache does not record the target. A build with only `EXLA_CPU_ONLY=1` set, without `XLA_TARGET=cpu`, rebuilt XLA for CUDA. After that, the test environment failed to load too. Setting both variables on every build avoids it.
6. **Pinned host memory warnings appeared on WSL2.** During load, we saw many lines like `could not allocate pinned host of size ... CUDA_ERROR_OUT_OF_MEMORY`. The run still worked.

## Questions for the Transmuter developer

1. On CUDA, Transmuter drifts about twice as far from the CPU result as ONNX Runtime CUDA does (6.0e-3 against 3.1e-3). Is that expected? Is there an option to force full-precision matmuls?
2. Can we compile several input shapes ahead of time, at load, to avoid a 30-second pause on the first call of each padding size?
   **Update:** We found no API for this. A call per shape with dummy inputs works, as `Transmuter.Serving` does at startup. With the disk cache, this matters only on the first start. A built-in warm-up for a list of shapes would still help.
3. Can the compile cache persist across VM restarts for CUDA, and what is the cache key?
   **Update:** Answered by the `:cache` option, described above. It works on CUDA and on the CPU.
4. Is CPU speed a goal? On the CPU, Transmuter runs about 35% slower than ONNX Runtime for this model.

## How to reproduce

The files are in this folder.

- `dump_ortex.exs` builds the input tensors and the Ortex CPU reference. It ran from this repository at the `ortex` tag.
- `laya_ref.bin` holds those inputs and reference outputs, in Erlang term format.
- `compare.exs` runs the Transmuter CPU comparison.
- `compare_gpu.exs` runs the Transmuter CUDA comparison.
- **Update:** `disk_cache.exs` tests the EXLA disk cache. Run it twice, as two processes.
- `time_ortex_cuda.exs` times Ortex on CUDA. Run it from a project whose Ortex was built with the `cuda` feature.
- `mix.exs` and `config.exs` are the standalone project used for the Transmuter runs. `config.exs` turns off GPU preallocation.
- `gpu_env.sh` puts the CUDA libraries from NVIDIA's pip wheels on `LD_LIBRARY_PATH`. The install steps are in `guides/gpu.md`.

To rerun the Transmuter side, copy this folder, move `config.exs` to `config/config.exs`, and point `LAYA_ONNX` at the model:

```sh
export LAYA_ONNX=/path/to/laya.onnx
mix deps.get

# CPU
EXLA_CPU_ONLY=1 mix deps.compile exla --force
mix run compare.exs

# CUDA
. ./gpu_env.sh
XLA_TARGET=cuda12 mix deps.compile exla --force
XLA_TARGET=cuda12 mix run compare_gpu.exs
```

The same model, served through `Nx.Serving`, is in `lib/system_one/models/laya.ex` on this branch.
