isabelle_bin = Path.expand("../../Isabelle2025-2/bin", __DIR__)

if File.exists?(Path.join(isabelle_bin, "isabelle")) do
  System.put_env("PATH", isabelle_bin <> ":" <> System.get_env("PATH", ""))
end

ExUnit.start()

defmodule IsabelleTestSupport do
  import ExUnit.Assertions

  @session_timeout 120_000

  def session_timeout, do: @session_timeout

  def isabelle_available? do
    System.find_executable("isabelle") != nil
  end

  def with_server(test, fun) do
    if isabelle_available?() do
      name = "elixir_test_#{test}_#{System.unique_integer([:positive])}"
      {:ok, [server]} = IsabelleClientMini.new_server(name, 0)

      try do
        fun.(server)
      after
        IsabelleClientMini.kill_server(name)
      end
    else
      flunk("isabelle executable not found on PATH")
    end
  end

  def theory_dir(name, theorem \\ ~s(theorem "x = x"\n  by simp)) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "isabelle_elixir_#{name}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "Example.thy"), """
    theory Example imports Main
    begin

    #{theorem}

    end
    """)

    dir
  end

  def assert_commands(commands) do
    for command <-
          ~w(cancel echo help purge_theories session_build session_start session_stop shutdown use_theories) do
      assert command in commands
    end
  end
end
