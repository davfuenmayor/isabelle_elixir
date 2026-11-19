defmodule IsabelleClient.FilesTest do
  use ExUnit.Case, async: true

  test "local placement into a non-active session uses its own directory" do
    root = Path.join(System.tmp_dir!(), "client_files_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    first = %IsabelleClient.Session{id: "first", tmp_dir: Path.join(root, "first")}
    second = %IsabelleClient.Session{id: "second", tmp_dir: Path.join(root, "second")}
    client = %IsabelleClient{sessions: [second, first]}

    assert {:ok, path} =
             IsabelleClient.write_file(client, "Example.thy", "source", session_id: first.id)

    assert path == Path.join(first.tmp_dir, "Example.thy")
    assert File.read!(path) == "source"
    refute File.exists?(second.tmp_dir)
  end
end
