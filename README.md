# Treehouse

Local development IP manager - a home for your worktrees.

Allocates unique IPs from `127.0.0.10-99` per git branch, persists in SQLite, and optionally announces via mDNS.

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [{:treehouse, "~> 0.1.0"}]
end
```

## Usage

### Basic

```elixir
# Get IP for current branch
{:ok, ip} = Treehouse.allocate("my-feature-branch")
# => {:ok, "127.0.0.10"}

# Same branch always gets same IP
{:ok, ip} = Treehouse.allocate("my-feature-branch")
# => {:ok, "127.0.0.10"}

# Different branch gets different IP
{:ok, ip} = Treehouse.allocate("another-branch")
# => {:ok, "127.0.0.11"}
```

### Phoenix Integration

In `config/dev.exs`:

```elixir
{:ok, branch} = Treehouse.Branch.current()
{:ok, ip} = Treehouse.allocate(branch)

config :my_app, MyAppWeb.Endpoint,
  http: [ip: Treehouse.parse_ip(ip), port: 4000],
  url: [host: "#{Treehouse.Branch.sanitize(branch)}.local"]
```

### Mix Tasks

```bash
# List all allocations
mix treehouse.list

# Show current branch allocation
mix treehouse.info

# Release current branch allocation
mix treehouse.release
```

### mDNS Announcement

```elixir
# Register service for discovery
{:ok, pid} = Treehouse.Mdns.register("my-branch", ip, 4000)

# Later...
Treehouse.Mdns.unregister(pid)
```

## Configuration

```elixir
# config/config.exs
config :treehouse,
  registry_path: "~/.local/share/treehouse/registry.db",
  ip_range_start: 10,
  ip_range_end: 99,
  domain: "local",
  stale_threshold_days: 7
```

## How It Works

1. **Allocation**: Each branch gets a unique IP from the pool (127.0.0.10-99)
2. **Persistence**: SQLite stores allocations at `~/.local/share/treehouse/registry.db`
3. **Lazy Reclaim**: IPs are only reclaimed when pool exhausted, oldest stale allocation first
4. **mDNS**: Optional service announcement via macOS `dns-sd`

## Prerequisites

For loopback aliases (binding to 127.0.0.x where x > 1), you need to create the aliases first:

```bash
# macOS - add loopback aliases
for i in $(seq 10 99); do
  sudo ifconfig lo0 alias 127.0.0.$i up
done
```

## License

MIT
