defmodule ElixIRCd.MixProject do
  @moduledoc false
  use Mix.Project

  def project do
    [
      app: :elixircd,
      version: app_version() || "0.0.0-dev",
      elixir: "~> 1.18",
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
          steps: [:assemble, &assemble_config/1]
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

  def application do
    [
      mod: {ElixIRCd, []},
      extra_applications: [:logger, :memento]
    ]
  end

  defp deps do
    [
      {:bamboo, "~> 2.4"},
      {:bamboo_mua, "~> 0.2"},
      {:bandit, "~> 1.5"},
      {:cidr, ">= 1.1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:doctor, "~> 0.21", only: :dev},
      {:excoveralls, "~> 0.18", only: :test},
      {:hammer, "~> 7.0"},
      {:memento, "~> 0.4"},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.10", only: [:dev, :test]},
      {:argon2_elixir, "~> 4.0"},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:thousand_island, "~> 1.3"},
      {:websock_adapter, "~> 0.5"}
    ]
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit, :mix],
      plt_file: {:no_warn, ".dialyzer/dialyzer.plt"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp app_version do
    case System.get_env("APP_VERSION") do
      nil -> nil
      "" -> nil
      version -> version
    end
  end

  defp assemble_config(release) do
    source_path = Path.join([__DIR__, "config", "elixircd.exs"])
    destination_path = Path.join([release.path, "config", "elixircd.exs"])
    File.mkdir_p!(Path.dirname(destination_path))
    File.copy!(source_path, destination_path)
    release
  end
end
