defmodule IsabelleClient.RawTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Raw
  alias IsabelleClient.Task

  @tag timeout: 180_000
  test "raw socket client exercises server lifecycle, commands, tasks, theories, and shutdown" do
    IsabelleTestSupport.with_server("raw", fn server ->
      assert {:ok, servers} = Raw.list_servers()
      assert Enum.any?(servers, &(&1["password"] == server["password"]))

      assert {:ok, socket} =
               Raw.connect(server["password"], server["host"], server["port"])

      assert {:ok, commands} = Raw.help(socket)
      IsabelleTestSupport.assert_commands(commands)

      assert {:ok, %{"client" => "raw", "n" => 1}} =
               Raw.command(socket, "echo", client: "raw", n: 1)

      assert {:ok, "plain string"} = Raw.echo(socket, "plain string")

      assert {:ok, nil} =
               Raw.cancel_task(socket, "00000000-0000-0000-0000-000000000000")

      assert {:ok, build_task} = Raw.build_session(socket, session: "HOL")
      assert_finished(socket, build_task)

      assert {:ok, start_task} = Raw.start_session(socket, session: "HOL")
      assert {:ok, %Task{status: :finished} = start_task} = await(socket, start_task)

      session_id = IsabelleClient.extract_session(start_task)
      assert is_binary(session_id)

      theory_dir = IsabelleTestSupport.theory_dir("raw")

      assert {:ok, use_task} =
               Raw.use_theories(socket,
                 session_id: session_id,
                 theories: ["Example"],
                 master_dir: theory_dir
               )

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = use_task} =
               await(socket, use_task)

      assert Enum.join(IsabelleClient.messages(use_task), "\n") =~ "theorem ?x = ?x"

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               Raw.purge_theories(socket,
                 session_id: session_id,
                 theories: ["Example"],
                 master_dir: theory_dir
               )

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, stop_task} = Raw.stop_session(socket, session_id)

      assert_finished(socket, stop_task)

      assert {:ok, nil} = Raw.shutdown_server(socket)
      assert :ok = Raw.close(socket)
    end)
  end

  defp assert_finished(socket, task) do
    assert {:ok, %Task{status: :finished, result: %{"ok" => true}}} = await(socket, task)
  end

  defp await(socket, task) do
    Raw.await_task(socket, task, IsabelleTestSupport.session_timeout())
  end
end
