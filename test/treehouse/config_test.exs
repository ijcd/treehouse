defmodule Treehouse.ConfigTest do
  use ExUnit.Case, async: true

  alias Treehouse.Config

  describe "domain/1" do
    test "returns default domain" do
      assert Config.domain() == "local"
    end

    test "returns domain from opts" do
      assert Config.domain(domain: "dev") == "dev"
    end

    test "returns domain from app config" do
      Application.put_env(:treehouse, :domain, "test")
      on_exit(fn -> Application.delete_env(:treehouse, :domain) end)

      assert Config.domain() == "test"
    end
  end

  describe "ip_prefix/0" do
    test "returns default ip prefix" do
      assert Config.ip_prefix() == "127.0.0"
    end

    test "returns ip prefix from app config" do
      Application.put_env(:treehouse, :ip_prefix, "192.168.1")
      on_exit(fn -> Application.delete_env(:treehouse, :ip_prefix) end)

      assert Config.ip_prefix() == "192.168.1"
    end
  end

  describe "ip_range_start/1" do
    test "returns default range start" do
      assert Config.ip_range_start() == 10
    end

    test "returns range start from opts" do
      assert Config.ip_range_start(ip_range_start: 50) == 50
    end
  end

  describe "ip_range_end/1" do
    test "returns default range end" do
      assert Config.ip_range_end() == 99
    end

    test "returns range end from opts" do
      assert Config.ip_range_end(ip_range_end: 200) == 200
    end
  end

  describe "stale_threshold_days/1" do
    test "returns default threshold" do
      assert Config.stale_threshold_days() == 7
    end

    test "returns threshold from opts" do
      assert Config.stale_threshold_days(stale_threshold_days: 14) == 14
    end
  end

  describe "registry_path/1" do
    test "returns default path" do
      assert Config.registry_path() == "~/.local/share/treehouse/registry.db"
    end

    test "returns path from opts" do
      assert Config.registry_path(db_path: "/tmp/test.db") == "/tmp/test.db"
    end
  end

  describe "format_ip/1" do
    test "formats ip suffix with default prefix" do
      assert Config.format_ip(42) == "127.0.0.42"
    end

    test "formats ip suffix with custom prefix" do
      Application.put_env(:treehouse, :ip_prefix, "10.0.0")
      on_exit(fn -> Application.delete_env(:treehouse, :ip_prefix) end)

      assert Config.format_ip(1) == "10.0.0.1"
    end
  end
end
