import Config

# Tests manually start their own Allocators with temp paths
config :treehouse,
  start_allocator: false

# Quiet logs during tests
config :logger, level: :warning
