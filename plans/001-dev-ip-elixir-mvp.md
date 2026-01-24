# Treehouse - MVP Implementation Plan

> **Package name:** `treehouse` (was `treehouse`)

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build Elixir Hex package that allocates per-branch IPs from 127.0.0.10-99, stores in SQLite, announces via mDNS.

**Architecture:** GenServer-backed allocator coordinates concurrent requests across independent Erlang VMs via shared SQLite. Port-wrapped dns-sd provides mDNS. Optional Phoenix integration helper.

**Tech Stack:** Elixir, exqlite (raw SQLite), GenServer, Port (dns-sd wrapper)

---

## Design Decisions (Resolved)

| Question | Decision |
|----------|----------|
| exqlite vs ecto_sqlite3 | exqlite - simpler, fewer deps |
| Port in schema? | **No** - we return IP only, caller decides port |
| Heartbeat strategy | On-access only (update `last_seen_at` when `get_or_allocate` called) |
| Stale cleanup | **Lazy** - only reclaim oldest when pool exhausted (1 week threshold) |
| PID tracking | No - multiple VMs make this unreliable; use timestamp instead |
| Multi-app umbrella | Not our problem - one call = one IP, caller manages |

---

## Core vs Optional

**Core (this library manages):**
- IP allocation from pool
- SQLite registry (shared `~/.local/share/treehouse/registry.db`)
- mDNS announcement via dns-sd
- Lazy reclamation when pool exhausted

**Optional helpers (convenience, not required):**
- `Treehouse.Phoenix` - configures endpoint with allocated IP
- Mix tasks - CLI for debugging

**Not our concern:**
- Port binding (Phoenix decides)
- Database naming (Phoenix decides)
- Loopback aliases (prereq: nix-darwin or manual)

---

## Prerequisites (External)

Before using this package:
1. Loopback aliases created via nix-darwin or manual `ifconfig lo0 alias`
2. macOS with `dns-sd` (built-in)

---

## Task Overview

| Task | Component | Purpose |
|------|-----------|---------|
| 1 | Project Setup | mix new, deps, config structure |
| 2 | Treehouse.Git | Branch detection and sanitization |
| 3 | Treehouse.Registry | SQLite storage layer |
| 4 | Treehouse.Allocator | GenServer IP allocation + lazy reclaim |
| 5 | Treehouse.Mdns | dns-sd Port wrapper |
| 6 | Treehouse.Phoenix | Optional endpoint configuration helper |
| 7 | Treehouse.Application | Supervision tree |
| 8 | Mix Tasks | CLI interface |
| 9 | Integration Tests | End-to-end validation |
| 10 | Documentation | README |

---

## Task 1: Project Setup

**Files:**
- Create: `mix.exs`
- Create: `lib/treehouse.ex`
- Create: `config/config.exs`
- Create: `config/test.exs`
- Create: `test/test_helper.exs`

**Step 1.1: Create project skeleton**

```bash
mix new treehouse --sup
cd treehouse
```

**Step 1.2: Configure mix.exs with dependencies**

```elixir
# mix.exs
defmodule Treehouse.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ijcd/treehouse"

  def project do
    [
      app: :treehouse,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Local development IP manager",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Treehouse.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.23"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
```

**Step 1.3: Create config files**

```elixir
# config/config.exs
import Config

config :treehouse,
  registry_path: "~/.local/share/treehouse/registry.db",
  ip_range_start: 10,
  ip_range_end: 99,
  domain: "local",
  stale_threshold_days: 7

import_config "#{config_env()}.exs"
```

```elixir
# config/test.exs
import Config

# Tests use temp files, not this path
config :treehouse,
  registry_path: nil
```

**Step 1.4: Create main module stub**

```elixir
# lib/treehouse.ex
defmodule Treehouse do
  @moduledoc """
  Local development IP manager.

  Allocates unique IPs from 127.0.0.10-99 per git branch,
  persists in SQLite, and announces via mDNS.

  ## Usage

      {:ok, ip} = Treehouse.get_or_allocate("my-branch")
      # => {:ok, "127.0.0.10"}

  The IP is yours to use. Bind your server to it, configure mDNS, etc.
  """

  @doc """
  Allocates an IP for the given branch, or returns existing allocation.
  Updates last_seen_at timestamp on each call.

  Returns `{:ok, ip_string}` or `{:error, reason}`.
  """
  def get_or_allocate(branch) do
    Treehouse.Allocator.get_or_allocate(branch)
  end

  @doc """
  Releases the allocation for a branch.
  """
  def release(branch) do
    Treehouse.Allocator.release(branch)
  end

  @doc """
  Lists all current allocations.
  """
  def list do
    Treehouse.Registry.list_allocations(Treehouse.RegistryServer.get_conn())
  end

  @doc """
  Gets allocation info for a specific branch.
  """
  def info(branch) do
    Treehouse.Registry.find_by_branch(Treehouse.RegistryServer.get_conn(), branch)
  end
end
```

**Step 1.5: Run `mix deps.get`**

```bash
mix deps.get
```

**Step 1.6: Commit**

```bash
git add -A
git commit -m "feat: project skeleton with exqlite dep"
```

---

## Task 2: Treehouse.Git - Branch Detection

**Files:**
- Create: `lib/treehouse/git.ex`
- Create: `test/treehouse/git_test.exs`

**Step 2.1: Write failing test for current_branch**

```elixir
# test/treehouse/git_test.exs
defmodule Treehouse.GitTest do
  use ExUnit.Case, async: true

  describe "current_branch/0" do
    test "returns current git branch" do
      assert {:ok, branch} = Treehouse.Git.current_branch()
      assert is_binary(branch)
      assert String.length(branch) > 0
    end
  end

  describe "sanitize_for_hostname/1" do
    test "creates valid DNS label" do
      assert Treehouse.Git.sanitize_for_hostname("feature/auth-flow") == "feature-auth-flow"
      assert Treehouse.Git.sanitize_for_hostname("ijcd/my_branch!") == "ijcd-mybranch"
    end

    test "truncates to 63 chars" do
      long_branch = String.duplicate("a", 100)
      result = Treehouse.Git.sanitize_for_hostname(long_branch)
      assert String.length(result) == 63
    end

    test "removes leading/trailing hyphens" do
      assert Treehouse.Git.sanitize_for_hostname("-foo-") == "foo"
      assert Treehouse.Git.sanitize_for_hostname("--bar--") == "bar"
    end
  end
end
```

**Step 2.2: Run test to verify it fails**

```bash
mix test test/treehouse/git_test.exs
```
Expected: Compilation error, module not found

**Step 2.3: Implement Git module**

```elixir
# lib/treehouse/git.ex
defmodule Treehouse.Git do
  @moduledoc """
  Git operations for branch detection and name sanitization.
  """

  @doc """
  Returns the current git branch name.
  """
  def current_branch do
    case System.cmd("git", ["branch", "--show-current"], stderr_to_stdout: true) do
      {branch, 0} ->
        trimmed = String.trim(branch)
        if trimmed == "" do
          # Detached HEAD
          case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
            {sha, 0} -> {:ok, "detached-" <> String.trim(sha)}
            {error, _} -> {:error, error}
          end
        else
          {:ok, trimmed}
        end

      {error, _} ->
        {:error, error}
    end
  end

  @doc """
  Sanitizes branch name for use as DNS hostname.
  Creates valid DNS label (a-z, 0-9, hyphen, max 63 chars).
  """
  def sanitize_for_hostname(branch) do
    branch
    |> String.replace(~r|/|, "-")
    |> String.replace(~r/[^a-zA-Z0-9-]/, "")
    |> String.downcase()
    |> String.replace(~r/^-+|-+$/, "")  # Remove leading/trailing hyphens
    |> String.slice(0, 63)
  end
end
```

**Step 2.4: Run tests**

```bash
mix test test/treehouse/git_test.exs
```
Expected: All pass

**Step 2.5: Commit**

```bash
git add lib/treehouse/git.ex test/treehouse/git_test.exs
git commit -m "feat: git branch detection and sanitization"
```

---

## Task 3: Treehouse.Registry - SQLite Storage

**Files:**
- Create: `lib/treehouse/registry.ex`
- Create: `lib/treehouse/allocation.ex`
- Create: `test/treehouse/registry_test.exs`

**Step 3.1: Create Allocation struct**

```elixir
# lib/treehouse/allocation.ex
defmodule Treehouse.Allocation do
  @moduledoc """
  Represents an IP allocation for a branch.
  """

  defstruct [
    :id,
    :branch,
    :ip,
    :hostname,
    :project_path,
    :allocated_at,
    :last_seen_at
  ]

  @type t :: %__MODULE__{
    id: integer() | nil,
    branch: String.t(),
    ip: String.t(),
    hostname: String.t(),
    project_path: String.t() | nil,
    allocated_at: DateTime.t(),
    last_seen_at: DateTime.t()
  }
end
```

**Step 3.2: Write failing Registry tests**

```elixir
# test/treehouse/registry_test.exs
defmodule Treehouse.RegistryTest do
  use ExUnit.Case

  alias Treehouse.{Registry, Allocation}

  setup do
    path = Path.join(System.tmp_dir!(), "treehouse_test_#{:rand.uniform(1_000_000)}.db")
    {:ok, conn} = Registry.init_db(path)
    on_exit(fn -> File.rm(path) end)
    %{conn: conn, path: path}
  end

  describe "insert_allocation/2" do
    test "inserts new allocation", %{conn: conn} do
      allocation = %Allocation{
        branch: "main",
        ip: "127.0.0.10",
        hostname: "main",
        project_path: "/path/to/project",
        allocated_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      }

      assert :ok = Registry.insert_allocation(conn, allocation)
    end

    test "enforces unique branch", %{conn: conn} do
      allocation = %Allocation{
        branch: "main",
        ip: "127.0.0.10",
        hostname: "main",
        allocated_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      }

      assert :ok = Registry.insert_allocation(conn, allocation)
      assert {:error, _} = Registry.insert_allocation(conn, allocation)
    end
  end

  describe "find_by_branch/2" do
    test "returns allocation if exists", %{conn: conn} do
      allocation = %Allocation{
        branch: "feature",
        ip: "127.0.0.11",
        hostname: "feature",
        allocated_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      }

      Registry.insert_allocation(conn, allocation)

      assert {:ok, found} = Registry.find_by_branch(conn, "feature")
      assert found.branch == "feature"
      assert found.ip == "127.0.0.11"
    end

    test "returns :not_found if missing", %{conn: conn} do
      assert :not_found = Registry.find_by_branch(conn, "nonexistent")
    end
  end

  describe "next_available_ip/3" do
    test "returns first IP in range when empty", %{conn: conn} do
      assert {:ok, "127.0.0.10"} = Registry.next_available_ip(conn, 10, 99)
    end

    test "returns next IP when some allocated", %{conn: conn} do
      allocation = %Allocation{
        branch: "main",
        ip: "127.0.0.10",
        hostname: "main",
        allocated_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      }
      Registry.insert_allocation(conn, allocation)

      assert {:ok, "127.0.0.11"} = Registry.next_available_ip(conn, 10, 99)
    end

    test "fills gaps", %{conn: conn} do
      for ip <- ["127.0.0.10", "127.0.0.12"] do
        allocation = %Allocation{
          branch: "branch-#{ip}",
          ip: ip,
          hostname: "h",
          allocated_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now()
        }
        Registry.insert_allocation(conn, allocation)
      end

      assert {:ok, "127.0.0.11"} = Registry.next_available_ip(conn, 10, 99)
    end

    test "returns error when pool exhausted", %{conn: conn} do
      for i <- 10..12 do
        allocation = %Allocation{
          branch: "branch-#{i}",
          ip: "127.0.0.#{i}",
          hostname: "h",
          allocated_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now()
        }
        Registry.insert_allocation(conn, allocation)
      end

      assert {:error, :pool_exhausted} = Registry.next_available_ip(conn, 10, 12)
    end
  end

  describe "find_oldest_allocation/1" do
    test "returns oldest by last_seen_at", %{conn: conn} do
      old_time = DateTime.add(DateTime.utc_now(), -7, :day)
      new_time = DateTime.utc_now()

      old_alloc = %Allocation{
        branch: "old",
        ip: "127.0.0.10",
        hostname: "old",
        allocated_at: old_time,
        last_seen_at: old_time
      }
      new_alloc = %Allocation{
        branch: "new",
        ip: "127.0.0.11",
        hostname: "new",
        allocated_at: new_time,
        last_seen_at: new_time
      }

      Registry.insert_allocation(conn, new_alloc)
      Registry.insert_allocation(conn, old_alloc)

      assert {:ok, oldest} = Registry.find_oldest_allocation(conn)
      assert oldest.branch == "old"
    end

    test "returns :not_found when empty", %{conn: conn} do
      assert :not_found = Registry.find_oldest_allocation(conn)
    end
  end

  describe "delete_allocation/2" do
    test "removes allocation", %{conn: conn} do
      allocation = %Allocation{
        branch: "to-delete",
        ip: "127.0.0.10",
        hostname: "td",
        allocated_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      }
      Registry.insert_allocation(conn, allocation)

      assert :ok = Registry.delete_allocation(conn, "to-delete")
      assert :not_found = Registry.find_by_branch(conn, "to-delete")
    end
  end

  describe "update_last_seen/2" do
    test "updates timestamp", %{conn: conn} do
      old_time = DateTime.add(DateTime.utc_now(), -1, :hour)
      allocation = %Allocation{
        branch: "test",
        ip: "127.0.0.10",
        hostname: "test",
        allocated_at: old_time,
        last_seen_at: old_time
      }
      Registry.insert_allocation(conn, allocation)

      :ok = Registry.update_last_seen(conn, "test")

      {:ok, updated} = Registry.find_by_branch(conn, "test")
      assert DateTime.compare(updated.last_seen_at, old_time) == :gt
    end
  end
end
```

**Step 3.3: Run tests to verify failure**

```bash
mix test test/treehouse/registry_test.exs
```
Expected: Compilation error

**Step 3.4: Implement Registry module**

```elixir
# lib/treehouse/registry.ex
defmodule Treehouse.Registry do
  @moduledoc """
  SQLite-based storage for IP allocations.
  """

  alias Treehouse.Allocation

  @create_table """
  CREATE TABLE IF NOT EXISTS allocations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    branch TEXT UNIQUE NOT NULL,
    ip TEXT UNIQUE NOT NULL,
    hostname TEXT NOT NULL,
    project_path TEXT,
    allocated_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
  )
  """

  @create_indexes [
    "CREATE INDEX IF NOT EXISTS idx_allocations_branch ON allocations(branch)",
    "CREATE INDEX IF NOT EXISTS idx_allocations_ip ON allocations(ip)",
    "CREATE INDEX IF NOT EXISTS idx_allocations_last_seen ON allocations(last_seen_at)"
  ]

  @doc """
  Initializes the database at the given path.
  """
  def init_db(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    :ok = Exqlite.Sqlite3.execute(conn, @create_table)
    for sql <- @create_indexes, do: :ok = Exqlite.Sqlite3.execute(conn, sql)

    {:ok, conn}
  end

  @doc """
  Inserts a new allocation.
  """
  def insert_allocation(conn, %Allocation{} = alloc) do
    sql = """
    INSERT INTO allocations (branch, ip, hostname, project_path, allocated_at, last_seen_at)
    VALUES (?, ?, ?, ?, ?, ?)
    """

    with {:ok, stmt} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(conn, stmt, [
           alloc.branch,
           alloc.ip,
           alloc.hostname,
           alloc.project_path,
           DateTime.to_iso8601(alloc.allocated_at),
           DateTime.to_iso8601(alloc.last_seen_at)
         ]),
         :done <- Exqlite.Sqlite3.step(conn, stmt) do
      Exqlite.Sqlite3.release(conn, stmt)
      :ok
    else
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  end

  @doc """
  Finds an allocation by branch name.
  """
  def find_by_branch(conn, branch) do
    sql = "SELECT * FROM allocations WHERE branch = ?"

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(conn, stmt, [branch])

    result = case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> {:ok, row_to_allocation(row)}
      :done -> :not_found
    end

    Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  @doc """
  Lists all allocations.
  """
  def list_allocations(conn) do
    sql = "SELECT * FROM allocations ORDER BY last_seen_at DESC"
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    allocations = fetch_all_rows(conn, stmt, [])
    Exqlite.Sqlite3.release(conn, stmt)
    allocations
  end

  @doc """
  Finds the next available IP in the range.
  """
  def next_available_ip(conn, range_start, range_end) do
    sql = "SELECT ip FROM allocations"
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    used_ips = fetch_used_ips(conn, stmt, MapSet.new())
    Exqlite.Sqlite3.release(conn, stmt)

    result = Enum.find_value(range_start..range_end, fn i ->
      ip = "127.0.0.#{i}"
      if MapSet.member?(used_ips, ip), do: nil, else: {:ok, ip}
    end)

    result || {:error, :pool_exhausted}
  end

  @doc """
  Finds the oldest allocation by last_seen_at.
  Used for lazy reclamation when pool is exhausted.
  """
  def find_oldest_allocation(conn) do
    sql = "SELECT * FROM allocations ORDER BY last_seen_at ASC LIMIT 1"
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    result = case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> {:ok, row_to_allocation(row)}
      :done -> :not_found
    end

    Exqlite.Sqlite3.release(conn, stmt)
    result
  end

  @doc """
  Updates the last_seen_at timestamp for a branch.
  """
  def update_last_seen(conn, branch) do
    sql = "UPDATE allocations SET last_seen_at = ? WHERE branch = ?"
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(conn, stmt, [DateTime.to_iso8601(DateTime.utc_now()), branch])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end

  @doc """
  Deletes an allocation by branch.
  """
  def delete_allocation(conn, branch) do
    sql = "DELETE FROM allocations WHERE branch = ?"
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
    :ok = Exqlite.Sqlite3.bind(conn, stmt, [branch])
    :done = Exqlite.Sqlite3.step(conn, stmt)
    Exqlite.Sqlite3.release(conn, stmt)
    :ok
  end

  # Private helpers

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all_rows(conn, stmt, [row_to_allocation(row) | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp fetch_used_ips(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      {:row, [ip]} -> fetch_used_ips(conn, stmt, MapSet.put(acc, ip))
      :done -> acc
    end
  end

  defp row_to_allocation([id, branch, ip, hostname, project_path, allocated_at, last_seen_at]) do
    %Allocation{
      id: id,
      branch: branch,
      ip: ip,
      hostname: hostname,
      project_path: project_path,
      allocated_at: parse_datetime(allocated_at),
      last_seen_at: parse_datetime(last_seen_at)
    }
  end

  defp parse_datetime(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    dt
  end
end
```

**Step 3.5: Run tests**

```bash
mix test test/treehouse/registry_test.exs
```
Expected: All pass

**Step 3.6: Commit**

```bash
git add lib/treehouse/allocation.ex lib/treehouse/registry.ex test/treehouse/registry_test.exs
git commit -m "feat: SQLite registry for IP allocations"
```

---

## Task 4: Treehouse.Allocator - GenServer with Lazy Reclaim

**Files:**
- Create: `lib/treehouse/allocator.ex`
- Create: `test/treehouse/allocator_test.exs`

**Step 4.1: Write failing Allocator tests**

```elixir
# test/treehouse/allocator_test.exs
defmodule Treehouse.AllocatorTest do
  use ExUnit.Case

  alias Treehouse.{Allocator, Registry, Allocation}

  setup do
    path = Path.join(System.tmp_dir!(), "treehouse_alloc_test_#{:rand.uniform(1_000_000)}.db")
    {:ok, conn} = Registry.init_db(path)
    {:ok, pid} = Allocator.start_link(conn: conn, ip_range: {10, 12}, stale_days: 7)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(path)
    end)

    %{allocator: pid, conn: conn}
  end

  describe "get_or_allocate/2" do
    test "allocates new IP for unknown branch", %{allocator: pid} do
      assert {:ok, ip} = Allocator.get_or_allocate(pid, "new-branch")
      assert ip == "127.0.0.10"
    end

    test "returns existing IP for known branch", %{allocator: pid} do
      {:ok, first} = Allocator.get_or_allocate(pid, "same-branch")
      {:ok, second} = Allocator.get_or_allocate(pid, "same-branch")
      assert first == second
    end

    test "allocates sequential IPs", %{allocator: pid} do
      {:ok, ip1} = Allocator.get_or_allocate(pid, "branch-1")
      {:ok, ip2} = Allocator.get_or_allocate(pid, "branch-2")
      {:ok, ip3} = Allocator.get_or_allocate(pid, "branch-3")

      assert ip1 == "127.0.0.10"
      assert ip2 == "127.0.0.11"
      assert ip3 == "127.0.0.12"
    end
  end

  describe "lazy reclamation" do
    test "reclaims oldest when pool exhausted", %{conn: conn} do
      # Insert old allocation directly
      old_time = DateTime.add(DateTime.utc_now(), -8, :day)
      old_alloc = %Allocation{
        branch: "old-branch",
        ip: "127.0.0.10",
        hostname: "old",
        allocated_at: old_time,
        last_seen_at: old_time
      }
      Registry.insert_allocation(conn, old_alloc)

      # Start new allocator with this data
      {:ok, pid} = Allocator.start_link(conn: conn, ip_range: {10, 10}, stale_days: 7)

      # Should reclaim the old one
      assert {:ok, "127.0.0.10"} = Allocator.get_or_allocate(pid, "new-branch")

      # Old branch should be gone
      assert :not_found = Registry.find_by_branch(conn, "old-branch")

      GenServer.stop(pid)
    end

    test "fails if oldest is too recent", %{conn: conn} do
      # Insert recent allocation
      recent = %Allocation{
        branch: "recent",
        ip: "127.0.0.10",
        hostname: "recent",
        allocated_at: DateTime.utc_now(),
        last_seen_at: DateTime.utc_now()
      }
      Registry.insert_allocation(conn, recent)

      {:ok, pid} = Allocator.start_link(conn: conn, ip_range: {10, 10}, stale_days: 7)

      # Should fail - can't reclaim recent allocation
      assert {:error, :no_available_ips} = Allocator.get_or_allocate(pid, "new-branch")

      GenServer.stop(pid)
    end
  end

  describe "release/2" do
    test "releases allocation", %{allocator: pid} do
      {:ok, _} = Allocator.get_or_allocate(pid, "to-release")
      assert :ok = Allocator.release(pid, "to-release")

      # Should get same IP again
      {:ok, ip} = Allocator.get_or_allocate(pid, "reuse")
      assert ip == "127.0.0.10"
    end
  end
end
```

**Step 4.2: Run tests to verify failure**

```bash
mix test test/treehouse/allocator_test.exs
```
Expected: Compilation error

**Step 4.3: Implement Allocator with lazy reclamation**

```elixir
# lib/treehouse/allocator.ex
defmodule Treehouse.Allocator do
  @moduledoc """
  GenServer that manages IP allocations.

  Serializes allocation requests to prevent race conditions.
  Implements lazy reclamation: when pool is exhausted, reclaims
  the oldest allocation if it's older than stale_days.
  """

  use GenServer

  alias Treehouse.{Registry, Allocation, Git}

  defstruct [:conn, :ip_range, :stale_days]

  # Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets or allocates an IP for the branch.
  Returns `{:ok, ip_string}` or `{:error, reason}`.
  """
  def get_or_allocate(server \\ __MODULE__, branch, opts \\ []) do
    GenServer.call(server, {:get_or_allocate, branch, opts})
  end

  @doc """
  Releases the allocation for a branch.
  """
  def release(server \\ __MODULE__, branch) do
    GenServer.call(server, {:release, branch})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    conn = case Keyword.get(opts, :conn) do
      nil ->
        conn_fn = Keyword.fetch!(opts, :conn_fn)
        conn_fn.()
      conn ->
        conn
    end

    {range_start, range_end} = Keyword.get(opts, :ip_range, {10, 99})
    stale_days = Keyword.get(opts, :stale_days, 7)

    state = %__MODULE__{
      conn: conn,
      ip_range: {range_start, range_end},
      stale_days: stale_days
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:get_or_allocate, branch, opts}, _from, state) do
    result = case Registry.find_by_branch(state.conn, branch) do
      {:ok, allocation} ->
        Registry.update_last_seen(state.conn, branch)
        {:ok, allocation.ip}

      :not_found ->
        allocate_new(state, branch, opts)
    end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:release, branch}, _from, state) do
    result = Registry.delete_allocation(state.conn, branch)
    {:reply, result, state}
  end

  defp allocate_new(state, branch, opts) do
    {range_start, range_end} = state.ip_range

    case Registry.next_available_ip(state.conn, range_start, range_end) do
      {:ok, ip} ->
        create_allocation(state, branch, ip, opts)

      {:error, :pool_exhausted} ->
        # Try lazy reclamation
        try_reclaim_and_allocate(state, branch, opts)
    end
  end

  defp try_reclaim_and_allocate(state, branch, opts) do
    case Registry.find_oldest_allocation(state.conn) do
      {:ok, oldest} ->
        cutoff = DateTime.add(DateTime.utc_now(), -state.stale_days, :day)

        if DateTime.compare(oldest.last_seen_at, cutoff) == :lt do
          # Old enough to reclaim
          Registry.delete_allocation(state.conn, oldest.branch)
          create_allocation(state, branch, oldest.ip, opts)
        else
          {:error, :no_available_ips}
        end

      :not_found ->
        {:error, :no_available_ips}
    end
  end

  defp create_allocation(state, branch, ip, opts) do
    hostname = Git.sanitize_for_hostname(branch)
    project_path = Keyword.get(opts, :project_path, File.cwd!())
    now = DateTime.utc_now()

    allocation = %Allocation{
      branch: branch,
      ip: ip,
      hostname: hostname,
      project_path: project_path,
      allocated_at: now,
      last_seen_at: now
    }

    case Registry.insert_allocation(state.conn, allocation) do
      :ok -> {:ok, ip}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

**Step 4.4: Run tests**

```bash
mix test test/treehouse/allocator_test.exs
```
Expected: All pass

**Step 4.5: Commit**

```bash
git add lib/treehouse/allocator.ex test/treehouse/allocator_test.exs
git commit -m "feat: allocator with lazy reclamation"
```

---

## Task 5: Treehouse.Mdns - dns-sd Wrapper

**Files:**
- Create: `lib/treehouse/mdns.ex`
- Create: `test/treehouse/mdns_test.exs`

**Step 5.1: Write Mdns tests**

```elixir
# test/treehouse/mdns_test.exs
defmodule Treehouse.MdnsTest do
  use ExUnit.Case

  alias Treehouse.Mdns

  describe "build_args/3" do
    test "builds correct dns-sd arguments" do
      args = Mdns.build_args("my-app", "127.0.0.10", 4000)

      assert args == [
        "-P",
        "my-app",
        "_http._tcp",
        "local",
        "4000",
        "my-app.local",
        "127.0.0.10"
      ]
    end
  end

  describe "start_link/1" do
    @tag :integration
    test "starts dns-sd process" do
      if System.find_executable("dns-sd") do
        {:ok, pid} = Mdns.start_link(
          hostname: "test-mdns-#{:rand.uniform(1000)}",
          ip: "127.0.0.99",
          port: 4000
        )

        assert Process.alive?(pid)
        GenServer.stop(pid)
      end
    end
  end
end
```

**Step 5.2: Run tests to verify failure**

```bash
mix test test/treehouse/mdns_test.exs
```

**Step 5.3: Implement Mdns**

```elixir
# lib/treehouse/mdns.ex
defmodule Treehouse.Mdns do
  @moduledoc """
  Announces services via mDNS using macOS dns-sd command.

  Wraps `dns-sd -P` to register a service that resolves
  hostname.local to the given IP.
  """

  use GenServer
  require Logger

  defstruct [:port_ref, :hostname, :ip, :service_port]

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def stop(server) do
    GenServer.stop(server)
  end

  @doc """
  Builds dns-sd -P arguments for service registration.
  """
  def build_args(hostname, ip, port) do
    [
      "-P",
      hostname,
      "_http._tcp",
      "local",
      to_string(port),
      "#{hostname}.local",
      ip
    ]
  end

  @impl true
  def init(opts) do
    hostname = Keyword.fetch!(opts, :hostname)
    ip = Keyword.fetch!(opts, :ip)
    port = Keyword.get(opts, :port, 4000)

    case start_dns_sd(hostname, ip, port) do
      {:ok, port_ref} ->
        Logger.info("[Treehouse] mDNS: #{hostname}.local -> #{ip}:#{port}")
        {:ok, %__MODULE__{port_ref: port_ref, hostname: hostname, ip: ip, service_port: port}}

      {:error, reason} ->
        Logger.warning("[Treehouse] mDNS unavailable: #{inspect(reason)}")
        {:ok, %__MODULE__{hostname: hostname, ip: ip, service_port: port}}
    end
  end

  @impl true
  def handle_info({port_ref, {:data, data}}, %{port_ref: port_ref} = state) do
    Logger.debug("[Treehouse.Mdns] #{data}")
    {:noreply, state}
  end

  def handle_info({port_ref, {:exit_status, status}}, %{port_ref: port_ref} = state) do
    Logger.warning("[Treehouse.Mdns] dns-sd exited with status #{status}")
    {:noreply, %{state | port_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port_ref: port_ref}) when is_port(port_ref) do
    case :erlang.port_info(port_ref, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", [to_string(os_pid)], stderr_to_stdout: true)
      _ ->
        :ok
    end
  end
  def terminate(_, _), do: :ok

  defp start_dns_sd(hostname, ip, port) do
    dns_sd = System.find_executable("dns-sd") || "/usr/bin/dns-sd"

    if File.exists?(dns_sd) do
      args = build_args(hostname, ip, port)
      try do
        port_ref = Port.open({:spawn_executable, dns_sd}, [:binary, :exit_status, args: args])
        {:ok, port_ref}
      rescue
        e -> {:error, Exception.message(e)}
      end
    else
      {:error, :dns_sd_not_found}
    end
  end
end
```

**Step 5.4: Run tests**

```bash
mix test test/treehouse/mdns_test.exs
```

**Step 5.5: Commit**

```bash
git add lib/treehouse/mdns.ex test/treehouse/mdns_test.exs
git commit -m "feat: mDNS announcer via dns-sd"
```

---

## Task 6: Treehouse.Phoenix - Optional Helper

**Files:**
- Create: `lib/treehouse/phoenix.ex`
- Create: `test/treehouse/phoenix_test.exs`

**Step 6.1: Write Phoenix tests**

```elixir
# test/treehouse/phoenix_test.exs
defmodule Treehouse.PhoenixTest do
  use ExUnit.Case

  alias Treehouse.Phoenix, as: TreehousePhoenix

  describe "parse_ip/1" do
    test "parses IP string to tuple" do
      assert TreehousePhoenix.parse_ip("127.0.0.10") == {127, 0, 0, 10}
      assert TreehousePhoenix.parse_ip("192.168.1.1") == {192, 168, 1, 1}
    end
  end
end
```

**Step 6.2: Run tests to verify failure**

```bash
mix test test/treehouse/phoenix_test.exs
```

**Step 6.3: Implement Phoenix helper**

```elixir
# lib/treehouse/phoenix.ex
defmodule Treehouse.Phoenix do
  @moduledoc """
  Optional Phoenix integration helper.

  Provides convenience functions for configuring Phoenix endpoints
  with Treehouse-allocated IPs. This is a helper, not required.

  ## Usage

  In `config/runtime.exs`:

      if config_env() == :dev do
        {:ok, ip} = Treehouse.get_or_allocate(branch)
        Treehouse.Phoenix.configure_endpoint!(:my_app, MyAppWeb.Endpoint, ip)
      end

  """

  require Logger

  @doc """
  Configures a Phoenix endpoint to bind to the given IP.

  Options:
  - `:port` - port to bind (default: 4000)
  - `:domain` - mDNS domain (default: "local")
  """
  def configure_endpoint!(app, endpoint, ip, opts \\ []) do
    port = Keyword.get(opts, :port, 4000)
    domain = Keyword.get(opts, :domain, "local")
    hostname = Keyword.get(opts, :hostname, infer_hostname())

    ip_tuple = parse_ip(ip)

    existing = Application.get_env(app, endpoint, [])
    new_config = Keyword.merge(existing,
      http: [ip: ip_tuple, port: port],
      url: [host: "#{hostname}.#{domain}", port: port],
      check_origin: false
    )

    Application.put_env(app, endpoint, new_config)

    Logger.info("[Treehouse] Endpoint configured: #{ip}:#{port} (#{hostname}.#{domain})")
    :ok
  end

  @doc """
  Parses an IP string into a tuple.
  """
  def parse_ip(ip_string) do
    ip_string
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  defp infer_hostname do
    case Treehouse.Git.current_branch() do
      {:ok, branch} -> Treehouse.Git.sanitize_for_hostname(branch)
      _ -> "dev"
    end
  end
end
```

**Step 6.4: Run tests**

```bash
mix test test/treehouse/phoenix_test.exs
```

**Step 6.5: Commit**

```bash
git add lib/treehouse/phoenix.ex test/treehouse/phoenix_test.exs
git commit -m "feat: optional Phoenix endpoint helper"
```

---

## Task 7: Treehouse.Application - Supervision Tree

**Files:**
- Create: `lib/treehouse/registry_server.ex`
- Modify: `lib/treehouse/application.ex`

**Step 7.1: Create RegistryServer**

```elixir
# lib/treehouse/registry_server.ex
defmodule Treehouse.RegistryServer do
  @moduledoc """
  Manages the SQLite connection for the registry.
  """

  use GenServer

  alias Treehouse.Registry

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def get_conn(server \\ __MODULE__) do
    GenServer.call(server, :get_conn)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || default_path()
    {:ok, conn} = Registry.init_db(path)
    {:ok, %{conn: conn, path: path}}
  end

  @impl true
  def handle_call(:get_conn, _from, state) do
    {:reply, state.conn, state}
  end

  defp default_path do
    path = Application.get_env(:treehouse, :registry_path, "~/.local/share/treehouse/registry.db")
    Path.expand(path)
  end
end
```

**Step 7.2: Update Application**

```elixir
# lib/treehouse/application.ex
defmodule Treehouse.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Treehouse.RegistryServer,
      {Treehouse.Allocator, allocator_opts()}
    ]

    opts = [strategy: :one_for_one, name: Treehouse.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp allocator_opts do
    [
      conn_fn: fn -> Treehouse.RegistryServer.get_conn() end,
      ip_range: {
        Application.get_env(:treehouse, :ip_range_start, 10),
        Application.get_env(:treehouse, :ip_range_end, 99)
      },
      stale_days: Application.get_env(:treehouse, :stale_threshold_days, 7)
    ]
  end
end
```

**Step 7.3: Run all tests**

```bash
mix test
```

**Step 7.4: Commit**

```bash
git add lib/treehouse/registry_server.ex lib/treehouse/application.ex
git commit -m "feat: supervision tree"
```

---

## Task 8: Mix Tasks

**Files:**
- Create: `lib/mix/tasks/treehouse.list.ex`
- Create: `lib/mix/tasks/treehouse.info.ex`
- Create: `lib/mix/tasks/treehouse.release.ex`

**Step 8.1: Create mix treehouse.list**

```elixir
# lib/mix/tasks/treehouse.list.ex
defmodule Mix.Tasks.Treehouse.List do
  @shortdoc "Lists all IP allocations"
  @moduledoc "Lists all current IP allocations."

  use Mix.Task

  alias Treehouse.Registry

  @impl true
  def run(_args) do
    path = Application.get_env(:treehouse, :registry_path, "~/.local/share/treehouse/registry.db")
           |> Path.expand()

    if File.exists?(path) do
      {:ok, conn} = Registry.init_db(path)
      allocations = Registry.list_allocations(conn)

      if Enum.empty?(allocations) do
        Mix.shell().info("No allocations found.")
      else
        Mix.shell().info("BRANCH                          IP              LAST SEEN")
        Mix.shell().info(String.duplicate("─", 70))

        for alloc <- allocations do
          branch = String.pad_trailing(alloc.branch, 30)
          ip = String.pad_trailing(alloc.ip, 15)
          last_seen = Calendar.strftime(alloc.last_seen_at, "%Y-%m-%d %H:%M")
          Mix.shell().info("#{branch} #{ip} #{last_seen}")
        end
      end
    else
      Mix.shell().info("No registry found.")
    end
  end
end
```

**Step 8.2: Create mix treehouse.info**

```elixir
# lib/mix/tasks/treehouse.info.ex
defmodule Mix.Tasks.Treehouse.Info do
  @shortdoc "Shows info for a branch"
  @moduledoc "Shows allocation info for a branch."

  use Mix.Task

  alias Treehouse.{Registry, Git}

  @impl true
  def run(args) do
    branch = case args do
      [branch] -> branch
      [] ->
        case Git.current_branch() do
          {:ok, branch} -> branch
          {:error, _} -> Mix.raise("Not in a git repo and no branch specified")
        end
    end

    path = Application.get_env(:treehouse, :registry_path, "~/.local/share/treehouse/registry.db")
           |> Path.expand()

    if File.exists?(path) do
      {:ok, conn} = Registry.init_db(path)

      case Registry.find_by_branch(conn, branch) do
        {:ok, alloc} ->
          Mix.shell().info("""
          Branch:     #{alloc.branch}
          IP:         #{alloc.ip}
          Hostname:   #{alloc.hostname}.local
          Project:    #{alloc.project_path || "N/A"}
          Allocated:  #{alloc.allocated_at}
          Last seen:  #{alloc.last_seen_at}
          """)

        :not_found ->
          Mix.shell().info("No allocation for: #{branch}")
      end
    else
      Mix.shell().info("No registry found.")
    end
  end
end
```

**Step 8.3: Create mix treehouse.release**

```elixir
# lib/mix/tasks/treehouse.release.ex
defmodule Mix.Tasks.Treehouse.Release do
  @shortdoc "Releases an IP allocation"
  @moduledoc "Releases the IP allocation for a branch."

  use Mix.Task

  alias Treehouse.Registry

  @impl true
  def run(args) do
    branch = case args do
      [branch] -> branch
      [] -> Mix.raise("Usage: mix treehouse.release <branch>")
    end

    path = Application.get_env(:treehouse, :registry_path, "~/.local/share/treehouse/registry.db")
           |> Path.expand()

    if File.exists?(path) do
      {:ok, conn} = Registry.init_db(path)
      Registry.delete_allocation(conn, branch)
      Mix.shell().info("Released: #{branch}")
    else
      Mix.shell().info("No registry found.")
    end
  end
end
```

**Step 8.4: Commit**

```bash
git add lib/mix/tasks/
git commit -m "feat: mix tasks for list, info, release"
```

---

## Task 9: Integration Tests

**Files:**
- Create: `test/treehouse_integration_test.exs`

**Step 9.1: Create integration test**

```elixir
# test/treehouse_integration_test.exs
defmodule TreehouseIntegrationTest do
  use ExUnit.Case

  @tag :integration
  test "full allocation flow" do
    # This tests the public API through the running application
    branch = "test-branch-#{:rand.uniform(10000)}"

    # Allocate
    assert {:ok, ip} = Treehouse.get_or_allocate(branch)
    assert String.starts_with?(ip, "127.0.0.")

    # Get same IP again
    assert {:ok, ^ip} = Treehouse.get_or_allocate(branch)

    # Info
    assert {:ok, alloc} = Treehouse.info(branch)
    assert alloc.ip == ip

    # List
    allocations = Treehouse.list()
    assert Enum.any?(allocations, &(&1.branch == branch))

    # Release
    assert :ok = Treehouse.release(branch)
    assert :not_found = Treehouse.info(branch)
  end
end
```

**Step 9.2: Commit**

```bash
git add test/treehouse_integration_test.exs
git commit -m "feat: integration tests"
```

---

## Task 10: Documentation

**Files:**
- Create: `README.md`

**Step 10.1: Write README**

```markdown
# Treehouse

Local development IP manager. Allocates unique IPs from `127.0.0.10-99` per git branch.

## Installation

```elixir
def deps do
  [{:treehouse, "~> 0.1", only: :dev}]
end
```

## Prerequisites

Loopback aliases must exist. On macOS with nix-darwin:

```nix
networking.aliases = builtins.map (n: "127.0.0.${toString n}") (lib.range 10 99);
```

Or manually:

```bash
for i in $(seq 10 99); do sudo ifconfig lo0 alias 127.0.0.$i; done
```

## Usage

```elixir
# Get an IP for your branch
{:ok, ip} = Treehouse.get_or_allocate("my-feature")
# => {:ok, "127.0.0.10"}

# Use it however you want
# Phoenix, Rails, Node, Go - doesn't matter
```

### With Phoenix

```elixir
# config/runtime.exs
if config_env() == :dev do
  {:ok, branch} = Treehouse.Git.current_branch()
  {:ok, ip} = Treehouse.get_or_allocate(branch)
  Treehouse.Phoenix.configure_endpoint!(:my_app, MyAppWeb.Endpoint, ip)
end
```

### With mDNS

```elixir
# Start mDNS announcer
{:ok, _} = Treehouse.Mdns.start_link(hostname: "my-app", ip: ip, port: 4000)
# Now http://my-app.local:4000 works
```

## Mix Tasks

```bash
mix treehouse.list              # List all allocations
mix treehouse.info [branch]     # Show info for branch
mix treehouse.release <branch>  # Release an allocation
```

## How It Works

- Allocations stored in `~/.local/share/treehouse/registry.db` (SQLite)
- Each call to `get_or_allocate` updates `last_seen_at`
- When pool exhausted, oldest allocation (>7 days stale) is reclaimed
- Multiple apps/VMs share the same registry file

## License

MIT
```

**Step 10.2: Commit**

```bash
git add README.md
git commit -m "docs: README"
```

---

## Summary

| Component | Purpose |
|-----------|---------|
| Treehouse | Public API: get_or_allocate, release, list, info |
| Treehouse.Registry | SQLite storage |
| Treehouse.Allocator | GenServer with lazy reclamation |
| Treehouse.Mdns | dns-sd wrapper |
| Treehouse.Phoenix | Optional endpoint helper |
| Mix tasks | CLI debugging |

**Key simplifications from original plan:**
- Removed port from schema (caller's concern)
- Lazy reclamation only (no proactive cleanup)
- Timestamp-based staleness (no PID tracking)
- 7-day default stale threshold

---

## Future Work (Plan 002)

- Publish to Hex.pm
- Write blog post explaining the problem and solution
- Announce in Elixir community:
  - Elixir Forum
  - ElixirStatus
  - Reddit r/elixir
  - Twitter/X #elixirlang
  - Elixir Slack

## Future Work (Plan 003)

- Setuid helper binary for privileged operations:
  - Create loopback aliases (`ifconfig lo0 alias 127.0.0.x`)
  - Manage PF hairpin NAT rules
  - Small Go/Rust binary, installed once with `sudo`
  - Treehouse calls helper via `System.cmd/3`
  - Removes nix-darwin prereq for casual users
- Service coordination (postgres, redis per-branch)
- Go/Rust daemon option (Option B from original spec)
