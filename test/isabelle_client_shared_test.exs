defmodule IsabelleClient.SharedTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Protocol
  alias IsabelleClient.Session
  alias IsabelleClient.Shared
  alias IsabelleClient.Task, as: IsabelleTask

  test "command timeout is applied to the socket receive, not only GenServer.call" do
    {:ok, pid, server} =
      start_fake_authenticated_server(fn socket, parent ->
        {:ok, command} = IsabelleTestSupport.recv_line(socket)
        send(parent, {:command, command})
      end)

    assert {:error, :timeout} = Shared.command(pid, "help", nil, 50)
    assert_receive {:command, "help"}

    :ok = Shared.close(pid)
    assert_server_down(server)
  end

  test "async command timeout is applied while awaiting Isabelle task completion" do
    {:ok, pid, server} =
      start_fake_authenticated_server(fn socket, parent ->
        {:ok, command} = IsabelleTestSupport.recv_line(socket)
        send(parent, {:command, command})
        :ok = :gen_tcp.send(socket, Protocol.command("OK", %{"task" => "task-1"}))
      end)

    assert {:error, :timeout} = Shared.build_session(pid, %{"session" => "HOL"}, 50)
    assert_receive {:command, "session_build {\"session\":\"HOL\"}"}

    :ok = Shared.close(pid)
    assert_server_down(server)
  end

  test "concurrent async tasks are routed by task id with event callbacks" do
    parent = self()

    {:ok, pid, server} =
      start_fake_authenticated_server(fn socket, parent ->
        {:ok, first} = IsabelleTestSupport.recv_line(socket)
        send(parent, {:command, 1, first})
        :ok = :gen_tcp.send(socket, Protocol.command("OK", %{"task" => "task-1"}))

        {:ok, second} = IsabelleTestSupport.recv_line(socket)
        send(parent, {:command, 2, second})
        :ok = :gen_tcp.send(socket, Protocol.command("OK", %{"task" => "task-2"}))

        :ok =
          :gen_tcp.send(
            socket,
            Protocol.command("NOTE", %{"task" => "task-2", "message" => "second note"})
          )

        :ok =
          :gen_tcp.send(
            socket,
            Protocol.command("FINISHED", %{"task" => "task-2", "ok" => true, "name" => "second"})
          )

        :ok =
          :gen_tcp.send(
            socket,
            Protocol.command("NOTE", %{"task" => "task-1", "message" => "first note"})
          )

        :ok =
          :gen_tcp.send(
            socket,
            Protocol.command("FINISHED", %{"task" => "task-1", "ok" => true, "name" => "first"})
          )
      end)

    first =
      Elixir.Task.async(fn ->
        Shared.build_session(pid, [session: "First"], 1_000,
          on_event: fn event -> send(parent, {:event, :first, event}) end
        )
      end)

    assert_receive {:command, 1, "session_build {\"session\":\"First\"}"}

    second =
      Elixir.Task.async(fn ->
        Shared.build_session(pid, [session: "Second"], 1_000,
          on_event: fn event -> send(parent, {:event, :second, event}) end
        )
      end)

    assert_receive {:command, 2, "session_build {\"session\":\"Second\"}"}

    assert {:ok,
            %IsabelleTask{
              id: "task-2",
              result: %{"name" => "second"},
              notes: [%{"message" => "second note"}]
            }} =
             Elixir.Task.await(second)

    assert {:ok,
            %IsabelleTask{
              id: "task-1",
              result: %{"name" => "first"},
              notes: [%{"message" => "first note"}]
            }} =
             Elixir.Task.await(first)

    assert_receive {:event, :first, %{type: :started, task: "task-1"}}
    assert_receive {:event, :second, %{type: :started, task: "task-2"}}

    assert_receive {:event, :first,
                    %{type: :note, task: "task-1", body: %{"message" => "first note"}}}

    assert_receive {:event, :second,
                    %{type: :note, task: "task-2", body: %{"message" => "second note"}}}

    assert_receive {:event, :first,
                    %{type: :finished, task: "task-1", body: %{"name" => "first"}}}

    assert_receive {:event, :second,
                    %{type: :finished, task: "task-2", body: %{"name" => "second"}}}

    :ok = Shared.close(pid)
    assert_server_down(server)
  end

  test "async on_event receives failed task results" do
    parent = self()

    {:ok, pid, server} =
      start_fake_authenticated_server(fn socket, parent ->
        {:ok, command} = IsabelleTestSupport.recv_line(socket)
        send(parent, {:command, command})
        :ok = :gen_tcp.send(socket, Protocol.command("OK", %{"task" => "task-1"}))

        :ok =
          :gen_tcp.send(
            socket,
            Protocol.command("FAILED", %{"task" => "task-1", "message" => "bad"})
          )
      end)

    assert {:error, %IsabelleTask{status: :failed, result: %{"message" => "bad"}}} =
             Shared.build_session(pid, [session: "Broken"], 1_000,
               on_event: fn event -> send(parent, {:event, event}) end
             )

    assert_receive {:command, "session_build {\"session\":\"Broken\"}"}
    assert_receive {:event, %{type: :started, task: "task-1"}}
    assert_receive {:event, %{type: :failed, task: "task-1", body: %{"message" => "bad"}}}

    :ok = Shared.close(pid)
    assert_server_down(server)
  end

  @tag timeout: 180_000
  test "GenServer client routes concurrent tasks across explicit sessions" do
    IsabelleTestSupport.with_server("shared_multi_session", fn server ->
      assert {:ok, pid} =
               Shared.connect(
                 password: server["password"],
                 host: server["host"],
                 port: server["port"]
               )

      assert {:ok, %IsabelleTask{status: :finished} = first_task} =
               Shared.start_session(
                 pid,
                 [session: "HOL"],
                 IsabelleTestSupport.session_timeout()
               )

      assert %Session{id: first_id} = first_session = IsabelleClient.session(first_task)

      assert {:ok, %IsabelleTask{status: :finished} = second_task} =
               Shared.start_session(
                 pid,
                 [session: "HOL"],
                 IsabelleTestSupport.session_timeout()
               )

      assert %Session{id: second_id} = second_session = IsabelleClient.session(second_task)
      assert first_id != second_id

      first_dir =
        IsabelleTestSupport.theory_dir("shared_multi_first", ~s(lemma "x = x"\n  by simp))

      second_dir =
        IsabelleTestSupport.theory_dir(
          "shared_multi_second",
          ~s(lemma "xs @ [] = xs"\n  by simp)
        )

      parent = self()
      event_ref = make_ref()
      done_ref = make_ref()
      release_ref = make_ref()

      operations = [
        {:first, first_session.id, first_dir, "theorem ?x = ?x"},
        {:second, second_session.id, second_dir, "theorem ?xs @ [] = ?xs"}
      ]

      tasks =
        Enum.map(operations, fn {label, session_id, theory_dir, expected} ->
          Elixir.Task.async(fn ->
            receive do
              {:go, ^release_ref} -> :ok
            end

            on_event = fn
              %{type: :note, task: task, body: %{"message" => message}} ->
                send(parent, {:shared_multi_note, event_ref, label, task, message})

              _event ->
                :ok
            end

            assert {:ok, %IsabelleTask{status: :finished, result: %{"ok" => true}} = use_task} =
                     Shared.use_theories(
                       pid,
                       [session_id: session_id, theories: ["Example"], master_dir: theory_dir],
                       IsabelleTestSupport.session_timeout(),
                       on_event: on_event
                     )

            assert Enum.join(IsabelleClient.messages(use_task), "\n") =~ expected
            send(parent, {:shared_concurrent_result, done_ref, {label, use_task.id}})
          end)
        end)

      Enum.each(tasks, &send(&1.pid, {:go, release_ref}))
      results = collect_results(done_ref, 2, 120_000)
      Enum.each(tasks, &Elixir.Task.await(&1, 1_000))

      task_ids_by_label = Map.new(results)

      notes_by_label =
        event_ref
        |> drain_notes(:shared_multi_note)
        |> Enum.group_by(fn {label, _task_id, _message} -> label end)

      assert Map.keys(task_ids_by_label) |> Enum.sort() == [:first, :second]
      assert Map.keys(notes_by_label) |> Enum.sort() == [:first, :second]

      for {label, task_id} <- task_ids_by_label do
        assert Enum.all?(notes_by_label[label], fn {_label, note_task_id, _message} ->
                 note_task_id == task_id
               end)
      end

      assert {:ok, %IsabelleTask{status: :finished, result: %{"ok" => true}}} =
               Shared.stop_session(
                 pid,
                 first_session,
                 IsabelleTestSupport.session_timeout()
               )

      assert {:ok, %IsabelleTask{status: :finished, result: %{"ok" => true}} = active_task} =
               Shared.use_theories(
                 pid,
                 [theories: ["Example"], master_dir: second_dir],
                 IsabelleTestSupport.session_timeout()
               )

      assert Enum.join(IsabelleClient.messages(active_task), "\n") =~ "theorem ?xs @ [] = ?xs"

      assert {:ok, %IsabelleTask{status: :finished, result: %{"ok" => true}}} =
               Shared.stop_session(pid, IsabelleTestSupport.session_timeout())

      assert :ok = Shared.close(pid)
    end)
  end

  @tag timeout: 180_000
  test "GenServer client can start and clean up a local session" do
    name = "elixir_test_shared_local_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Shared.start_link(
               server_name: name,
               session: "HOL",
               timeout: IsabelleTestSupport.session_timeout()
             )

    assert {:ok, "ok"} = Shared.echo(pid, "ok")
    assert :ok = Shared.close(pid)
  end

  @tag timeout: 180_000
  test "GenServer client routes concurrent callers and exercises shared API" do
    IsabelleTestSupport.with_server("shared", fn server ->
      assert {:ok, pid} =
               Shared.connect(
                 password: server["password"],
                 host: server["host"],
                 port: server["port"]
               )

      assert Process.alive?(pid)

      assert {:error, :no_session} = Shared.use_theories(pid, %{})
      assert {:error, :no_session} = Shared.purge_theories(pid, %{})
      assert {:error, :no_session} = Shared.stop_session(pid)

      assert {:ok, commands} = Shared.help(pid)
      IsabelleTestSupport.assert_commands(commands)

      # This batch is the core Shared-client property. Each caller expects its
      # own unique response from one shared TCP connection. Sharing a raw socket
      # or stateful client directly across these tasks can let callers steal
      # each other's replies.
      parent = self()
      ref = make_ref()
      release_ref = make_ref()

      operations =
        (Enum.map(1..25, &{:echo, &1}) ++ Enum.map(1..5, &{:help, &1}))
        |> Enum.shuffle()

      concurrent_tasks =
        Enum.map(operations, fn operation ->
          Elixir.Task.async(fn ->
            receive do
              {:go, ^release_ref} -> :ok
            end

            case operation do
              {:echo, n} ->
                payload = %{
                  "client" => "shared",
                  "n" => n,
                  "token" => "token-#{n}",
                  "framed" => String.duplicate(Integer.to_string(rem(n, 10)), 160)
                }

                assert {:ok, ^payload} = Shared.echo(pid, payload)

              {:help, _n} ->
                assert {:ok, commands} = Shared.help(pid)
                IsabelleTestSupport.assert_commands(commands)
            end

            send(parent, {:shared_concurrent_result, ref, operation})
          end)
        end)

      Enum.each(concurrent_tasks, &send(&1.pid, {:go, release_ref}))

      concurrent_results = collect_results(ref, 30, 30_000)
      Enum.each(concurrent_tasks, &Elixir.Task.await(&1, 1_000))

      assert Enum.sort(concurrent_results) ==
               Enum.sort(Enum.map(1..25, &{:echo, &1}) ++ Enum.map(1..5, &{:help, &1}))

      assert {:ok, %IsabelleTask{status: :finished, result: %{"ok" => true}}} =
               Shared.build_session(
                 pid,
                 %{"session" => "HOL"},
                 IsabelleTestSupport.session_timeout()
               )

      assert {:ok, %IsabelleTask{status: :finished} = start_task} =
               Shared.start_session(
                 pid,
                 %{"session" => "HOL"},
                 IsabelleTestSupport.session_timeout()
               )

      assert is_binary(start_task.result["session_id"])

      assert {:ok, %{"phase" => "active_session"}} =
               Shared.echo(pid, %{"phase" => "active_session"})

      theories = [
        {"Example1", "lemma \"x = x\"\n  by simp", "theorem ?x = ?x"},
        {"Example2", "lemma \"xs @ [] = xs\"\n  by simp", "theorem ?xs @ [] = ?xs"},
        {"Example3", "lemma \"(A \\<longrightarrow> A) \\<and> True\"\n  by simp",
         "theorem (?A \\<longrightarrow> ?A) \\<and> True"}
      ]

      theory_dir = IsabelleTestSupport.theory_set_dir("shared", theories)

      event_ref = make_ref()
      theory_ref = make_ref()
      theory_release_ref = make_ref()

      theory_operations =
        Enum.map(theories, fn {theory, _body, expected_result} ->
          {:use_theories, theory, expected_result}
        end)

      theory_tasks =
        theory_operations
        |> Enum.shuffle()
        |> Enum.map(fn operation ->
          Elixir.Task.async(fn ->
            receive do
              {:go, ^theory_release_ref} -> :ok
            end

            result =
              case operation do
                {:use_theories, theory, expected_result} ->
                  on_event = fn
                    %{type: :note, task: task, body: %{"message" => message}} ->
                      send(parent, {:shared_theory_note, event_ref, theory, task, message})

                    _event ->
                      :ok
                  end

                  assert {:ok,
                          %IsabelleTask{status: :finished, result: %{"ok" => true}} = use_task} =
                           Shared.use_theories(
                             pid,
                             [theories: [theory], master_dir: theory_dir],
                             IsabelleTestSupport.session_timeout(),
                             on_event: on_event
                           )

                  assert [%{"theory_name" => theory_name}] = use_task.result["nodes"]
                  assert theory_name == "Draft.#{theory}"
                  assert Enum.join(IsabelleClient.messages(use_task), "\n") =~ expected_result
                  {:use_theories, theory, expected_result, use_task}
              end

            send(parent, {:shared_concurrent_result, theory_ref, result})
          end)
        end)

      Enum.each(theory_tasks, &send(&1.pid, {:go, theory_release_ref}))
      theory_results = collect_results(theory_ref, length(theory_tasks), 120_000)
      Enum.each(theory_tasks, &Elixir.Task.await(&1, 1_000))

      results_by_theory =
        Map.new(theory_results, fn {:use_theories, theory, _expected, task} -> {theory, task} end)

      assert results_by_theory |> Map.keys() |> Enum.sort() == ~w(Example1 Example2 Example3)

      notes_by_theory =
        event_ref
        |> drain_notes(:shared_theory_note)
        |> Enum.group_by(fn {theory, _task_id, _message} -> theory end)

      assert notes_by_theory |> Map.keys() |> Enum.sort() == ~w(Example1 Example2 Example3)

      for {theory, task} <- results_by_theory do
        assert task.notes != []

        assert Enum.all?(notes_by_theory[theory], fn {_theory, task_id, _message} ->
                 task_id == task.id
               end)
      end

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               Shared.purge_theories(pid, %{
                 "theories" => ~w(Example1 Example2 Example3),
                 "master_dir" => theory_dir
               })

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, %IsabelleTask{status: :finished, result: %{"ok" => true}}} =
               Shared.stop_session(pid, IsabelleTestSupport.session_timeout())

      assert {:ok, nil} = Shared.shutdown_server(pid)
      assert :ok = Shared.close(pid)
    end)
  end

  defp collect_results(ref, count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    for _ <- 1..count do
      receive do
        {:shared_concurrent_result, ^ref, result} ->
          result
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("timed out waiting for concurrent result")
      end
    end
  end

  defp drain_notes(ref, tag, acc \\ []) do
    receive do
      {^tag, ^ref, label, task_id, message} ->
        drain_notes(ref, tag, [{label, task_id, message} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp start_fake_authenticated_server(after_auth) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, "secret"} = IsabelleTestSupport.recv_line(socket)
        :ok = :gen_tcp.send(socket, "OK\n")
        after_auth.(socket, parent)
        Process.sleep(:infinity)
      end)

    {:ok, pid} = Shared.connect(password: "secret", host: "127.0.0.1", port: port)
    :gen_tcp.close(listen)
    {:ok, pid, server}
  end

  defp assert_server_down(server) do
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server, _}
  end
end
