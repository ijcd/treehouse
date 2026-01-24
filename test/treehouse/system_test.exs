defmodule Treehouse.SystemTest do
  use ExUnit.Case, async: true

  describe "Treehouse.System" do
    test "adapter/0 returns Native by default" do
      assert Treehouse.System.adapter() == Treehouse.System.Native
    end

    test "find_executable/1 delegates to adapter" do
      # Uses the real native adapter
      assert Treehouse.System.find_executable("ls") =~ "ls"
    end
  end

  describe "Treehouse.System.Native" do
    test "find_executable/1 finds existing command" do
      path = Treehouse.System.Native.find_executable("ls")
      assert is_binary(path)
      assert path =~ "ls"
    end

    test "find_executable/1 returns nil for missing command" do
      assert Treehouse.System.Native.find_executable("nonexistent_command_xyz") == nil
    end
  end
end
