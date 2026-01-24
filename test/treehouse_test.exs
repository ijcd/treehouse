defmodule TreehouseTest do
  use ExUnit.Case, async: false

  import Treehouse.TestFixtures

  setup do
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
    test "sanitizes branch names" do
      {:ok, _ip} = Treehouse.allocate("feature/my-branch")
      {:ok, info} = Treehouse.info("feature/my-branch")
      assert info.sanitized_name == "feature-my-branch"
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
end
