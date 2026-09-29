# Benchmarks

`laya.exs` measures query latency of `SystemOne.Models.Laya`.

```console
$ MIX_ENV=bench mix run bench/laya.exs
```

The `bench` environment builds Ortex with CUDA. Follow
[the GPU guide](../guides/gpu.md) first. It runs on CUDA only by default;
set `PROVIDERS=cuda,cpu` to also measure the CPU.

> #### Warning {: .warning}
>
> The CPU run loads a 1.6 GB model and uses every core. On a small machine it
> can make the host unresponsive.

## Results

WSL2 on Windows, Intel Xeon E5-2670 v3 (12 cores, 24 threads), 7.7 GB RAM,
NVIDIA GeForce RTX 3060 Ti (8 GB), ONNX Runtime 1.19.2, CUDA 12.6. Average
time per iteration:

| Job                                   | CPU    | CUDA   | Speedup |
|---------------------------------------|--------|--------|---------|
| 1 query x 1 question                  | 420 ms | 28 ms  | 15x     |
| 1 query x 8 questions                 | 3.1 s  | 103 ms | 30x     |
| 16 concurrent queries x 8 questions   | 59 s   | 1.3 s  | 46x     |

The CPU numbers were taken while other processes shared the machine and the
system was swapping, so treat them as a rough lower bound. The 16-query CPU
job is no longer run by default.
