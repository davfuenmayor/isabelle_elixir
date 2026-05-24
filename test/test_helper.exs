isabelle_bin = Path.expand("../../Isabelle2025-2/bin", __DIR__)
isabelle_tool = Path.join(isabelle_bin, "isabelle")

if File.exists?(isabelle_tool) do
  System.put_env("ISABELLE_TOOL", isabelle_tool)
end

ExUnit.start()

defmodule IsabelleTestSupport do
  import ExUnit.Assertions

  @session_timeout 120_000

  def session_timeout, do: @session_timeout

  def isabelle_available? do
    match?({:ok, _}, IsabelleClient.Server.executable())
  end

  def with_server(test, fun) do
    if isabelle_available?() do
      name = "elixir_test_#{test}_#{System.unique_integer([:positive])}"
      {:ok, [server]} = IsabelleClient.new_server(name, 0)

      try do
        fun.(server)
      after
        IsabelleClient.kill_server(name)
      end
    else
      flunk("isabelle executable not found; set ISABELLE_TOOL or add isabelle to PATH")
    end
  end

  def theory_dir(name, theorem \\ ~s(theorem "x = x"\n  by simp)) do
    dir = tmp_dir(name)

    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "Example.thy"), """
    theory Example imports Main
    begin

    #{theorem}

    end
    """)

    dir
  end

  def theory_set_dir(name, theories) do
    dir = tmp_dir(name)
    File.mkdir_p!(dir)
    write_theories!(dir, theories)
    dir
  end

  def write_theories!(dir, theories) do
    for {theory, body, _expected} <- theories do
      File.write!(Path.join(dir, "#{theory}.thy"), """
      theory #{theory} imports Main
      begin

      #{body}

      end
      """)
    end

    dir
  end

  def assert_commands(commands) do
    for command <-
          ~w(cancel echo help purge_theories session_build session_start session_stop shutdown use_theories) do
      assert command in commands
    end
  end

  def recv_line(socket, acc \\ []) do
    case :gen_tcp.recv(socket, 1, 1_000) do
      {:ok, "\n"} -> {:ok, IO.iodata_to_binary(acc)}
      {:ok, byte} -> recv_line(socket, [acc, byte])
      {:error, reason} -> {:error, reason}
    end
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "isabelle_elixir_#{name}_#{System.unique_integer([:positive])}")
  end
end
