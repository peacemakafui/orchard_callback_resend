defmodule OrchardResend.MixProject do
  use Mix.Project

  def project do
    [
      app: :orchard_resend,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {OrchardResend.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.12"},
      {:postgrex, "~> 0.20"},
      {:httpoison, "~> 2.2"},
      {:poison, "~> 6.0"},
      {:jason, "~> 1.4"},
      {:ecto_sql, "~> 3.12"},
      {:hackney, "~> 1.23"}
    ]
  end
end
