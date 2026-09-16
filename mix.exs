defmodule Retain.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/amilner42/retain"

  def project do
    [
      app: :retain,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Retain",
      description:
        "Plug-and-play spaced repetition for Ecto apps: a Leitner ladder over an append-only review log.",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.20"},
      {:jason, "~> 1.4"},
      {:tz, "~> 0.28"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end

  defp docs do
    [
      main: "Retain",
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/templates mix.exs README.md LICENSE)
    ]
  end
end
