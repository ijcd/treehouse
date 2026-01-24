defmodule Treehouse.MdnsTest do
  use ExUnit.Case, async: false

  import Hammox

  alias Treehouse.Mdns

  setup :verify_on_exit!

  describe "DnsSd.build_command/4" do
    test "builds dns-sd proxy command for hostname resolution" do
      {cmd, args} = Mdns.DnsSd.build_command("my-branch", "127.0.0.42", 4000)
      assert cmd == "dns-sd"
      assert "-P" in args
      assert "my-branch" in args
      assert "_http._tcp" in args
      assert "local" in args
      assert "4000" in args
      # hostname
      assert "my-branch.local" in args
      # IP for A record
      assert "127.0.0.42" in args
    end

    test "uses custom service type" do
      {_cmd, args} =
        Mdns.DnsSd.build_command("branch", "127.0.0.10", 4000, service_type: "_https._tcp")

      assert "_https._tcp" in args
    end

    test "uses custom domain" do
      {_cmd, args} = Mdns.DnsSd.build_command("branch", "127.0.0.10", 4000, domain: "dev")
      assert "dev" in args
      # hostname uses custom domain
      assert "branch.dev" in args
    end
  end

  describe "register/4" do
    @tag :integration
    test "starts dns-sd process" do
      {:ok, pid} = Mdns.register("test-branch-#{:rand.uniform(1000)}", "127.0.0.42", 4000)
      assert Process.alive?(pid)
      Mdns.unregister(pid)
      refute Process.alive?(pid)
    end
  end

  describe "unregister/1" do
    @tag :integration
    test "stops the dns-sd process" do
      {:ok, pid} = Mdns.register("test-#{:rand.uniform(1000)}", "127.0.0.42", 4000)
      assert :ok = Mdns.unregister(pid)
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "DnsSd monitor_port with mocked system" do
    setup do
      # Set mock adapter for this test
      Application.put_env(:treehouse, :system_adapter, Treehouse.MockSystem)
      # Set Hammox to global mode so spawned processes can use the mock
      Hammox.set_mox_global()

      on_exit(fn ->
        Application.delete_env(:treehouse, :system_adapter)
      end)

      :ok
    end

    test "handles port data and exit_status messages" do
      # Mock find_executable to return echo, which outputs data and exits
      Hammox.stub(Treehouse.MockSystem, :find_executable, fn "dns-sd" ->
        "/bin/echo"
      end)

      {:ok, pid} = Treehouse.Mdns.DnsSd.register("mock-test", "127.0.0.1", 4000)
      assert is_pid(pid)

      # Wait for echo to output and exit, triggering both receive branches
      Process.sleep(150)

      # Monitor should have processed exit_status and terminated
      refute Process.alive?(pid)
    end

    test "handles immediate exit" do
      # Mock to return /usr/bin/true which exits immediately with status 0
      Hammox.stub(Treehouse.MockSystem, :find_executable, fn "dns-sd" ->
        "/usr/bin/true"
      end)

      {:ok, pid} = Treehouse.Mdns.DnsSd.register("exit-test", "127.0.0.1", 4000)
      assert is_pid(pid)

      Process.sleep(150)
      refute Process.alive?(pid)
    end
  end
end
