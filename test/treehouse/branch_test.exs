defmodule Treehouse.BranchTest do
  use ExUnit.Case, async: true

  alias Treehouse.Branch

  describe "current/0" do
    test "returns current git branch name" do
      # We're in a git repo, so this should work
      {:ok, branch} = Branch.current()
      assert is_binary(branch)
      assert String.length(branch) > 0
    end
  end

  describe "current/1 with path" do
    test "returns branch for given path" do
      {:ok, branch} = Branch.current(File.cwd!())
      assert is_binary(branch)
    end

    test "returns error for non-git directory" do
      assert {:error, _} = Branch.current("/tmp")
    end
  end

  describe "sanitize/1" do
    test "passes through simple branch names" do
      assert Branch.sanitize("main") == "main"
      assert Branch.sanitize("feature") == "feature"
    end

    test "replaces slashes with dashes" do
      assert Branch.sanitize("feature/new-thing") == "feature-new-thing"
      assert Branch.sanitize("user/feature/sub") == "user-feature-sub"
    end

    test "removes special characters" do
      assert Branch.sanitize("feature@thing") == "featurething"
      assert Branch.sanitize("feature#123") == "feature123"
    end

    test "handles underscores" do
      assert Branch.sanitize("feature_name") == "feature-name"
    end

    test "lowercases everything" do
      assert Branch.sanitize("Feature-Name") == "feature-name"
      assert Branch.sanitize("MAIN") == "main"
    end

    test "collapses multiple dashes" do
      assert Branch.sanitize("feature--name") == "feature-name"
      assert Branch.sanitize("a---b") == "a-b"
    end

    test "trims leading/trailing dashes" do
      assert Branch.sanitize("-feature-") == "feature"
      assert Branch.sanitize("--name--") == "name"
    end

    test "handles complex branch names" do
      assert Branch.sanitize("ijcd/feature/add-new-thing_v2") == "ijcd-feature-add-new-thing-v2"
    end

    test "preserves short names unchanged" do
      short = "short-branch"
      assert Branch.sanitize(short) == short
    end

    test "truncates long names with hash suffix" do
      long = String.duplicate("a", 100)
      result = Branch.sanitize(long)
      assert byte_size(result) <= 63
      # Should have hash suffix
      assert result =~ ~r/-[a-f0-9]{8}$/
    end

    test "different long names produce different hashes" do
      long1 = String.duplicate("a", 100)
      long2 = String.duplicate("b", 100)
      assert Branch.sanitize(long1) != Branch.sanitize(long2)
    end

    test "exactly 63 char name is unchanged" do
      exact = String.duplicate("a", 63)
      assert Branch.sanitize(exact) == exact
    end
  end

  describe "hostname/1" do
    test "appends domain suffix" do
      assert Branch.hostname("main") == "main.local"
      assert Branch.hostname("feature-branch") == "feature-branch.local"
    end

    test "uses configured domain" do
      assert Branch.hostname("main", domain: "dev") == "main.dev"
    end
  end
end
