# Treehouse

Local development IP manager - a home for your worktrees.

Allocates unique IPs from your available loopback aliases per **project/branch** combination, persists in SQLite, and optionally announces via mDNS.

## The Problem

When running multiple Phoenix apps (or multiple branches of the same app) locally, they all want to bind to `localhost:4000`. You end up juggling ports or stopping one server to start another.

Treehouse gives each project/branch combination its own IP address from the `127.0.0.x` range, so `main` and `feature-x` can run simultaneously on the same port.

## Quick Start

```bash
# 1. Add loopback aliases (one-time, until reboot)
mix treehouse.loopback | sudo sh

# 2. Check your setup
mix treehouse.doctor

# 3. Allocate and run
mix phx.server
```

## Installation

Add to `mix.exs`:

```elixir
def deps do
  [{:treehouse, "~> 0.1.0"}]
end
```

## Loopback Setup

Before Phoenix can bind to addresses like `127.0.0.42`, you need to create loopback aliases on the `lo0` interface. Treehouse **discovers available IPs** from your system - you configure the aliases, Treehouse finds them.

### Quick Setup (Temporary)

```bash
# Show the setup commands
mix treehouse.loopback

# Or pipe directly to shell
mix treehouse.loopback | sudo sh
```

This adds aliases for `127.0.0.10` through `127.0.0.99`. Aliases are lost on reboot.

### Check Your Setup

```bash
$ mix treehouse.doctor

=== Loopback Aliases ===
Status: OK (90 IPs available)
Range: 127.0.0.10 - 127.0.0.99

=== Registry ===
Path: /Users/you/.local/share/treehouse/registry.db
Status: OK

=== Current Allocations ===
PROJECT         BRANCH               IP             HOSTNAME
---------------------------------------------------------------------------
myapp           main                 127.0.0.10     main.myapp.local
myapp           feature-login        127.0.0.11     feature-login.myapp.local
```

### Persistent Setup (macOS)

For aliases that survive reboot, you have several options:

#### Option A: LaunchDaemon

Create `/Library/LaunchDaemons/com.treehouse.loopback.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.treehouse.loopback</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>-c</string>
    <string>for i in $(seq 10 99); do ifconfig lo0 alias 127.0.0.$i up; done</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
```

Load with: `sudo launchctl load /Library/LaunchDaemons/com.treehouse.loopback.plist`

#### Option B: nix-darwin

If you use nix-darwin for system configuration:

```nix
# In your darwin configuration
{
  system.activationScripts.postActivation.text = ''
    # Treehouse loopback aliases
    for i in $(seq 10 99); do
      /sbin/ifconfig lo0 alias 127.0.0.$i up 2>/dev/null || true
    done
  '';
}
```

### Hairpin NAT (Optional)

If your server needs to make HTTP requests to itself via the loopback IP (e.g., server-side rendering that calls its own API), you need PF NAT rules:

```bash
# Generate setup including PF rules
mix treehouse.loopback --pf > /tmp/loopback-setup.sh
sudo sh /tmp/loopback-setup.sh
```

This adds packet filter rules that allow hairpin routing on the loopback interface.

#### nix-darwin with PF

```nix
{
  system.activationScripts.postActivation.text = ''
    # Loopback aliases
    for i in $(seq 10 99); do
      /sbin/ifconfig lo0 alias 127.0.0.$i up 2>/dev/null || true
    done

    # PF NAT for hairpin routing
    cat > /etc/pf.anchors/loopback_treehouse << 'EOF'
    ${builtins.concatStringsSep "\n" (
      builtins.genList (i: "nat on lo0 from 127.0.0.${toString (i + 10)} to 127.0.0.${toString (i + 10)} -> 127.0.0.1") 90
    )}
    EOF

    # Enable if not already in pf.conf
    grep -q 'loopback_treehouse' /etc/pf.conf || {
      echo 'nat-anchor "loopback_treehouse"' >> /etc/pf.conf
      echo 'load anchor "loopback_treehouse" from "/etc/pf.anchors/loopback_treehouse"' >> /etc/pf.conf
    }
    /sbin/pfctl -f /etc/pf.conf
    /sbin/pfctl -e 2>/dev/null || true
  '';
}
```

## Phoenix Integration

Treehouse integrates with Phoenix by configuring the endpoint to bind to a branch-specific IP.

### Option 1: config/dev.exs (Recommended)

The simplest approach - add to the top of `config/dev.exs`:

```elixir
# config/dev.exs

# Treehouse allocates a unique IP for this project/branch
{:ok, treehouse} = Treehouse.setup(port: 4000)

config :my_app, MyAppWeb.Endpoint,
  http: [ip: treehouse.ip_tuple, port: 4000],
  url: [host: treehouse.hostname]
```

**When branch is detected**: At compile time, when Mix evaluates the config.

**Behavior**: Branch is detected when you run `mix compile`, `mix phx.server`, or any Mix task. Since `mix phx.server` recompiles changed files, switching branches and starting the server typically picks up the new branch.

**Caveat**: If you switch branches without any file changes, the old branch's IP might be used until you force recompilation with `mix compile --force`.

### Option 2: config/runtime.exs (Always Fresh)

For guaranteed fresh branch detection on every server start:

```elixir
# config/runtime.exs

if config_env() == :dev do
  {:ok, treehouse} = Treehouse.setup(port: 4000)

  config :my_app, MyAppWeb.Endpoint,
    http: [ip: treehouse.ip_tuple, port: 4000],
    url: [host: treehouse.hostname]
end
```

**When branch is detected**: At runtime, every time the application starts.

**Behavior**: Branch is always detected when you run `mix phx.server`, regardless of compilation state. The `if config_env() == :dev` guard ensures this only runs in development.

**Trade-off**: Slightly more verbose, but guarantees the IP always matches your current git branch.

### What You Get

After setup, `treehouse` contains everything needed for Phoenix:

```elixir
%{
  project: "myapp",           # From Mix.Project or config
  branch: "feature-login",    # From git
  ip: "127.0.0.42",          # Allocated IP string
  ip_tuple: {127, 0, 0, 42}, # For endpoint :http config
  hostname: "feature-login.myapp.local",  # For :url config
  mdns_pid: #PID<0.456.0>    # mDNS registration (or nil)
}
```

### Complete Example

Here's a full `config/dev.exs` with Treehouse:

```elixir
import Config

# === Treehouse Setup ===
{:ok, treehouse} = Treehouse.setup(port: 4000)

# === Phoenix Endpoint ===
config :my_app, MyAppWeb.Endpoint,
  http: [ip: treehouse.ip_tuple, port: 4000],
  url: [host: treehouse.hostname, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-secret-key...",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:my_app, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:my_app, ~w(--watch)]}
  ]

# ... rest of dev config
```

Now start your server:

```bash
$ mix phx.server
[info] [treehouse] Available IPs: 127.0.0.10, 127.0.0.11, 127.0.0.12 ... 127.0.0.99 (90 total)
[info] [treehouse] Allocated 127.0.0.42 for myapp:feature-login
[info] Running MyAppWeb.Endpoint with Bandit 1.5.0 at 127.0.0.42:4000 (http)
[info] Access MyAppWeb.Endpoint at http://feature-login.myapp.local:4000
```

## mDNS (Automatic Hostname Resolution)

By default, `setup/1` registers an mDNS hostname so `feature-login.myapp.local` resolves to `127.0.0.42` without editing `/etc/hosts`.

> **Note**: mDNS registration uses macOS `dns-sd` command. On Linux, you'd need Avahi or similar.

### Verifying mDNS (macOS only)

```bash
# Browse registered HTTP services
dns-sd -B _http._tcp local

# Lookup your hostname
dns-sd -G v4 feature-login.myapp.local

# Test resolution
ping feature-login.myapp.local
```

### Disabling mDNS

```elixir
{:ok, treehouse} = Treehouse.setup(port: 4000, mdns: false)
```

### Manual mDNS Control

For use outside of `setup/1`:

```elixir
# After allocating an IP manually
{:ok, ip} = Treehouse.allocate("my-branch")
# => {:ok, "127.0.0.42"}

# Register mDNS hostname -> IP mapping
{:ok, pid} = Treehouse.Mdns.register("my-branch.myapp", ip, 4000)
# Now http://my-branch.myapp.local:4000 resolves to 127.0.0.42

# When done, unregister (or let process exit)
Treehouse.Mdns.unregister(pid)
```

## Mix Tasks

### Diagnostics

```bash
# Check setup and diagnose issues
$ mix treehouse.doctor

# Show commands to set up loopback aliases
$ mix treehouse.loopback

# Include hairpin NAT rules for self-referencing servers
$ mix treehouse.loopback --pf

# Custom IP range
$ mix treehouse.loopback --start 10 --end 50
```

### Managing Allocations

```bash
# List all allocations across all projects
$ mix treehouse.list

PROJECT         BRANCH               IP             HOSTNAME
--------------------------------------------------------------------------------
myapp           main                 127.0.0.10     main.myapp.local
myapp           feature-login        127.0.0.11     feature-login.myapp.local
other_app       main                 127.0.0.12     main.other_app.local

# Show current branch's allocation
$ mix treehouse.info
Project:    myapp
Branch:     feature-login
Hostname:   feature-login.myapp.local
IP:         127.0.0.11
Allocated:  2024-01-15T10:30:00Z
Last seen:  2024-01-15T14:22:00Z

# Allocate IP for current branch (or specify one)
$ mix treehouse.allocate
Allocated IP for myapp:feature-login

  IP:       127.0.0.11
  Hostname: feature-login.myapp.local

$ mix treehouse.allocate other-branch
Allocated IP for myapp:other-branch

  IP:       127.0.0.12
  Hostname: other-branch.myapp.local

# Release current branch's allocation
$ mix treehouse.release
Released allocation for: myapp:feature-login

$ mix treehouse.release other-branch
Released allocation for: myapp:other-branch
```

### Configuration

```bash
# View current IP range configuration
$ mix treehouse.config

=== Treehouse Configuration ===

IP Range: 127.0.0.10 - 127.0.0.99

# Set custom IP range (persisted in database)
$ mix treehouse.config --start 20 --end 80
Set ip_range_start = 20
Set ip_range_end = 80

=== Treehouse Configuration ===

IP Range: 127.0.0.20 - 127.0.0.80
```

The configured IP range is stored in the database and filters which discovered loopback aliases are used. This allows different machines to have different ranges while sharing the same codebase.

## Manual API

For use outside Phoenix config. Note: `setup/1` auto-starts the application, but these functions require it to be running:

```elixir
# Ensure app is started (setup/1 does this automatically)
{:ok, _} = Application.ensure_all_started(:treehouse)

# Allocate (project auto-detected from Mix.Project)
{:ok, ip} = Treehouse.allocate("my-branch")
# => {:ok, "127.0.0.10"}

# Allocate with explicit project
{:ok, ip} = Treehouse.allocate("other_app", "main")
# => {:ok, "127.0.0.11"}

# Get info
{:ok, info} = Treehouse.info("my-branch")
# => {:ok, %{branch: "my-branch", ip_suffix: 10, ...}}

# Release
:ok = Treehouse.release("my-branch")
```

## Configuration

All configuration is optional - sensible defaults work for most users.

### Global State

Treehouse uses a **shared SQLite database** at `~/.local/share/treehouse/registry.db` to track allocations across all projects. This ensures different projects don't collide.

### IP Pool Discovery

Treehouse **discovers available IPs** by interrogating your system's loopback interface. It finds all `127.0.0.x` aliases (where x > 1) and uses those as the allocation pool.

```bash
# See what Treehouse discovers
$ mix treehouse.doctor

=== Loopback Aliases ===
Status: OK (90 IPs available)
Range: 127.0.0.10 - 127.0.0.99
```

If no aliases are found, Treehouse will warn you and `mix treehouse.doctor` will show setup commands.

### Per-Project Config

Each project can override settings in its `config/config.exs`:

```elixir
config :treehouse,
  # Override auto-detected project name
  project: "myapp",

  # mDNS domain suffix (default: "local")
  domain: "local"
```

### Advanced Options

These settings have sensible defaults. Only change if you have specific needs:

```elixir
config :treehouse,
  # Database location
  registry_path: "~/.local/share/treehouse/registry.db",

  # Days before allocation considered stale for reclamation
  stale_threshold_days: 7
```

For testing, you can override the discovered pool with explicit IP ranges:

```elixir
# Only for testing - normally let Treehouse discover available IPs
config :treehouse,
  ip_range_start: 10,
  ip_range_end: 99
```

## How It Works

1. **Loopback Discovery**: Interrogates `ifconfig lo0` (macOS) or `ip addr show lo` (Linux) for available `127.0.0.x` aliases
2. **Project Detection**: Uses `Mix.Project.config()[:app]`, falls back to directory name
3. **Branch Detection**: Runs `git rev-parse --abbrev-ref HEAD`
4. **Allocation**: Finds or creates a unique IP for the project/branch combination
5. **Persistence**: SQLite database shared across all projects
6. **Lazy Reclaim**: When pool exhausted, reclaims oldest stale allocation
7. **mDNS**: Registers `branch.project.local` via macOS `dns-sd`

## Running Multiple Branches

The whole point - run `main` and `feature-x` simultaneously:

```bash
# Terminal 1: main branch
$ git checkout main
$ mix phx.server
[info] [treehouse] Allocated 127.0.0.10 for myapp:main
[info] Running at http://main.myapp.local:4000

# Terminal 2: feature branch
$ git checkout feature-x
$ mix phx.server
[info] [treehouse] Allocated 127.0.0.11 for myapp:feature-x
[info] Running at http://feature-x.myapp.local:4000
```

Both servers run on port 4000, but different IPs. Access either via their hostnames.

## Troubleshooting

### "No loopback aliases found"

Run `mix treehouse.doctor` to see setup commands, or:

```bash
mix treehouse.loopback | sudo sh
```

### "IP pool exhausted"

All available IPs are in use. Either:
- Add more loopback aliases
- Release unused allocations with `mix treehouse.release`
- Wait for stale allocations to be reclaimed (7 days by default)

### mDNS not resolving

1. Verify registration: `dns-sd -B _http._tcp local`
2. Check firewall isn't blocking mDNS (port 5353 UDP)
3. Try `ping feature-login.myapp.local`

## License

MIT
