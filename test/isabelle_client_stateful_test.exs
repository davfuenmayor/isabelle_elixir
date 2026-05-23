defmodule IsabelleClientStatefulTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Task
  alias IsabelleClient.Protocol

  @tag timeout: 180_000
  test "stateful client tracks sessions and exercises convenience APIs" do
    IsabelleTestSupport.with_server("stateful", fn server ->
      assert {:ok, client} =
               IsabelleClient.connect(server["password"],
                 host: server["host"],
                 port: server["port"]
               )

      assert %IsabelleClient{session_id: nil, tmp_dir: nil} = client
      assert {:error, :no_session} = IsabelleClient.use_theories(client)
      assert {:error, :no_session} = IsabelleClient.purge_theories(client)
      assert {:error, :no_session} = IsabelleClient.stop_session(client)

      assert {:ok, commands} = IsabelleClient.help(client)
      IsabelleTestSupport.assert_commands(commands)

      assert {:ok, %{"client" => "stateful"}} =
               IsabelleClient.command(client, "echo", client: "stateful")

      assert {:ok, "stateful string"} = IsabelleClient.echo(client, "stateful string")

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.build_session(
                 client,
                 [session: "HOL"],
                 IsabelleTestSupport.session_timeout()
               )

      assert {:ok, client, %Task{status: :finished} = start_task} =
               IsabelleClient.start_session(
                 client,
                 [session: "HOL"],
                 IsabelleTestSupport.session_timeout()
               )

      assert is_binary(client.session_id)
      assert is_binary(client.tmp_dir)
      assert start_task.result["session_id"] == client.session_id

      theory_dir =
        IsabelleTestSupport.theory_dir("stateful", """
        lemma "x = x"
          sledgehammer
          by simp

        lemma "xs @ [] = xs"
          sledgehammer
          by simp
        """)

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = use_task} =
               IsabelleClient.use_theories(
                 client,
                 [theories: ["Example"], master_dir: theory_dir],
                 IsabelleTestSupport.session_timeout()
               )

      use_line_5 = Enum.join(IsabelleClient.messages(use_task, line: 5), "\n")
      use_line_6 = Enum.join(IsabelleClient.messages(use_task, line: 6), "\n")
      use_line_9 = Enum.join(IsabelleClient.messages(use_task, line: 9), "\n")
      use_line_10 = Enum.join(IsabelleClient.messages(use_task, line: 10), "\n")

      assert use_line_5 =~ "Sledgehammering"
      assert use_line_6 =~ "theorem ?x = ?x"
      assert use_line_9 =~ "Sledgehammering"
      assert use_line_10 =~ "theorem ?xs @ [] = ?xs"

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = check_file_task} =
               IsabelleClient.check_file(
                 client,
                 Path.join(theory_dir, "Example.thy"),
                 [],
                 IsabelleTestSupport.session_timeout()
               )

      file_line_5 = Enum.join(IsabelleClient.messages(check_file_task, line: 5), "\n")
      file_line_6 = Enum.join(IsabelleClient.messages(check_file_task, line: 6), "\n")
      file_line_9 = Enum.join(IsabelleClient.messages(check_file_task, line: 9), "\n")
      file_line_10 = Enum.join(IsabelleClient.messages(check_file_task, line: 10), "\n")

      assert file_line_5 =~ "Sledgehammering"
      assert file_line_6 =~ "theorem ?x = ?x"
      assert file_line_9 =~ "Sledgehammering"
      assert file_line_10 =~ "theorem ?xs @ [] = ?xs"

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = check_text_task} =
               IsabelleClient.check_text(
                 client,
                 "Scratch",
                 ~s(lemma "x = x"\n  sledgehammer\n  by simp\n\nlemma "xs @ [] = xs"\n  sledgehammer\n  by simp),
                 [],
                 IsabelleTestSupport.session_timeout()
               )

      text_line_5 = Enum.join(IsabelleClient.messages(check_text_task, line: 5), "\n")
      text_line_6 = Enum.join(IsabelleClient.messages(check_text_task, line: 6), "\n")
      text_line_9 = Enum.join(IsabelleClient.messages(check_text_task, line: 9), "\n")
      text_line_10 = Enum.join(IsabelleClient.messages(check_text_task, line: 10), "\n")

      assert text_line_5 =~ "Sledgehammering"
      assert text_line_6 =~ "theorem ?x = ?x"
      assert text_line_9 =~ "Sledgehammering"
      assert text_line_10 =~ "theorem ?xs @ [] = ?xs"

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               IsabelleClient.purge_theories(client,
                 theories: ["Example"],
                 master_dir: theory_dir
               )

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, client, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.stop_session(client, IsabelleTestSupport.session_timeout())

      assert client.session_id == nil
      assert client.tmp_dir == nil

      assert {:ok, nil} = IsabelleClient.shutdown_server(client)
      assert :ok = IsabelleClient.close(client)
    end)
  end

  @tag timeout: 180_000
  test "with_session starts and cleans up a local session" do
    name = "elixir_test_with_session_#{System.unique_integer([:positive])}"

    assert {:ok, "ok"} =
             IsabelleClient.with_session(
               [
                 server_name: name,
                 session: "HOL",
                 timeout: IsabelleTestSupport.session_timeout()
               ],
               fn client ->
                 assert is_binary(client.session_id)
                 IsabelleClient.echo(client, "ok")
               end
             )
  end

  test "use_theories treats nil args as an empty argument map for an active session" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, command} = recv_line(socket)
        send(parent, {:command, command})

        :ok = :gen_tcp.send(socket, Protocol.command("OK", %{"task" => "task-1"}))

        :ok =
          :gen_tcp.send(socket, Protocol.command("FINISHED", %{"task" => "task-1", "ok" => true}))

        :gen_tcp.close(socket)
      end)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    client = %IsabelleClient{socket: socket, session_id: "session-1"}

    assert {:ok, %Task{status: :finished, result: %{"ok" => true}}} =
             IsabelleClient.use_theories(client, nil, 1_000)

    assert_receive {:command, "use_theories {\"session_id\":\"session-1\"}"}

    :gen_tcp.close(socket)
    :gen_tcp.close(listen)
    ref = Process.monitor(server)
    assert_receive {:DOWN, ^ref, :process, ^server, _}
  end

  defp recv_line(socket, acc \\ []) do
    case :gen_tcp.recv(socket, 1, 1_000) do
      {:ok, "\n"} -> {:ok, IO.iodata_to_binary(acc)}
      {:ok, byte} -> recv_line(socket, [acc, byte])
      {:error, reason} -> {:error, reason}
    end
  end
end
