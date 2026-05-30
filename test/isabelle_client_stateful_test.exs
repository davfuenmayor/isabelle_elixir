defmodule IsabelleClientStatefulTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Session
  alias IsabelleClient.Task
  alias IsabelleClient.Protocol

  test "forget_session only updates the local session stack" do
    first = %Session{id: "first", tmp_dir: "/tmp/first"}
    second = %Session{id: "second", tmp_dir: "/tmp/second"}
    third = %Session{id: "third", tmp_dir: "/tmp/third"}
    client = %IsabelleClient{sessions: [third, second, first]}

    assert IsabelleClient.forget_session(client, second).sessions == [third, first]
    assert IsabelleClient.forget_session(client, "third").sessions == [second, first]
    assert IsabelleClient.forget_session(client, "missing").sessions == [third, second, first]
  end

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
                 [session: "HOL", label: "main"],
                 IsabelleTestSupport.session_timeout()
               )

      first_session = Session.from_result(first_task.result, %{"session" => "HOL"}, "main")
      assert %Session{id: first_id, tmp_dir: first_tmp_dir} = first_session
      assert IsabelleClient.active_session(client) == first_session
      assert client.sessions == [first_session]
      assert IsabelleClient.sessions(client) == [first_session]

      assert {:ok, client, %Task{status: :finished} = second_task} =
               IsabelleClient.start_session(
                 client,
                 [session: "HOL"],
                 IsabelleTestSupport.session_timeout()
               )

      second_session = Session.from_result(second_task.result, %{"session" => "HOL"})
      assert %Session{id: second_id, tmp_dir: second_tmp_dir} = second_session
      assert first_id != second_id
      assert first_tmp_dir != second_tmp_dir
      assert IsabelleClient.active_session(client) == second_session
      assert client.sessions == [second_session, first_session]
      assert IsabelleClient.sessions(client) == [second_session, first_session]

      assert {:ok, client, %Task{status: :finished} = third_task} =
               IsabelleClient.start_session(
                 client,
                 [session: "HOL"],
                 IsabelleTestSupport.session_timeout()
               )

      third_session = Session.from_result(third_task.result, %{"session" => "HOL"})
      assert %Session{id: third_id, tmp_dir: third_tmp_dir} = third_session
      assert third_id not in [first_id, second_id]
      assert third_tmp_dir not in [first_tmp_dir, second_tmp_dir]
      assert IsabelleClient.active_session(client) == third_session
      assert IsabelleClient.sessions(client) == [third_session, second_session, first_session]

      first_dir =
        IsabelleTestSupport.theory_dir("stateful_multi_first", ~s(lemma "x = x"\n  by simp))

      second_dir =
        IsabelleTestSupport.theory_dir(
          "stateful_multi_second",
          ~s(lemma "xs @ [] = xs"\n  by simp)
        )

      third_dir =
        IsabelleTestSupport.theory_dir(
          "stateful_multi_third",
          ~s|lemma "(A \\<longrightarrow> A) \\<and> True"\n  by simp|
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
                 [session_id: second_session.id, theories: ["Example"], master_dir: second_dir],
                 IsabelleTestSupport.session_timeout()
               )

      assert_messages_contain(second_use, "theorem ?xs @ [] = ?xs")

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = third_use} =
               IsabelleClient.use_theories(
                 client,
                 [theories: ["Example"], master_dir: third_dir],
                 IsabelleTestSupport.session_timeout()
               )

      assert_messages_contain(third_use, "theorem (?A \\<longrightarrow> ?A) \\<and> True")

      assert {:ok, client, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.stop_session(client, IsabelleTestSupport.session_timeout())

      assert IsabelleClient.active_session(client).id == second_id
      assert IsabelleClient.active_session(client) == second_session
      assert IsabelleClient.sessions(client) == [second_session, first_session]

      assert {:ok, client, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.stop_session(
                 client,
                 first_session,
                 IsabelleTestSupport.session_timeout()
               )

      assert IsabelleClient.active_session(client).id == second_id
      assert IsabelleClient.active_session(client) == second_session
      assert IsabelleClient.sessions(client) == [second_session]

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = second_use_again} =
               IsabelleClient.use_theories(
                 client,
                 [theories: ["Example"], master_dir: second_dir],
                 IsabelleTestSupport.session_timeout()
               )

      assert_messages_contain(second_use_again, "theorem ?xs @ [] = ?xs")

      assert {:ok, client, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.stop_session(client, IsabelleTestSupport.session_timeout())

      assert IsabelleClient.active_session(client) == nil
      assert IsabelleClient.sessions(client) == []

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

      assert %IsabelleClient{sessions: []} = client
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

      assert %Session{} = active_session = IsabelleClient.active_session(client)
      assert is_binary(active_session.id)
      assert is_binary(active_session.tmp_dir)
      assert active_session.args == %{"session" => "HOL"}
      assert active_session.label == nil
      assert start_task.result["session_id"] == active_session.id

      theory_text =
        ~s(lemma "x = x"\n  sledgehammer\n  by simp\n\nlemma "xs @ [] = xs"\n  sledgehammer\n  by simp)

      theory_dir = IsabelleTestSupport.theory_dir("stateful", theory_text)

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

      assert_check_text_messages(check_text_task)

      [%{"pos" => %{"offset" => proof_offset}} | _] =
        IsabelleClient.diagnostics(check_text_task, line: 4)

      proof_at_offset =
        check_text_task
        |> IsabelleClient.messages(line: 4, offset: proof_offset)
        |> Enum.join("\n")

      assert proof_at_offset =~ "theorem ?x = ?x"

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = offset_task} =
               IsabelleClient.check_text(
                 client,
                 "OffsetFiltering",
                 ~s(lemma "x = x" by simp lemma "xs @ [] = xs" by simp),
                 [],
                 IsabelleTestSupport.session_timeout()
               )

      line_2_messages = IsabelleClient.messages(offset_task, line: 2)
      assert Enum.any?(line_2_messages, &String.contains?(&1, "theorem ?x = ?x"))
      assert Enum.any?(line_2_messages, &String.contains?(&1, "theorem ?xs @ [] = ?xs"))

      first_offset = diagnostic_offset(offset_task, "theorem ?x = ?x")
      second_offset = diagnostic_offset(offset_task, "theorem ?xs @ [] = ?xs")

      first_at_offset = IsabelleClient.messages(offset_task, line: 2, offset: first_offset)
      second_at_offset = IsabelleClient.messages(offset_task, line: 2, offset: second_offset)

      assert Enum.any?(first_at_offset, &String.contains?(&1, "theorem ?x = ?x"))
      refute Enum.any?(first_at_offset, &String.contains?(&1, "theorem ?xs @ [] = ?xs"))
      assert Enum.any?(second_at_offset, &String.contains?(&1, "theorem ?xs @ [] = ?xs"))
      refute Enum.any?(second_at_offset, &String.contains?(&1, "theorem ?x = ?x"))

      file_filter_dir =
        IsabelleTestSupport.theory_set_dir("stateful_file_filter", [
          {"FileFilterOne", ~s(lemma "x = x"\n  by simp), "theorem ?x = ?x"},
          {"FileFilterTwo", ~s(lemma "xs @ [] = xs"\n  by simp), "theorem ?xs @ [] = ?xs"}
        ])

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = file_filter_task} =
               IsabelleClient.use_theories(
                 client,
                 [theories: ["FileFilterOne", "FileFilterTwo"], master_dir: file_filter_dir],
                 IsabelleTestSupport.session_timeout()
               )

      one_file = diagnostic_file(file_filter_task, "theorem ?x = ?x")
      two_file = diagnostic_file(file_filter_task, "theorem ?xs @ [] = ?xs")
      assert is_binary(one_file)
      assert is_binary(two_file)
      assert one_file != two_file

      one_messages = IsabelleClient.messages(file_filter_task, file: one_file)
      two_messages = IsabelleClient.messages(file_filter_task, file: two_file)

      assert Enum.any?(one_messages, &String.contains?(&1, "theorem ?x = ?x"))
      refute Enum.any?(one_messages, &String.contains?(&1, "theorem ?xs @ [] = ?xs"))
      assert Enum.any?(two_messages, &String.contains?(&1, "theorem ?xs @ [] = ?xs"))
      refute Enum.any?(two_messages, &String.contains?(&1, "theorem ?x = ?x"))

      complete_theory = """
      theory CompleteTextExample imports Main begin

      lemma "x = x"
        by simp

      end
      """

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = complete_task} =
               IsabelleClient.check_text(
                 client,
                 "CompleteTextExample",
                 complete_theory,
                 [],
                 IsabelleTestSupport.session_timeout()
               )

      assert File.read!(Path.join(active_session.tmp_dir, "CompleteTextExample.thy")) ==
               complete_theory

      assert_messages_contain(complete_task, "theorem ?x = ?x", line: 4)

      broken_result =
        IsabelleClient.check_text(
          client,
          "BrokenExample",
          ~s(lemma "x = y"\n  by simp),
          [],
          IsabelleTestSupport.session_timeout()
        )

      {result_tag, broken_task} = broken_result

      assert result_tag in [:ok, :error]
      assert %Task{status: :finished, result: %{"ok" => false}} = broken_task
      assert IsabelleClient.errors(broken_task) != []
      assert IsabelleClient.errors(broken_task, line: 3) != []

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               IsabelleClient.purge_theories(client,
                 theories: ["Example"],
                 master_dir: theory_dir
               )

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, client, %Task{status: :finished, result: %{"ok" => true}}} =
               IsabelleClient.stop_session(client, IsabelleTestSupport.session_timeout())

      assert IsabelleClient.active_session(client) == nil
      assert client.sessions == []

      assert {:ok, nil} = IsabelleClient.shutdown_server(client)
      assert :ok = IsabelleClient.close(client)
    end)
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
    client = %IsabelleClient{socket: socket, sessions: [%Session{id: "session-1"}]}

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

  defp assert_check_text_messages(task) do
    assert_messages_contain(task, "Sledgehammering", line: 3)
    assert_messages_contain(task, "theorem ?x = ?x", line: 4)
    assert_messages_contain(task, "Sledgehammering", line: 7)
    assert_messages_contain(task, "theorem ?xs @ [] = ?xs", line: 8)
  end

  defp assert_messages_contain(task, expected, opts \\ []) do
    assert task
           |> IsabelleClient.messages(opts)
           |> Enum.join("\n")
           |> String.contains?(expected)
  end

  defp diagnostic_offset(task, text) do
    diagnostic_pos(task, text, "offset", line: 2)
  end

  defp diagnostic_file(task, text) do
    diagnostic_pos(task, text, "file")
  end

  defp diagnostic_pos(task, text, field, opts \\ []) do
    task
    |> IsabelleClient.diagnostics(opts)
    |> Enum.find_value(fn diagnostic ->
      if String.contains?(diagnostic["message"], text) do
        get_in(diagnostic, ["pos", field])
      end
    end)
  end
end
