defmodule Treehouse.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ijcd/treehouse"

  def project do
    [
      app: :treehouse,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Local development IP manager - a home for your worktrees",
      package: package(),
      docs: docs(),
      test_coverage: [summary: [threshold: 90]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Treehouse.Application, []}
    ]
  end

  defp deps do
    [
      {:exqlite, "~> 0.23"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:hammox, "~> 0.7", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"]
    ]
  end
end
