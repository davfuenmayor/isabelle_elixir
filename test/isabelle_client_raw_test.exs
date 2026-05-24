defmodule IsabelleClientRawTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Task

  @tag timeout: 180_000
  test "raw socket client exercises server lifecycle, commands, tasks, theories, and shutdown" do
    IsabelleTestSupport.with_server("raw", fn server ->
      assert {:ok, servers} = IsabelleClient.list_servers()
      assert Enum.any?(servers, &(&1["password"] == server["password"]))

      assert {:ok, socket} =
               IsabelleClient.connect_socket(server["password"], server["host"], server["port"])

      assert {:ok, commands} = IsabelleClient.help(socket)
      IsabelleTestSupport.assert_commands(commands)

      assert {:ok, %{"client" => "raw", "n" => 1}} =
               IsabelleClient.command(socket, "echo", client: "raw", n: 1)

      assert {:ok, "plain string"} = IsabelleClient.echo(socket, "plain string")

      assert {:ok, nil} =
               IsabelleClient.cancel_task(socket, "00000000-0000-0000-0000-000000000000")

      assert {:ok, build_task} = IsabelleClient.build_session(socket, session: "HOL")
      assert_finished(socket, build_task)

      assert {:ok, start_task} = IsabelleClient.start_session(socket, session: "HOL")
      assert {:ok, %Task{status: :finished} = start_task} = await(socket, start_task)

      session_id = IsabelleClient.extract_session(start_task)
      assert is_binary(session_id)

      theory_dir = IsabelleTestSupport.theory_dir("raw")

      assert {:ok, use_task} =
               IsabelleClient.use_theories(socket,
                 session_id: session_id,
                 theories: ["Example"],
                 master_dir: theory_dir
               )

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = use_task} =
               await(socket, use_task)

      assert Enum.join(IsabelleClient.messages(use_task), "\n") =~ "theorem ?x = ?x"

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               IsabelleClient.purge_theories(socket,
                 session_id: session_id,
                 theories: ["Example"],
                 master_dir: theory_dir
               )

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, stop_task} = IsabelleClient.stop_session(socket, session_id)

      assert_finished(socket, stop_task)

      assert {:ok, nil} = IsabelleClient.shutdown_server(socket)
      assert :ok = IsabelleClient.close(socket)
    end)
  end

  defp assert_finished(socket, task) do
    assert {:ok, %Task{status: :finished, result: %{"ok" => true}}} = await(socket, task)
  end

  defp await(socket, task) do
    IsabelleClient.await_task(socket, task, IsabelleTestSupport.session_timeout())
  end
end
