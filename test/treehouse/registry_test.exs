defmodule Treehouse.RegistryTest do
  use ExUnit.Case, async: false

  import Treehouse.TestHelpers

  alias Treehouse.Registry

  setup do
    setup_registry()
  end

  describe "allocate/2" do
    test "creates new allocation" do
      {:ok, alloc} = Registry.allocate("main", 10)
      assert alloc.branch == "main"
      assert alloc.ip_suffix == 10
      assert alloc.sanitized_name == "main"
      assert alloc.allocated_at != nil
      assert alloc.last_seen_at != nil
    end

    test "sanitizes branch name" do
      {:ok, alloc} = Registry.allocate("feature/new-thing", 11)
      assert alloc.sanitized_name == "feature-new-thing"
    end

    test "returns existing allocation if branch already exists" do
      {:ok, first} = Registry.allocate("main", 10)
      {:ok, second} = Registry.allocate("main", 20)
      assert first.id == second.id
      assert first.ip_suffix == second.ip_suffix
    end
  end

  describe "find_by_branch/1" do
    test "returns allocation for branch" do
      {:ok, _} = Registry.allocate("main", 10)
      {:ok, found} = Registry.find_by_branch("main")
      assert found.branch == "main"
    end

    test "returns nil for unknown branch" do
      assert {:ok, nil} = Registry.find_by_branch("unknown")
    end
  end

  describe "find_by_ip/1" do
    test "returns allocation for IP suffix" do
      {:ok, _} = Registry.allocate("main", 42)
      {:ok, found} = Registry.find_by_ip(42)
      assert found.branch == "main"
    end

    test "returns nil for unused IP" do
      assert {:ok, nil} = Registry.find_by_ip(99)
    end
  end

  describe "list_allocations/0" do
    test "returns all allocations" do
      {:ok, _} = Registry.allocate("main", 10)
      {:ok, _} = Registry.allocate("develop", 11)
      {:ok, list} = Registry.list_allocations()
      assert length(list) == 2
    end

    test "returns empty list when none" do
      {:ok, list} = Registry.list_allocations()
      assert list == []
    end
  end

  describe "touch/1" do
    test "updates last_seen_at timestamp" do
      {:ok, alloc} = Registry.allocate("main", 10)
      :timer.sleep(10)
      :ok = Registry.touch(alloc.id)
      {:ok, updated} = Registry.find_by_branch("main")
      assert updated.last_seen_at > alloc.last_seen_at
    end
  end

  describe "release/1" do
    test "deletes allocation" do
      {:ok, alloc} = Registry.allocate("main", 10)
      :ok = Registry.release(alloc.id)
      {:ok, found} = Registry.find_by_branch("main")
      assert found == nil
    end
  end

  describe "stale_allocations/1" do
    test "returns empty list when no stale allocations" do
      {:ok, _} = Registry.allocate("fresh-branch", 10)
      {:ok, stale} = Registry.stale_allocations(7)
      assert stale == []
    end
  end

  describe "used_ips/0" do
    test "returns list of used IP suffixes" do
      {:ok, _} = Registry.allocate("main", 10)
      {:ok, _} = Registry.allocate("develop", 20)
      {:ok, ips} = Registry.used_ips()
      assert Enum.sort(ips) == [10, 20]
    end
  end
end
