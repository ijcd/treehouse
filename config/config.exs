import Config

config :treehouse,
  registry_path: "~/.local/share/treehouse/registry.db",
  ip_range_start: 10,
  ip_range_end: 99,
  domain: "local",
  stale_threshold_days: 7

import_config "#{config_env()}.exs"
