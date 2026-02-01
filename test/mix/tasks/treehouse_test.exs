defmodule Mix.Tasks.TreehouseTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Hammox
  import Treehouse.TestFixtures

  setup :verify_on_exit!

  setup do
    on_exit(&cleanup_adapter_env/0)
    setup_named_allocator(prefix: "treehouse_mix_test")
  end

  # Helper to stub config defaults for mock tests
  defp stub_config_defaults do
    Hammox.stub(Treehouse.MockRegistry, :get_config, fn
      "ip_range_start" -> {:ok, "10"}
      "ip_range_end" -> {:ok, "99"}
      _key -> {:ok, nil}
    end)
  end

  describe "mix treehouse" do
    test "shows help" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.run([])
        end)

      assert output =~ "Commands for managing Treehouse IP allocations"
      assert output =~ "mix treehouse.list"
    end
  end

  describe "mix treehouse.list" do
    test "shows no allocations when empty" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.List.run([])
        end)

      assert output =~ "No allocations"
    end

    test "shows allocations" do
      {:ok, _} = Treehouse.allocate("test-branch")

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.List.run([])
        end)

      assert output =~ "BRANCH"
      assert output =~ "test-branch"
      assert output =~ "127.0.0."
    end

    test "truncates long branch names" do
      # Create allocation with a very long branch name
      {:ok, _} =
        Treehouse.allocate("this-is-a-very-long-branch-name-that-exceeds-twenty-characters")

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.List.run([])
        end)

      # Should be truncated to 20 chars with ".." at end (18 + 2)
      assert output =~ "this-is-a-very-lon.."
      # The hostname column still shows full name
      assert output =~ ".treehouse.local"
    end
  end

  describe "mix treehouse.info" do
    test "shows no allocation for unknown branch" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Info.run(["unknown-branch"])
        end)

      assert output =~ "No allocation for treehouse:unknown-branch"
    end

    test "shows allocation info for known branch" do
      {:ok, _} = Treehouse.allocate("info-test")

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Info.run(["info-test"])
        end)

      assert output =~ "Project:    treehouse"
      assert output =~ "Branch:     info-test"
      assert output =~ "Hostname:   info-test.treehouse.local"
      assert output =~ "IP:         127.0.0."
      assert output =~ "Allocated:"
      assert output =~ "Last seen:"
    end

    test "uses current branch when no arg given" do
      # This will use real git, which should work in repo
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Info.run([])
        end)

      # Should either find allocation or report none - either is valid
      assert output =~ "allocation" or output =~ "Branch:"
    end
  end

  describe "mix treehouse.release" do
    test "releases allocation" do
      {:ok, _} = Treehouse.allocate("release-test")

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Release.run(["release-test"])
        end)

      assert output =~ "Released allocation for: treehouse:release-test"

      # Verify it's gone
      {:ok, nil} = Treehouse.info("release-test")
    end

    test "releases non-existent branch is ok" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Release.run(["nonexistent"])
        end)

      assert output =~ "Released allocation for: treehouse:nonexistent"
    end

    test "uses current branch when no arg given" do
      # This tests the {:ok, branch} -> branch path in get_current_branch
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Release.run([])
        end)

      # Should release (whether allocation existed or not)
      assert output =~ "Released allocation for:"
    end
  end

  describe "mix treehouse.allocate" do
    test "allocates IP for specified branch" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Allocate.run(["allocate-test"])
        end)

      assert output =~ "Allocated IP for treehouse:allocate-test"
      assert output =~ "IP:"
      assert output =~ "127.0.0."
      assert output =~ "Hostname:"
    end

    test "allocates IP for current branch when no arg given" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Allocate.run([])
        end)

      # Should allocate for whatever current branch is
      assert output =~ "Allocated IP for treehouse:"
      assert output =~ "IP:"
    end

    test "returns same IP for same branch" do
      {:ok, ip1} = Treehouse.allocate("same-branch-test")

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Allocate.run(["same-branch-test"])
        end)

      assert output =~ ip1
    end

    test "shows error when no loopback aliases available" do
      Hammox.set_mox_global()

      # Mock loopback to return empty IPs, triggering no_loopback_aliases error
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      # Need to restart allocator with mock to pick up empty pool
      GenServer.stop(Treehouse.Allocator)
      db = Treehouse.TestFixtures.temp_db_path("treehouse_no_loopback_test")
      {:ok, pid} = Treehouse.Allocator.start_link(db_path: db, name: Treehouse.Allocator)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Application.delete_env(:treehouse, :loopback_adapter)
        File.rm(db)
      end)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            Mix.Tasks.Treehouse.Allocate.run(["no-loopback-branch"])
          end)
        end)

      assert stderr =~ "No loopback aliases configured"
    end

    test "shows error when pool exhausted" do
      import ExUnit.CaptureLog

      Hammox.set_mox_global()

      # Mock loopback to return only 2 IPs
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [10, 11] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      # Need to restart allocator with mock and tiny pool
      GenServer.stop(Treehouse.Allocator)
      db = Treehouse.TestFixtures.temp_db_path("treehouse_exhausted_test")

      {:ok, pid} =
        Treehouse.Allocator.start_link(
          db_path: db,
          name: Treehouse.Allocator,
          stale_threshold_days: 365
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Application.delete_env(:treehouse, :loopback_adapter)
        File.rm(db)
      end)

      # Exhaust the pool
      {:ok, _} = Treehouse.allocate("branch1")
      {:ok, _} = Treehouse.allocate("branch2")

      # Third allocation should fail
      stderr =
        capture_log(fn ->
          capture_io(:stderr, fn ->
            capture_io(fn ->
              Mix.Tasks.Treehouse.Allocate.run(["branch3"])
            end)
          end)
        end)

      assert stderr =~ "pool exhausted"
    end
  end

  describe "mix treehouse.doctor" do
    test "shows loopback aliases section" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run([])
        end)

      assert output =~ "=== Loopback Aliases ==="
      # Either shows OK or NOT CONFIGURED
      assert output =~ "Status:"
    end

    test "shows registry section" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run([])
        end)

      assert output =~ "=== Registry ==="
      assert output =~ "Path:"
    end

    test "shows allocations section" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run([])
        end)

      assert output =~ "=== Current Allocations ==="
    end

    test "shows allocations when present" do
      {:ok, _} = Treehouse.allocate("doctor-test")

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run([])
        end)

      assert output =~ "doctor-test"
      assert output =~ "127.0.0."
    end

    test "shows NOT CONFIGURED when no loopback aliases" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [] end)
      Hammox.stub(Treehouse.MockLoopback, :setup_script, fn _start, _end -> "mock script" end)

      Hammox.stub(Treehouse.MockLoopback, :setup_commands, fn _start, _end ->
        ["cmd1", "cmd2", "cmd3"]
      end)

      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run([])
        end)

      assert output =~ "NOT CONFIGURED"
      assert output =~ "No loopback aliases found"
      assert output =~ "mock script"
    end

    test "shows individual IPs when 10 or fewer" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [10, 11, 12] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run([])
        end)

      assert output =~ "IPs: 127.0.0.10, 127.0.0.11, 127.0.0.12"
    end

    test "shows error when registry fails" do
      # This test uses a dedicated describe block with mocked registry
      # See "error paths with mocked registry" describe block
    end

    test "ping option shows connectivity check" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [10, 11, 12] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run(["--ping"])
        end)

      assert output =~ "=== Connectivity Check ==="
      assert output =~ "Pinging"
    end

    test "ping skipped when no loopback aliases" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [] end)
      Hammox.stub(Treehouse.MockLoopback, :setup_script, fn _start, _end -> "mock script" end)
      Hammox.stub(Treehouse.MockLoopback, :setup_commands, fn _start, _end -> ["cmd1"] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run(["--ping"])
        end)

      assert output =~ "=== Connectivity Check ==="
      assert output =~ "SKIPPED"
    end

    test "ping-all option pings all IPs" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [10, 11] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run(["--ping-all"])
        end)

      assert output =~ "Pinging 2 IPs"
    end

    test "ping samples first, middle, last for large ranges" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> Enum.to_list(10..99) end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run(["--ping"])
        end)

      # Should sample 3 IPs (first, middle, last)
      assert output =~ "Pinging 3 IPs"
    end

    test "ping with single IP" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [42] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run(["--ping"])
        end)

      assert output =~ "Pinging 1 IP"
      assert output =~ "127.0.0.42"
    end

    test "ping with two IPs" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [10, 99] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run(["--ping"])
        end)

      assert output =~ "Pinging 2 IPs"
    end
  end

  describe "Mix.Tasks.Treehouse.Doctor.ping_args/2" do
    test "returns macOS args on Darwin" do
      args = Mix.Tasks.Treehouse.Doctor.ping_args("127.0.0.10", {:unix, :darwin})
      assert args == ["-c", "1", "-t", "1", "127.0.0.10"]
    end

    test "returns Linux args on Linux" do
      args = Mix.Tasks.Treehouse.Doctor.ping_args("127.0.0.10", {:unix, :linux})
      assert args == ["-c", "1", "-W", "1", "127.0.0.10"]
    end

    test "returns Windows args on Windows" do
      args = Mix.Tasks.Treehouse.Doctor.ping_args("127.0.0.10", {:win32, :nt})
      assert args == ["-n", "1", "-w", "1000", "127.0.0.10"]
    end

    test "uses system OS type by default" do
      # This just verifies the function works without explicit OS type
      args = Mix.Tasks.Treehouse.Doctor.ping_args("127.0.0.10")
      assert is_list(args)
      assert length(args) == 5
    end
  end

  describe "mix treehouse.doctor ping success" do
    test "ping shows OK when pings succeed" do
      :meck.new(System, [:passthrough, :unstick, :no_passthrough_cover])
      :meck.expect(System, :cmd, fn "ping", _args, _opts -> {"", 0} end)

      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [10] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      on_exit(fn ->
        try do
          :meck.unload(System)
        catch
          _, _ -> :ok
        end
      end)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run(["--ping"])
        end)

      assert output =~ "Status: OK (1/1 reachable)"
    end

    test "ping shows ISSUES when pings fail" do
      :meck.new(System, [:passthrough, :unstick, :no_passthrough_cover])
      :meck.expect(System, :cmd, fn "ping", _args, _opts -> {"Request timeout", 2} end)

      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [10, 11] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      on_exit(fn ->
        try do
          :meck.unload(System)
        catch
          _, _ -> :ok
        end
      end)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run(["--ping"])
        end)

      assert output =~ "Status: ISSUES (2/2 unreachable)"
      assert output =~ "Some IPs failed ping"
      assert output =~ "Loopback aliases not properly configured"
      assert output =~ "Firewall blocking ICMP"
    end
  end

  describe "mix treehouse.doctor error paths" do
    # This test needs to stop the setup-started allocator and registry
    setup %{allocator: allocator, registry: registry} do
      GenServer.stop(allocator)
      GenServer.stop(registry)
      :ok
    end

    test "shows error when registry list fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)
      stub_config_defaults()
      Hammox.stub(Treehouse.MockRegistry, :list_allocations, fn -> {:error, :mock_db_error} end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Treehouse.Allocator.start_link(db_path: "/mock/path", name: Treehouse.Allocator)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Doctor.run([])
        end)

      assert output =~ "Error reading registry"
    end
  end

  describe "mix treehouse.loopback" do
    test "outputs setup commands" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Loopback.run([])
        end)

      # On macOS, should show ifconfig commands
      case :os.type() do
        {:unix, :darwin} ->
          assert output =~ "ifconfig lo0"
          assert output =~ "127.0.0.10"

        {:unix, _linux} ->
          assert output =~ "ip addr"

        _ ->
          :ok
      end
    end

    test "respects --start and --end options" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Loopback.run(["--start", "50", "--end", "52"])
        end)

      assert output =~ "127.0.0.50"
      assert output =~ "127.0.0.51"
      assert output =~ "127.0.0.52"
      refute output =~ "127.0.0.10"
    end

    test "script mode outputs single line" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Loopback.run(["--script"])
        end)

      assert output =~ "#!/bin/sh"
      assert output =~ "Treehouse loopback setup"
      assert output =~ "seq 10 99"
    end

    test "pf mode outputs packet filter rules on macOS" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Loopback.run(["--pf"])
        end)

      case :os.type() do
        {:unix, :darwin} ->
          assert output =~ "PF NAT"
          assert output =~ "nat on lo0"
          assert output =~ "loopback_treehouse"

        {:unix, _linux} ->
          assert output =~ "Linux typically doesn't need hairpin NAT"

        _ ->
          assert output =~ "not available"
      end
    end

    test "pf mode outputs Linux message" do
      original = :os.type()

      try do
        :meck.new(:os, [:passthrough, :unstick, :no_link])
      catch
        :error, {:already_started, _} -> :ok
      end

      :meck.expect(:os, :type, fn -> {:unix, :linux} end)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Loopback.run(["--pf"])
        end)

      assert output =~ "Linux typically doesn't need hairpin NAT"

      :meck.expect(:os, :type, fn -> original end)
    end

    test "pf mode outputs unsupported message on unknown OS" do
      original = :os.type()

      try do
        :meck.new(:os, [:passthrough, :unstick, :no_link])
      catch
        :error, {:already_started, _} -> :ok
      end

      :meck.expect(:os, :type, fn -> {:win32, :nt} end)

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Loopback.run(["--pf"])
        end)

      assert output =~ "PF rules not available"

      :meck.expect(:os, :type, fn -> original end)
    end
  end

  describe "error paths with mocked branch" do
    test "allocate shows error when branch detection fails" do
      Hammox.expect(Treehouse.MockBranch, :current, fn nil ->
        {:error, "not a git repository"}
      end)

      Application.put_env(:treehouse, :branch_adapter, Treehouse.MockBranch)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.Allocate.run([])
        end)

      assert output =~ "Error getting branch:"
    end

    test "info shows error when branch detection fails" do
      Hammox.expect(Treehouse.MockBranch, :current, fn nil ->
        {:error, "not a git repository"}
      end)

      Application.put_env(:treehouse, :branch_adapter, Treehouse.MockBranch)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.Info.run([])
        end)

      assert output =~ "Error getting branch:"
    end

    test "release shows error when branch detection fails" do
      Hammox.expect(Treehouse.MockBranch, :current, fn nil ->
        {:error, "not a git repository"}
      end)

      Application.put_env(:treehouse, :branch_adapter, Treehouse.MockBranch)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.Release.run([])
        end)

      assert output =~ "Error getting branch:"
    end
  end

  describe "error paths with mocked registry" do
    # These tests need to stop the setup-started allocator and registry
    # to avoid conflicts with the mock configuration
    setup %{allocator: allocator, registry: registry} do
      GenServer.stop(allocator)
      GenServer.stop(registry)
      :ok
    end

    test "list shows error when database fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)
      stub_config_defaults()

      Hammox.stub(Treehouse.MockRegistry, :list_allocations, fn ->
        {:error, :mock_db_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Treehouse.Allocator.start_link(db_path: "/mock/path", name: Treehouse.Allocator)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.List.run([])
        end)

      assert output =~ "Error:"
    end

    test "info shows error when database fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)
      stub_config_defaults()

      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _project, _branch ->
        {:error, :mock_db_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Treehouse.Allocator.start_link(db_path: "/mock/path", name: Treehouse.Allocator)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.Info.run(["some-branch"])
        end)

      assert output =~ "Error:"
    end

    test "release shows error when database fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)
      stub_config_defaults()

      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _project, _branch ->
        {:error, :mock_db_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Treehouse.Allocator.start_link(db_path: "/mock/path", name: Treehouse.Allocator)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.Release.run(["some-branch"])
        end)

      assert output =~ "Error:"
    end

    test "allocate shows error when database fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)
      stub_config_defaults()

      Hammox.stub(Treehouse.MockRegistry, :find_by_branch, fn _project, _branch ->
        {:error, :mock_db_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Treehouse.Allocator.start_link(db_path: "/mock/path", name: Treehouse.Allocator)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.Allocate.run(["some-branch"])
        end)

      assert output =~ "Error:"
    end
  end

  describe "mix treehouse.config" do
    test "shows current configuration" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Config.run([])
        end)

      assert output =~ "Treehouse Configuration"
      assert output =~ "IP Range: 127.0.0.10 - 127.0.0.99"
    end

    test "sets ip_range_start" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Config.run(["--start", "20"])
        end)

      assert output =~ "Set ip_range_start = 20"
      assert output =~ "IP Range: 127.0.0.20"
    end

    test "sets ip_range_end" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Config.run(["--end", "80"])
        end)

      assert output =~ "Set ip_range_end = 80"
      assert output =~ "127.0.0.80"
    end

    test "sets both start and end" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Config.run(["--start", "30", "--end", "70"])
        end)

      assert output =~ "Set ip_range_start = 30"
      assert output =~ "Set ip_range_end = 70"
      assert output =~ "IP Range: 127.0.0.30 - 127.0.0.70"
    end
  end

  describe "mix treehouse.config error paths" do
    setup %{allocator: allocator, registry: registry} do
      GenServer.stop(allocator)
      GenServer.stop(registry)
      :ok
    end

    test "shows error when set_config fails" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)
      stub_config_defaults()

      Hammox.stub(Treehouse.MockRegistry, :set_config, fn _key, _value ->
        {:error, :mock_set_error}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Treehouse.Allocator.start_link(db_path: "/mock/path", name: Treehouse.Allocator)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      # Capture both stdout (to suppress noise) and stderr (to check error)
      {_stdout, stderr} =
        capture_io_both(fn ->
          Mix.Tasks.Treehouse.Config.run(["--start", "20"])
        end)

      assert stderr =~ "Error setting"
    end

    test "shows error when get_config fails for start" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)
      stub_config_defaults()

      # Override get_config to return error for ip_range_start
      Hammox.stub(Treehouse.MockRegistry, :get_config, fn
        "ip_range_start" -> {:error, :mock_get_error}
        "ip_range_end" -> {:ok, "99"}
        _key -> {:ok, nil}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Treehouse.Allocator.start_link(
          db_path: "/mock/path",
          name: Treehouse.Allocator,
          ip_range_start: 10,
          ip_range_end: 99
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {_stdout, stderr} =
        capture_io_both(fn ->
          Mix.Tasks.Treehouse.Config.run([])
        end)

      assert stderr =~ "Error reading config"
    end

    test "shows error when get_config fails for end" do
      Hammox.set_mox_global()

      Hammox.stub(Treehouse.MockRegistry, :init_schema, fn -> :ok end)
      stub_config_defaults()

      # Override get_config to return error for ip_range_end
      Hammox.stub(Treehouse.MockRegistry, :get_config, fn
        "ip_range_start" -> {:ok, "10"}
        "ip_range_end" -> {:error, :mock_get_error}
        _key -> {:ok, nil}
      end)

      Application.put_env(:treehouse, :registry_adapter, Treehouse.MockRegistry)
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        Treehouse.Allocator.start_link(
          db_path: "/mock/path",
          name: Treehouse.Allocator,
          ip_range_start: 10,
          ip_range_end: 99
        )

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      {_stdout, stderr} =
        capture_io_both(fn ->
          Mix.Tasks.Treehouse.Config.run([])
        end)

      assert stderr =~ "Error reading config"
    end
  end

  # Helper to capture both stdout and stderr
  defp capture_io_both(fun) do
    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fun)
        send(self(), {:stdout, stdout})
      end)

    stdout =
      receive do
        {:stdout, s} -> s
      after
        0 -> ""
      end

    {stdout, stderr}
  end
end
