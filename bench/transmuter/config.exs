import Config

# Do not grab most of the GPU up front. The desktop already uses part of it.
config :exla, :clients,
  cuda: [platform: :cuda, preallocate: false],
  host: [platform: :host]
