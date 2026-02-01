defmodule TreehouseTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Hammox
  import Treehouse.TestFixtures

  setup :verify_on_exit!

  setup do
    on_exit(fn ->
      Application.delete_env(:treehouse, :branch_adapter)
      Application.delete_env(:treehouse, :mdns_adapter)
    end)

    setup_named_allocator(prefix: "treehouse_integration_test")
  end

  describe "full allocation flow" do
    test "allocate, list, info, release" do
      # Allocate
      {:ok, ip} = Treehouse.allocate("main")
      assert ip =~ ~r/^127\.0\.0\.\d+$/

      # List shows it
      {:ok, list} = Treehouse.list()
      assert length(list) == 1
      assert hd(list).branch == "main"

      # Info shows details
      {:ok, info} = Treehouse.info("main")
      assert info.branch == "main"
      assert "127.0.0.#{info.ip_suffix}" == ip

      # Same IP on re-allocate
      {:ok, ip2} = Treehouse.allocate("main")
      assert ip == ip2

      # Release
      :ok = Treehouse.release("main")

      # Info shows nil
      {:ok, nil} = Treehouse.info("main")

      # List is empty
      {:ok, []} = Treehouse.list()
    end

    test "allocate, info, release with explicit project" do
      # Test 2-arity versions with explicit project
      {:ok, ip} = Treehouse.allocate("myproject", "feature-x")
      assert ip =~ ~r/^127\.0\.0\.\d+$/

      {:ok, info} = Treehouse.info("myproject", "feature-x")
      assert info.project == "myproject"
      assert info.branch == "feature-x"

      :ok = Treehouse.release("myproject", "feature-x")
      {:ok, nil} = Treehouse.info("myproject", "feature-x")
    end

    test "multiple branches get different IPs" do
      {:ok, ip1} = Treehouse.allocate("branch-1")
      {:ok, ip2} = Treehouse.allocate("branch-2")
      {:ok, ip3} = Treehouse.allocate("branch-3")

      assert ip1 != ip2
      assert ip2 != ip3
      assert ip1 != ip3

      {:ok, list} = Treehouse.list()
      assert length(list) == 3
    end
  end

  describe "Branch integration" do
    test "sanitizes branch and project names" do
      {:ok, _ip} = Treehouse.allocate("feature/my-branch")
      {:ok, info} = Treehouse.info("feature/my-branch")
      # sanitized_name format is "branch.project"
      assert info.sanitized_name == "feature-my-branch.treehouse"
    end

    test "current returns current branch" do
      {:ok, branch} = Treehouse.Branch.current()
      assert is_binary(branch)
    end
  end

  describe "parse_ip/1" do
    test "parses IP string to tuple" do
      assert Treehouse.parse_ip("127.0.0.1") == {127, 0, 0, 1}
      assert Treehouse.parse_ip("127.0.0.42") == {127, 0, 0, 42}
      assert Treehouse.parse_ip("192.168.1.100") == {192, 168, 1, 100}
    end
  end

  describe "format_ip/1" do
    test "delegates to Config.format_ip" do
      assert Treehouse.format_ip(42) == "127.0.0.42"
    end
  end

  describe "setup/1" do
    test "returns all config needed for Phoenix" do
      {:ok, config} = Treehouse.setup(port: 4000, branch: "test-setup", mdns: false)

      assert config.project == "treehouse"
      assert config.branch == "test-setup"
      assert config.ip =~ ~r/^127\.0\.0\.\d+$/
      assert config.ip_tuple == Treehouse.parse_ip(config.ip)
      assert config.hostname == "test-setup.treehouse.local"
      assert config.mdns_pid == nil
    end

    test "uses auto-detected branch when not specified" do
      {:ok, config} = Treehouse.setup(port: 4000, mdns: false)

      # Should use current git branch
      {:ok, current_branch} = Treehouse.Branch.current()
      assert config.branch == current_branch
    end

    test "allows project override" do
      {:ok, config} = Treehouse.setup(port: 4000, project: "myapp", branch: "main", mdns: false)

      assert config.project == "myapp"
      assert config.hostname == "main.myapp.local"
    end

    test "returns error when branch detection fails" do
      expect(Treehouse.MockBranch, :current, fn nil ->
        {:error, "not a git repository"}
      end)

      Application.put_env(:treehouse, :branch_adapter, Treehouse.MockBranch)

      assert {:error, "not a git repository"} = Treehouse.setup(port: 4000, mdns: false)
    end

    test "sets mdns_pid to nil when mDNS registration fails" do
      # Use MockMdns adapter instead of meck
      Application.put_env(:treehouse, :mdns_adapter, Treehouse.MockMdns)

      expect(Treehouse.MockMdns, :register, fn _name, _ip, _port, _opts ->
        {:error, :unavailable}
      end)

      {:ok, config} = Treehouse.setup(port: 4000, branch: "test-mdns-fail")
      assert config.mdns_pid == nil
    end

    test "sets mdns_pid when mDNS registration succeeds" do
      # Use MockMdns adapter instead of meck
      Application.put_env(:treehouse, :mdns_adapter, Treehouse.MockMdns)
      mock_pid = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn -> Process.exit(mock_pid, :kill) end)

      expect(Treehouse.MockMdns, :register, fn _name, _ip, _port, _opts ->
        {:ok, mock_pid}
      end)

      {:ok, config} = Treehouse.setup(port: 4000, branch: "test-mdns-success")
      assert config.mdns_pid == mock_pid
    end
  end

  describe "setup/1 with exhausted IP pool" do
    # Test allocation failure by exhausting a real IP pool
    # instead of mocking Allocator internals
    test "returns error when IP pool is exhausted", context do
      # Stop the default test allocator and registry
      if context[:allocator], do: GenServer.stop(context[:allocator])
      if context[:registry], do: GenServer.stop(context[:registry])

      # Start fresh with single-IP pool
      {:ok, ctx} =
        setup_named_allocator(prefix: "exhaust_test", ip_range_start: 99, ip_range_end: 99)

      # Allocate the only available IP
      {:ok, _ip} = Treehouse.allocate("first-branch")

      # Next allocation should fail with pool exhausted
      log =
        capture_log(fn ->
          assert {:error, :pool_exhausted} =
                   Treehouse.setup(port: 4000, branch: "second-branch", mdns: false)
        end)

      assert log =~ "IP pool exhausted for treehouse:second-branch"

      # Cleanup (on_exit from setup_named_allocator handles file cleanup)
      GenServer.stop(ctx[:allocator])
      GenServer.stop(ctx[:registry])
    end
  end
end
