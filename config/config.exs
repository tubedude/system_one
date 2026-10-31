import Config

# Do not reserve most of the GPU up front. Other processes, such as a desktop,
# may already use part of it.
config :exla, :clients,
  cuda: [platform: :cuda, preallocate: false],
  host: [platform: :host]
