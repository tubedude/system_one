# Changelog

## v0.2.1 (2026-10-31)

  * Fixed `:act_probability` in Laya answers. Every question after the first
    one read the wrong value from the model output. It now reads column 0 of
    each question's row, like the official `@receptron/laya` package. The bug
    was also in v0.1.x.

## v0.2.0 (2026-10-31)

Breaking: SystemOne now needs Nx 1.0 and EXLA. Ortex is no longer a
dependency. On a machine with CUDA installed, a CPU-only build needs
`EXLA_CPU_ONLY=1` and `XLA_TARGET=cpu`. See the GPU guide.

  * Laya runs on Nx 1.0 and EXLA through Transmuter instead of Ortex. The
    Rust toolchain is no longer needed to build.
  * `:execution_providers` now picks the EXLA client: `:cuda` or `:cpu`.
  * The first query of each new input shape compiles the graph.
  * New `:compile_cache` option keeps compiled programs on disk across
    restarts.

## v0.1.1 (2026-10-31)

  * Added `SystemOne.preview/2` and `SystemOne.Models.Laya.preview/2` for CPU-only
    pre-tokenization inspection and truncation estimation.
  * Added `SystemOne.Preview` struct with per-question token breakdowns.

## v0.1.0 (2026-09-28)

Initial release.

  * `SystemOne` supervises named model instances with status, subscriptions,
    `await_ready/2`, and `reload/2`.
  * `SystemOne.Models.Laya` serves the Laya ONNX model through Ortex.
  * `SystemOne.Installer` and `mix system_one.install` download and verify
    checksum-pinned model bundles.
  * GPU guide for Linux and WSL2, and a CPU/CUDA benchmark in `bench/`.
