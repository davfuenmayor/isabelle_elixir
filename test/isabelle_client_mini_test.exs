defmodule IsabelleClientMiniTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Task

  @tag timeout: 180_000
  test "minimal socket client exercises server lifecycle, commands, tasks, theories, and shutdown" do
    IsabelleTestSupport.with_server("mini", fn server ->
      assert {:ok, servers} = IsabelleClientMini.list_servers()
      assert Enum.any?(servers, &(&1["password"] == server["password"]))

      assert {:ok, socket} =
               IsabelleClientMini.connect(server["password"], server["host"], server["port"])

      assert {:ok, commands} = IsabelleClientMini.help(socket)
      IsabelleTestSupport.assert_commands(commands)

      assert {:ok, %{"client" => "mini", "n" => 1}} =
               IsabelleClientMini.command(socket, "echo", %{"client" => "mini", "n" => 1})

      assert {:ok, "plain string"} = IsabelleClientMini.echo(socket, "plain string")

      assert {:ok, nil} =
               IsabelleClientMini.cancel_task(socket, "00000000-0000-0000-0000-000000000000")

      assert {:ok, build_task} = IsabelleClientMini.build_session(socket, %{"session" => "HOL"})

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClientMini.await_task(
                 socket,
                 build_task,
                 IsabelleTestSupport.session_timeout()
               )

      assert {:ok, start_task} = IsabelleClientMini.start_session(socket, %{"session" => "HOL"})

      assert {:ok, %Task{status: :finished} = start_task} =
               IsabelleClientMini.poll_status(
                 socket,
                 start_task,
                 IsabelleTestSupport.session_timeout()
               )

      session_id = IsabelleClientMini.extract_session(start_task)
      assert is_binary(session_id)

      theory_dir = IsabelleTestSupport.theory_dir("mini")

      assert {:ok, use_task} =
               IsabelleClientMini.use_theories(socket, %{
                 "session_id" => session_id,
                 "theories" => ["Example"],
                 "master_dir" => theory_dir
               })

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = use_task} =
               IsabelleClientMini.await_task(
                 socket,
                 use_task,
                 IsabelleTestSupport.session_timeout()
               )

      assert IsabelleClientMini.extract_results(use_task) =~ "theorem ?x = ?x"

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               IsabelleClientMini.purge_theories(socket, %{
                 "session_id" => session_id,
                 "theories" => ["Example"],
                 "master_dir" => theory_dir
               })

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, stop_task} = IsabelleClientMini.stop_session(socket, session_id)

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClientMini.await_task(
                 socket,
                 stop_task,
                 IsabelleTestSupport.session_timeout()
               )

      assert {:ok, nil} = IsabelleClientMini.shutdown_server(socket)
      assert :ok = IsabelleClientMini.close(socket)
    end)
  end
end
