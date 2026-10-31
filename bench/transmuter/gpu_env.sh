# Puts the CUDA libraries from NVIDIA's pip wheels on the loader path.
# Install them first, as described in guides/gpu.md, into GPU_LIBS.
GPU_LIBS="${GPU_LIBS:-$HOME/.cache/exla-cuda-libs}"
LD_LIBRARY_PATH="$(find "$GPU_LIBS/nvidia" -maxdepth 2 -type d -name lib | tr '\n' ':')/usr/local/cuda/targets/x86_64-linux/lib:/usr/lib/wsl/lib"
export LD_LIBRARY_PATH
