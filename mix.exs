defmodule Isabelle.MixProject do
  use Mix.Project

  # ------------ Project metadata ------------------------------------------
  def project do
    [
      app: :isabelle_elixir,
      version: "0.2.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex / docs metadata
      description: "Elixir client for the Isabelle proof assistant",
      source_url: "https://github.com/davfuenmayor/isabelle_elixir",
      homepage_url: "https://isabelle.in.tum.de",
      package: [
        licenses: ["MIT"],
        links: %{
          "GitHub" => "https://github.com/davfuenmayor/isabelle_elixir",
          "Isabelle" => "https://isabelle.in.tum.de"
        }
      ],
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  # ------------ OTP application metadata ----------------------------------
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # ------------ Dependencies ----------------------------------------------
  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
