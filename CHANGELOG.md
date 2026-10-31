# Changelog

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
