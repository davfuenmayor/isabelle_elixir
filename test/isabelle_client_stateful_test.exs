defmodule IsabelleClientStatefulTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Session
  alias IsabelleClient.Task
  alias IsabelleClient.Protocol

  @tag timeout: 180_000
  test "stateful client can use and stop explicit sessions independently" do
    IsabelleTestSupport.with_server("stateful_multi_session", fn server ->
      assert {:ok, client} =
               IsabelleClient.connect(server["password"],
                 host: server["host"],
                 port: server["port"]
               )

      assert {:ok, client, %Task{status: :finished} = first_task} =
               IsabelleClient.start_session(
                 client,
                 [session: "HOL"],
                 IsabelleTestSupport.session_timeout()
               )

      first_session = IsabelleClient.session(first_task)
      assert %Session{id: first_id, tmp_dir: first_tmp_dir} = first_session
      assert client.session == first_session

      assert {:ok, client, %Task{status: :finished} = second_task} =
               IsabelleClient.start_session(
                 client,
                 [session: "HOL"],
                 IsabelleTestSupport.session_timeout()
               )

      second_session = IsabelleClient.session(second_task)
      assert %Session{id: second_id, tmp_dir: second_tmp_dir} = second_session
      assert first_id != second_id
      assert first_tmp_dir != second_tmp_dir
      assert client.session == second_session

      first_dir =
        IsabelleTestSupport.theory_dir("stateful_multi_first", ~s(lemma "x = x"\n  by simp))

      second_dir =
        IsabelleTestSupport.theory_dir(
          "stateful_multi_second",
          ~s(lemma "xs @ [] = xs"\n  by simp)
        )

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = first_use} =
               IsabelleClient.use_theories(
                 client,
                 [session_id: first_session.id, theories: ["Example"], master_dir: first_dir],
                 IsabelleTestSupport.session_timeout()
               )

      assert_messages_contain(first_use, "theorem ?x = ?x")

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = first_text} =
               IsabelleClient.check_text(
                 client,
                 "ExplicitScratch",
                 ~s(lemma "x = x"\n  by simp),
                 [session_id: first_session.id],
                 IsabelleTestSupport.session_timeout()
               )

      assert_messages_contain(first_text, "theorem ?x = ?x")

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = second_use} =
               IsabelleClient.use_theories(
                 client,
                 [theories: ["Example"], master_dir: second_dir],
                 IsabelleTestSupport.session_timeout()
               )

      assert_messages_contain(second_use, "theorem ?xs @ [] = ?xs")

      assert {:ok, client, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.stop_session(
                 client,
                 first_session,
                 IsabelleTestSupport.session_timeout()
               )

      assert client.session_id == second_id
      assert client.session == second_session

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = second_use_again} =
               IsabelleClient.use_theories(
                 client,
                 [theories: ["Example"], master_dir: second_dir],
                 IsabelleTestSupport.session_timeout()
               )

      assert_messages_contain(second_use_again, "theorem ?xs @ [] = ?xs")

      assert {:ok, client, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.stop_session(client, IsabelleTestSupport.session_timeout())

      assert client.session_id == nil
      assert client.session == nil

      assert {:ok, nil} = IsabelleClient.shutdown_server(client)
      assert :ok = IsabelleClient.close(client)
    end)
  end

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

      assert_example_messages(use_task)

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = check_file_task} =
               IsabelleClient.check_file(
                 client,
                 Path.join(theory_dir, "Example.thy"),
                 [],
                 IsabelleTestSupport.session_timeout()
               )

      assert_example_messages(check_file_task)

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = check_text_task} =
               IsabelleClient.check_text(
                 client,
                 "Scratch",
                 ~s(lemma "x = x"\n  sledgehammer\n  by simp\n\nlemma "xs @ [] = xs"\n  sledgehammer\n  by simp),
                 [],
                 IsabelleTestSupport.session_timeout()
               )

      assert_example_messages(check_text_task)

      [%{"pos" => %{"offset" => proof_offset}} | _] =
        IsabelleClient.diagnostics(check_text_task, line: 6)

      proof_at_offset =
        check_text_task
        |> IsabelleClient.messages(line: 6, offset: proof_offset)
        |> Enum.join("\n")

      assert proof_at_offset =~ "theorem ?x = ?x"

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
        {:ok, command} = IsabelleTestSupport.recv_line(socket)
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

  defp assert_example_messages(task) do
    assert_messages_contain(task, "Sledgehammering", line: 5)
    assert_messages_contain(task, "theorem ?x = ?x", line: 6)
    assert_messages_contain(task, "Sledgehammering", line: 9)
    assert_messages_contain(task, "theorem ?xs @ [] = ?xs", line: 10)
  end

  defp assert_messages_contain(task, expected, opts \\ []) do
    assert task
           |> IsabelleClient.messages(opts)
           |> Enum.join("\n")
           |> String.contains?(expected)
  end
end
