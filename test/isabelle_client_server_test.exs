defmodule IsabelleClientServerTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Server

  setup do
    env = [{"ISABELLE_TOOL", System.get_env("ISABELLE_TOOL")}, {"PATH", System.get_env("PATH")}]
    on_exit(fn -> Enum.each(env, fn {key, value} -> restore_env(key, value) end) end)
  end

  test "executable uses ISABELLE_TOOL, falls back to PATH, and reports missing tools" do
    System.put_env("ISABELLE_TOOL", "/tmp/custom-isabelle")
    assert Server.executable() == {:ok, "/tmp/custom-isabelle"}

    System.delete_env("ISABELLE_TOOL")
    tool = fake_isabelle!()
    System.put_env("PATH", Path.dirname(tool))

    assert Server.executable() == {:ok, tool}
    assert System.get_env("ISABELLE_TOOL") == tool

    System.delete_env("ISABELLE_TOOL")
    System.put_env("PATH", empty_dir!())

    assert Server.executable() == {:error, :isabelle_not_found}
    assert System.get_env("ISABELLE_TOOL") == nil
  end

  defp fake_isabelle! do
    tool = Path.join(empty_dir!(), "isabelle")
    File.write!(tool, "#!/bin/sh\n")
    File.chmod!(tool, 0o755)
    tool
  end

  defp empty_dir! do
    dir =
      Path.join(System.tmp_dir!(), "isabelle_elixir_tool_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    dir
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
