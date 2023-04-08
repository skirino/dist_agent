defmodule DistAgent.Mixfile do
  use Mix.Project

  @github_url "https://github.com/skirino/dist_agent"

  def project() do
    [
      app:               :dist_agent,
      version:           "0.3.1",
      elixir:            "~> 1.6",
      build_embedded:    Mix.env() == :prod,
      start_permanent:   Mix.env() == :prod,
      deps:              deps(),
      description:       "Elixir framework to run distributed, fault-tolerant variant of Agent.",
      package:           package(),
      source_url:        @github_url,
      homepage_url:      @github_url,
      test_coverage:     [tool: ExCoveralls],
      preferred_cli_env: [coveralls: :test, "coveralls.detail": :test, "coveralls.post": :test, "coveralls.html": :test],
    ]
  end

  def application() do
    [
      mod: {DistAgent.Application, []},
    ]
  end

  defp deps() do
    [
      {:croma       , "~> 0.10"},
      {:rafted_value, "~> 0.10"},
      {:raft_fleet  , "~> 0.9"},
      {:raft_kv     , "~> 0.2.4"},
      {:foretoken   , "~> 0.3"},
      {:dialyxir    , "~> 1.3" , [only: :dev , runtime: false]},
      {:ex_doc      , "~> 0.29", [only: :dev , runtime: false]},
      {:excoveralls , "~> 0.16", [only: :test, runtime: false]},
    ]
  end

  defp package() do
    [
      files:       ["lib", "mix.exs", "README.md", "LICENSE"],
      maintainers: ["Shunsuke Kirino"],
      licenses:    ["MIT"],
      links:       %{"GitHub repository" => @github_url},
    ]
  end
end
