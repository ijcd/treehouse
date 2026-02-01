defmodule Treehouse.RegistryTest do
  use ExUnit.Case, async: false

  import Treehouse.TestFixtures

  alias Treehouse.Registry

  @project "testapp"

  setup do
    setup_registry()
  end

  describe "allocate/3" do
    test "creates new allocation" do
      {:ok, alloc} = Registry.allocate(@project, "main", 10)
      assert alloc.project == @project
      assert alloc.branch == "main"
      assert alloc.ip_suffix == 10
      assert alloc.sanitized_name == "main.testapp"
      assert alloc.allocated_at != nil
      assert alloc.last_seen_at != nil
    end

    test "sanitizes project and branch name" do
      {:ok, alloc} = Registry.allocate("MyApp", "feature/new-thing", 11)
      assert alloc.sanitized_name == "feature-new-thing.myapp"
    end

    test "returns existing allocation if project/branch already exists" do
      {:ok, first} = Registry.allocate(@project, "main", 10)
      {:ok, second} = Registry.allocate(@project, "main", 20)
      assert first.id == second.id
      assert first.ip_suffix == second.ip_suffix
    end

    test "different projects can have same branch" do
      {:ok, alloc1} = Registry.allocate("app1", "main", 10)
      {:ok, alloc2} = Registry.allocate("app2", "main", 11)
      assert alloc1.id != alloc2.id
      assert alloc1.ip_suffix != alloc2.ip_suffix
    end
  end

  describe "find_by_branch/2" do
    test "returns allocation for project/branch" do
      {:ok, _} = Registry.allocate(@project, "main", 10)
      {:ok, found} = Registry.find_by_branch(@project, "main")
      assert found.branch == "main"
      assert found.project == @project
    end

    test "returns nil for unknown branch" do
      assert {:ok, nil} = Registry.find_by_branch(@project, "unknown")
    end

    test "returns nil for wrong project" do
      {:ok, _} = Registry.allocate("app1", "main", 10)
      assert {:ok, nil} = Registry.find_by_branch("app2", "main")
    end
  end

  describe "find_by_ip/1" do
    test "returns allocation for IP suffix" do
      {:ok, _} = Registry.allocate(@project, "main", 42)
      {:ok, found} = Registry.find_by_ip(42)
      assert found.branch == "main"
      assert found.project == @project
    end

    test "returns nil for unused IP" do
      assert {:ok, nil} = Registry.find_by_ip(99)
    end
  end

  describe "list_allocations/0" do
    test "returns all allocations" do
      {:ok, _} = Registry.allocate(@project, "main", 10)
      {:ok, _} = Registry.allocate(@project, "develop", 11)
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
      {:ok, alloc} = Registry.allocate(@project, "main", 10)
      :timer.sleep(10)
      :ok = Registry.touch(alloc.id)
      {:ok, updated} = Registry.find_by_branch(@project, "main")
      assert updated.last_seen_at > alloc.last_seen_at
    end
  end

  describe "release/1" do
    test "deletes allocation" do
      {:ok, alloc} = Registry.allocate(@project, "main", 10)
      :ok = Registry.release(alloc.id)
      {:ok, found} = Registry.find_by_branch(@project, "main")
      assert found == nil
    end
  end

  describe "stale_allocations/1" do
    test "returns empty list when no stale allocations" do
      {:ok, _} = Registry.allocate(@project, "fresh-branch", 10)
      {:ok, stale} = Registry.stale_allocations(7)
      assert stale == []
    end
  end

  describe "used_ips/0" do
    test "returns list of used IP suffixes" do
      {:ok, _} = Registry.allocate(@project, "main", 10)
      {:ok, _} = Registry.allocate(@project, "develop", 20)
      {:ok, ips} = Registry.used_ips()
      assert Enum.sort(ips) == [10, 20]
    end
  end
end
