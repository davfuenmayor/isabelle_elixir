defmodule Isabelle.MixProject do
  use Mix.Project

  # ------------ Project metadata ------------------------------------------
  def project do
    [
      app: :isabelle_elixir,
      version: "0.4.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),

      # Hex / docs metadata
      description: "Elixir client for the Isabelle proof assistant",
      source_url: "https://github.com/davfuenmayor/isabelle_elixir",
      homepage_url: "https://isabelle.in.tum.de",
      package: [
        licenses: ["MIT"],
        files: [
          "lib",
          "priv",
          "livebook_examples",
          "mix.exs",
          "README.md",
          "CHANGELOG.md",
          "LICENSE"
        ],
        links: %{
          "GitHub" => "https://github.com/davfuenmayor/isabelle_elixir",
          "Isabelle" => "https://isabelle.in.tum.de"
        }
      ],
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "livebook_examples/Client.livemd",
          "livebook_examples/ClientShared.livemd",
          "livebook_examples/ClientRaw.livemd",
          "livebook_examples/Unification.livemd",
          "livebook_examples/TPTP.livemd"
        ],
        groups_for_extras: [
          Tutorials: ~r/livebook_examples\/.*/
        ],
        source_ref: "v0.4.0"
      ]
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
