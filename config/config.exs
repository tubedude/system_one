import Config

# The bench environment builds ONNX Runtime with CUDA so bench/ can compare
# CPU and GPU. A CUDA build still runs on the CPU.
if config_env() == :bench do
  config :ortex, Ortex.Native, features: ["cuda"]
end
