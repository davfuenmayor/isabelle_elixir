defmodule IsabelleClientStatefulTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Task

  @tag timeout: 180_000
  test "stateful client tracks sessions and exercises convenience APIs" do
    IsabelleTestSupport.with_server("stateful", fn server ->
      assert {:ok, client} =
               IsabelleClient.connect(server["password"],
                 host: server["host"],
                 port: server["port"]
               )

      assert %IsabelleClient{session_id: nil} = client
      assert {:error, :no_session} = IsabelleClient.use_theories(client)
      assert {:error, :no_session} = IsabelleClient.purge_theories(client)
      assert {:error, :no_session} = IsabelleClient.stop_session(client)

      assert {:ok, commands} = IsabelleClient.help(client)
      IsabelleTestSupport.assert_commands(commands)

      assert {:ok, %{"client" => "stateful"}} =
               IsabelleClient.command(client, "echo", %{"client" => "stateful"})

      assert {:ok, "stateful string"} = IsabelleClient.echo(client, "stateful string")

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.build_session(
                 client,
                 %{"session" => "HOL"},
                 IsabelleTestSupport.session_timeout()
               )

      assert {:ok, client, %Task{status: :finished} = start_task} =
               IsabelleClient.start_session(
                 client,
                 %{"session" => "HOL"},
                 IsabelleTestSupport.session_timeout()
               )

      assert is_binary(client.session_id)
      assert start_task.result["session_id"] == client.session_id

      theory_dir = IsabelleTestSupport.theory_dir("stateful")

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = use_task} =
               IsabelleClient.use_theories(
                 client,
                 %{"theories" => ["Example"], "master_dir" => theory_dir},
                 IsabelleTestSupport.session_timeout()
               )

      assert IsabelleClientMini.extract_results(use_task) =~ "theorem ?x = ?x"

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               IsabelleClient.purge_theories(client, %{
                 "theories" => ["Example"],
                 "master_dir" => theory_dir
               })

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, client, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.stop_session(client, IsabelleTestSupport.session_timeout())

      assert client.session_id == nil

      assert {:ok, nil} = IsabelleClient.shutdown_server(client)
      assert :ok = IsabelleClient.close(client)
    end)
  end
end
