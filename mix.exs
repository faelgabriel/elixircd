defmodule ElixIRCd.MixProject do
  @moduledoc false
  use Mix.Project

  def project do
    [
      app: :elixircd,
      version: System.get_env("APP_VERSION") || "0.0.1-dev",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:yecc] ++ Mix.compilers(),
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.github": :test
      ],
      test_coverage: [tool: ExCoveralls],
      releases: [
        elixircd: [
          include_executables_for: include_executables_for()
        ]
      ]
    ]
  end

  defp aliases do
    [
      "check.all": [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "sobelow --config",
        "deps.audit",
        "doctor",
        "dialyzer"
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {ElixIRCd, []},
      extra_applications: [:logger, :memento, :mix]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:argon2_elixir, "~> 4.0"},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev], runtime: false},
      {:doctor, "~> 0.21.0", only: :dev},
      {:excoveralls, "~> 0.18", only: :test},
      {:memento, "~> 0.3.2"},
      {:mix_audit, "~> 2.0", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.7", only: [:dev, :test]},
      {:ranch, "~> 2.1"},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:wait_for_it, "~> 2.1", only: [:dev, :test]}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit, :mix],
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp include_executables_for do
    case :os.type() do
      {:unix, _} -> [:unix]
      {:win32, _} -> [:windows]
    end
  end
end
