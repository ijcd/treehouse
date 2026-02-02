defmodule Treehouse.LoopbackTest do
  use ExUnit.Case, async: false

  import Hammox
  import Treehouse.TestFixtures

  alias Treehouse.Loopback

  setup :verify_on_exit!

  setup do
    on_exit(&cleanup_adapter_env/0)
    :ok
  end

  describe "available_ips/0" do
    test "returns list of integers" do
      result = Loopback.available_ips()
      assert is_list(result)
      Enum.each(result, fn ip -> assert is_integer(ip) end)
    end

    test "filters out 127.0.0.1 (base loopback)" do
      result = Loopback.available_ips()
      refute 1 in result
    end

    test "returns sorted list" do
      result = Loopback.available_ips()
      assert result == Enum.sort(result)
    end

    test "delegates to configured adapter" do
      Hammox.stub(Treehouse.MockLoopback, :available_ips, fn -> [42, 43, 44] end)
      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      assert Loopback.available_ips() == [42, 43, 44]
    end
  end

  describe "available_count/0" do
    test "returns count of available IPs" do
      count = Loopback.available_count()
      assert is_integer(count)
      assert count >= 0
      assert count == length(Loopback.available_ips())
    end
  end

  describe "available?/1" do
    test "returns boolean for IP suffix" do
      available = Loopback.available_ips()

      if available != [] do
        first_available = List.first(available)
        assert Loopback.available?(first_available) == true
      end

      # 1 is never available (base loopback filtered out)
      assert Loopback.available?(1) == false
    end
  end

  describe "setup_commands/2" do
    test "returns list of commands" do
      commands = Loopback.setup_commands(10, 12)
      assert is_list(commands)
      assert length(commands) == 3
    end

    test "uses default range 10-99 when no args" do
      commands = Loopback.setup_commands()
      assert length(commands) == 90
    end

    test "delegates to configured adapter" do
      Hammox.stub(Treehouse.MockLoopback, :setup_commands, fn 5, 7 ->
        ["cmd1", "cmd2", "cmd3"]
      end)

      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      assert Loopback.setup_commands(5, 7) == ["cmd1", "cmd2", "cmd3"]
    end
  end

  describe "setup_script/2" do
    test "returns single string command" do
      script = Loopback.setup_script(10, 20)
      assert is_binary(script)
    end

    test "uses default range 10-99 when no args" do
      script = Loopback.setup_script()
      assert script =~ "10" and script =~ "99"
    end

    test "delegates to configured adapter" do
      Hammox.stub(Treehouse.MockLoopback, :setup_script, fn 5, 7 ->
        "mock script"
      end)

      Application.put_env(:treehouse, :loopback_adapter, Treehouse.MockLoopback)

      assert Loopback.setup_script(5, 7) == "mock script"
    end
  end

  describe "default adapter selection" do
    # These tests mock :os.type to test adapter selection on different OSes

    test "selects Linux adapter on Linux" do
      original = :os.type()

      try do
        :meck.new(:os, [:passthrough, :unstick, :no_link])
      catch
        :error, {:already_started, _} -> :ok
      end

      :meck.expect(:os, :type, fn -> {:unix, :linux} end)
      Application.delete_env(:treehouse, :loopback_adapter)

      result = Loopback.setup_script(10, 10)
      assert result =~ "ip addr"

      # Restore
      :meck.expect(:os, :type, fn -> original end)
    end

    test "selects Unsupported adapter on unknown OS" do
      original = :os.type()

      try do
        :meck.new(:os, [:passthrough, :unstick, :no_link])
      catch
        :error, {:already_started, _} -> :ok
      end

      :meck.expect(:os, :type, fn -> {:win32, :nt} end)
      Application.delete_env(:treehouse, :loopback_adapter)

      result = Loopback.setup_script(10, 10)
      assert result =~ "Unsupported"

      # Restore
      :meck.expect(:os, :type, fn -> original end)
    end
  end
end

defmodule Treehouse.Loopback.DarwinTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Only run on macOS
  @moduletag :darwin

  alias Treehouse.Loopback.Darwin

  setup do
    case :os.type() do
      {:unix, :darwin} -> :ok
      _ -> {:skip, "Darwin tests only run on macOS"}
    end
  end

  describe "available_ips/0" do
    test "parses ifconfig output" do
      result = Darwin.available_ips()
      assert is_list(result)
      Enum.each(result, fn ip -> assert is_integer(ip) end)
    end

    test "returns empty list and logs warning when ifconfig fails" do
      # Mock System.cmd to simulate ifconfig failure
      :meck.new(System, [:passthrough, :no_passthrough_cover])
      :meck.expect(System, :cmd, fn "ifconfig", ["lo0"], _ -> {"error message", 1} end)

      log =
        capture_log(fn ->
          assert Darwin.available_ips() == []
        end)

      assert log =~ "Failed to query loopback"

      :meck.unload(System)
    end
  end

  describe "setup_commands/2" do
    test "generates ifconfig commands" do
      commands = Darwin.setup_commands(10, 12)
      assert hd(commands) =~ "ifconfig lo0 alias 127.0.0.10"
    end
  end

  describe "setup_script/2" do
    test "generates ifconfig script" do
      script = Darwin.setup_script(10, 20)
      assert script =~ "ifconfig lo0"
      assert script =~ "seq 10 20"
    end
  end
end

defmodule Treehouse.Loopback.LinuxTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Treehouse.Loopback.Linux

  describe "available_ips/0" do
    test "parses ip addr output when command succeeds" do
      :meck.new(System, [:passthrough, :no_passthrough_cover])

      :meck.expect(System, :cmd, fn "ip", ["addr", "show", "lo"], _ ->
        output = """
        1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN
            inet 127.0.0.1/8 scope host lo
            inet 127.0.0.10/8 scope host secondary lo
            inet 127.0.0.11/8 scope host secondary lo
        """

        {output, 0}
      end)

      assert Linux.available_ips() == [10, 11]

      :meck.unload(System)
    end

    test "returns empty list and logs warning when ip command fails" do
      :meck.new(System, [:passthrough, :no_passthrough_cover])
      :meck.expect(System, :cmd, fn "ip", ["addr", "show", "lo"], _ -> {"error", 1} end)

      log =
        capture_log(fn ->
          assert Linux.available_ips() == []
        end)

      assert log =~ "Failed to query loopback"

      :meck.unload(System)
    end
  end

  describe "setup_commands/2" do
    test "generates ip addr commands" do
      commands = Linux.setup_commands(10, 12)
      assert hd(commands) =~ "ip addr add 127.0.0.10"
    end
  end

  describe "setup_script/2" do
    test "generates ip addr script" do
      script = Linux.setup_script(10, 20)
      assert script =~ "ip addr add"
      assert script =~ "seq 10 20"
    end
  end
end

defmodule Treehouse.Loopback.UnsupportedTest do
  use ExUnit.Case, async: true

  alias Treehouse.Loopback.Unsupported

  describe "available_ips/0" do
    test "returns empty list" do
      assert Unsupported.available_ips() == []
    end
  end

  describe "setup_commands/2" do
    test "returns unsupported message" do
      assert Unsupported.setup_commands(10, 20) == ["# Unsupported platform"]
    end
  end

  describe "setup_script/2" do
    test "returns unsupported message" do
      assert Unsupported.setup_script(10, 20) == "# Unsupported platform"
    end
  end
end
