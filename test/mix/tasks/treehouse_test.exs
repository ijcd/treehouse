defmodule Mix.Tasks.TreehouseTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Hammox

  setup :verify_on_exit!

  setup do
    # Start Allocator with temp DB
    db_path = Path.join(System.tmp_dir!(), "treehouse_mix_test_#{:rand.uniform(100_000)}.db")
    {:ok, pid} = Treehouse.Allocator.start_link(db_path: db_path, name: Treehouse.Allocator)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(db_path)
      # Reset adapter to default
      Application.delete_env(:treehouse, :branch_adapter)
    end)

    :ok
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

      assert output =~ "Branch"
      assert output =~ "test-branch"
      assert output =~ "127.0.0."
    end
  end

  describe "mix treehouse.info" do
    test "shows no allocation for unknown branch" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Info.run(["unknown-branch"])
        end)

      assert output =~ "No allocation for branch: unknown-branch"
    end

    test "shows allocation info for known branch" do
      {:ok, _} = Treehouse.allocate("info-test")

      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Info.run(["info-test"])
        end)

      assert output =~ "Branch:     info-test"
      assert output =~ "Hostname:   info-test.local"
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

      assert output =~ "Released allocation for: release-test"

      # Verify it's gone
      {:ok, nil} = Treehouse.info("release-test")
    end

    test "releases non-existent branch is ok" do
      output =
        capture_io(fn ->
          Mix.Tasks.Treehouse.Release.run(["nonexistent"])
        end)

      assert output =~ "Released allocation for: nonexistent"
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

  describe "error paths with mocked branch" do
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

  describe "error paths with closed connection" do
    test "list shows error when database fails" do
      # Get internal connection and close it to simulate DB failure
      state = :sys.get_state(Treehouse.Allocator)
      Exqlite.Sqlite3.close(state.conn)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.List.run([])
        end)

      assert output =~ "Error:"
    end

    test "info shows error when database fails" do
      state = :sys.get_state(Treehouse.Allocator)
      Exqlite.Sqlite3.close(state.conn)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.Info.run(["some-branch"])
        end)

      assert output =~ "Error:"
    end

    test "release shows error when database fails" do
      state = :sys.get_state(Treehouse.Allocator)
      Exqlite.Sqlite3.close(state.conn)

      output =
        capture_io(:stderr, fn ->
          Mix.Tasks.Treehouse.Release.run(["some-branch"])
        end)

      assert output =~ "Error:"
    end
  end
end
