defmodule ElixIRCd.MixProject do
  @moduledoc false
  use Mix.Project

  def project do
    [
      app: :elixircd,
      version: app_version() || "0.0.0-unversioned",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:yecc] ++ Mix.compilers(),
      test_coverage: [tool: ExCoveralls],
      releases: [
        elixircd: [
          steps: [:assemble, &assemble_config/1]
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.github": :test
      ]
    ]
  end

  defp aliases do
    [
      quality: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "sobelow --config",
        "deps.audit",
        "doctor",
        "dialyzer",
        "cmd --shell MIX_ENV=test mix coveralls"
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
      # Core dependencies
      {:argon2_elixir, "~> 4.1"},
      {:bandit, "~> 1.12"},
      {:cidr, "~> 1.2"},
      {:hammer, "~> 7.5"},
      {:memento, "~> 0.6"},
      {:thousand_island, "~> 1.5"},
      {:websock_adapter, "~> 0.6"},

      # Email dependencies
      {:bamboo, "~> 2.5"},
      {:bamboo_mua, "~> 0.2"},

      # Development and testing tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:doctor, "~> 0.23", only: :dev},
      {:excoveralls, "~> 0.18", only: :test},
      {:mimic, "~> 2.4", only: [:dev, :test]},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.15", only: [:dev, :test], runtime: false}
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
