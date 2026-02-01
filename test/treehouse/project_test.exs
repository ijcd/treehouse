defmodule Treehouse.ProjectTest do
  use ExUnit.Case, async: false

  alias Treehouse.Project

  describe "current/0" do
    test "returns project name from Mix.Project" do
      {:ok, name} = Project.current()
      assert name == "treehouse"
    end
  end

  describe "current!/0" do
    test "returns project name directly" do
      assert Project.current!() == "treehouse"
    end
  end

  describe "current/0 with config override" do
    setup do
      original = Application.get_env(:treehouse, :project)

      on_exit(fn ->
        if original do
          Application.put_env(:treehouse, :project, original)
        else
          Application.delete_env(:treehouse, :project)
        end
      end)

      :ok
    end

    test "prefers explicit config as atom" do
      Application.put_env(:treehouse, :project, :myapp)
      {:ok, name} = Project.current()
      assert name == "myapp"
    end

    test "prefers explicit config as string" do
      Application.put_env(:treehouse, :project, "custom-project")
      {:ok, name} = Project.current()
      assert name == "custom-project"
    end
  end

  describe "sanitize/1" do
    test "passes through simple names" do
      assert Project.sanitize("myapp") == "myapp"
      assert Project.sanitize("treehouse") == "treehouse"
    end

    test "lowercases" do
      assert Project.sanitize("MyApp") == "myapp"
      assert Project.sanitize("TREEHOUSE") == "treehouse"
    end

    test "replaces invalid characters with dashes" do
      assert Project.sanitize("my_app") == "my-app"
      assert Project.sanitize("my.app") == "my-app"
    end

    test "collapses multiple dashes" do
      assert Project.sanitize("my--app") == "my-app"
      assert Project.sanitize("my___app") == "my-app"
    end

    test "trims leading/trailing dashes" do
      assert Project.sanitize("-myapp-") == "myapp"
      assert Project.sanitize("--app--") == "app"
    end

    test "truncates long names to 20 chars" do
      long = String.duplicate("a", 30)
      result = Project.sanitize(long)
      assert byte_size(result) <= 20
    end

    test "truncates and trims trailing dash" do
      # 21 chars with dash at position 20
      long = String.duplicate("a", 19) <> "-b"
      result = Project.sanitize(long)
      assert byte_size(result) <= 20
      refute String.ends_with?(result, "-")
    end
  end

  # NOTE: These tests use meck because Mix.Project is an external stdlib module
  # we can't inject. They test behavior when running outside Mix (releases, escripts).
  describe "fallback paths" do
    setup do
      # Clear any config override so we test the fallback chain
      original = Application.get_env(:treehouse, :project)
      Application.delete_env(:treehouse, :project)

      on_exit(fn ->
        if original do
          Application.put_env(:treehouse, :project, original)
        else
          Application.delete_env(:treehouse, :project)
        end
      end)

      :ok
    end

    test "falls back to directory when Mix.Project.config has no :app" do
      :meck.new(Mix.Project, [:passthrough, :unstick, :no_passthrough_cover])
      :meck.expect(Mix.Project, :config, fn -> [] end)

      on_exit(fn ->
        try do
          :meck.unload(Mix.Project)
        catch
          _, _ -> :ok
        end
      end)

      # from_mix returns nil (no :app key), falls through to from_directory
      {:ok, name} = Project.current()
      # Directory name is "treehouse"
      assert name == "treehouse"
    end

    test "falls back to directory when Mix.Project.config/0 not exported" do
      :meck.new(Mix.Project, [:passthrough, :unstick, :no_passthrough_cover])
      # Delete the config function so function_exported? returns false
      :meck.delete(Mix.Project, :config, 0)

      on_exit(fn ->
        try do
          :meck.unload(Mix.Project)
        catch
          _, _ -> :ok
        end
      end)

      # from_mix hits else branch (function not exported), falls to from_directory
      {:ok, name} = Project.current()
      assert name == "treehouse"
    end
  end
end
