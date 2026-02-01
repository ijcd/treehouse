# Treehouse Project Guidelines

## Testing Strategy

- **Coverage target: 100%** - No excuses, figure it out
- **Mocks (noun-style via Hammox)** - Use for internal adapters we control (Branch, Registry, Loopback, Mdns, System)
- **Meck (verb-style)** - Only for external libraries we don't control (Exqlite, Mix.Project) and only if necessary

### Pattern

```elixir
# Good: Mock adapter via Hammox
Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _, _ -> {:ok, nil} end)
Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)

# Only when necessary: Meck for external library
:meck.new(Exqlite.Sqlite3, [:passthrough, :no_passthrough_cover])
:meck.expect(Exqlite.Sqlite3, :step, fn _, _ -> {:error, :test_error} end)
```

## Architecture

Adapter pattern throughout:
- `Treehouse.Branch` -> `Branch.Git`
- `Treehouse.Loopback` -> `Loopback.Darwin`, `Loopback.Linux`, `Loopback.Unsupported`
- `Treehouse.Mdns` -> `Mdns.DnsSd`
- `Treehouse.Registry` -> `Registry.Sqlite`
- `Treehouse.System` -> `System.Native`

All adapters auto-detected or configurable via:
```elixir
config :treehouse, :branch_adapter, Treehouse.MockBranch
```
