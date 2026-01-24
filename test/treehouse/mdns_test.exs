defmodule Treehouse.MdnsTest do
  use ExUnit.Case, async: false

  alias Treehouse.Mdns

  describe "build_command/3" do
    test "builds dns-sd proxy command for hostname resolution" do
      {cmd, args} = Mdns.build_command("my-branch", "127.0.0.42", 4000)
      assert cmd == "dns-sd"
      assert "-P" in args
      assert "my-branch" in args
      assert "_http._tcp" in args
      assert "local" in args
      assert "4000" in args
      assert "my-branch.local" in args  # hostname
      assert "127.0.0.42" in args       # IP for A record
    end

    test "uses custom service type" do
      {_cmd, args} = Mdns.build_command("branch", "127.0.0.10", 4000, service_type: "_https._tcp")
      assert "_https._tcp" in args
    end

    test "uses custom domain" do
      {_cmd, args} = Mdns.build_command("branch", "127.0.0.10", 4000, domain: "dev")
      assert "dev" in args
      assert "branch.dev" in args  # hostname uses custom domain
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
end
