defmodule ElixIRCd.MixProject do
  @moduledoc false
  use Mix.Project

  def project do
    [
      app: :elixircd,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env()),

      # Coveralls
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.github": :test
      ],
      test_coverage: [tool: ExCoveralls],

      # Docs
      name: "ElixIRCd",
      source_url: "https://github.com/faelgabriel/elixircd",
      homepage_url: "https://faelgabriel.github.io/elixircd",
      docs: [
        main: "ElixIRCd",
        extras: ["README.md"]
      ]
    ]
  end

  defp aliases do
    []
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {ElixIRCd, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:doctor, "~> 0.21.0", only: :dev},
      # Ecto override until Etso is updated
      {:ecto, "~> 3.11", override: true},
      {:etso, "~> 1.1.0"},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:ex_machina, "~> 2.7", only: [:dev, :test]},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.7", only: [:dev, :test]},
      {:ranch, "~> 2.1"},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:typed_ecto_schema, "~> 0.4.1", runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
