defmodule IsabelleClientFullTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Protocol
  alias IsabelleClient.Task, as: IsabelleTask

  test "command timeout is applied to the socket receive, not only GenServer.call" do
    {:ok, pid, server} =
      start_fake_authenticated_server(fn socket, parent ->
        {:ok, command} = recv_line(socket)
        send(parent, {:command, command})
      end)

    assert {:error, :timeout} = IsabelleClientFull.command(pid, "help", nil, 50)
    assert_receive {:command, "help"}

    :ok = IsabelleClientFull.close(pid)
    assert_server_down(server)
  end

  test "async command timeout is applied while awaiting Isabelle task completion" do
    {:ok, pid, server} =
      start_fake_authenticated_server(fn socket, parent ->
        {:ok, command} = recv_line(socket)
        send(parent, {:command, command})
        :ok = :gen_tcp.send(socket, Protocol.command("OK", %{"task" => "task-1"}))
      end)

    assert {:error, :timeout} = IsabelleClientFull.build_session(pid, %{"session" => "HOL"}, 50)
    assert_receive {:command, "session_build {\"session\":\"HOL\"}"}

    :ok = IsabelleClientFull.close(pid)
    assert_server_down(server)
  end

  test "concurrent async tasks are routed by task id with note callbacks" do
    parent = self()

    {:ok, pid, server} =
      start_fake_authenticated_server(fn socket, parent ->
        {:ok, first} = recv_line(socket)
        send(parent, {:command, 1, first})
        :ok = :gen_tcp.send(socket, Protocol.command("OK", %{"task" => "task-1"}))

        {:ok, second} = recv_line(socket)
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

    on_note = fn note -> send(parent, {:note, note["task"], note["message"]}) end

    first =
      Elixir.Task.async(fn ->
        IsabelleClientFull.build_session(pid, [session: "First"], 1_000, on_note: on_note)
      end)

    assert_receive {:command, 1, "session_build {\"session\":\"First\"}"}

    second =
      Elixir.Task.async(fn ->
        IsabelleClientFull.build_session(pid, [session: "Second"], 1_000, on_note: on_note)
      end)

    assert_receive {:command, 2, "session_build {\"session\":\"Second\"}"}

    assert {:ok,
            %IsabelleTask{
              id: "task-1",
              result: %{"name" => "first"},
              notes: [%{"message" => "first note"}]
            }} =
             Elixir.Task.await(first)

    assert {:ok,
            %IsabelleTask{
              id: "task-2",
              result: %{"name" => "second"},
              notes: [%{"message" => "second note"}]
            }} =
             Elixir.Task.await(second)

    assert_receive {:note, "task-1", "first note"}
    assert_receive {:note, "task-2", "second note"}

    :ok = IsabelleClientFull.close(pid)
    assert_server_down(server)
  end

  @tag timeout: 180_000
  test "GenServer client can start and clean up a local session" do
    name = "elixir_test_full_local_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             IsabelleClientFull.start_link(
               server_name: name,
               session: "HOL",
               timeout: IsabelleTestSupport.session_timeout()
             )

    assert {:ok, "ok"} = IsabelleClientFull.echo(pid, "ok")
    assert :ok = IsabelleClientFull.close(pid)
  end

  @tag timeout: 180_000
  test "GenServer client routes concurrent callers and exercises full API" do
    IsabelleTestSupport.with_server("full", fn server ->
      assert {:ok, pid} =
               IsabelleClientFull.connect(
                 password: server["password"],
                 host: server["host"],
                 port: server["port"]
               )

      assert Process.alive?(pid)

      assert {:error, :no_session} = IsabelleClientFull.use_theories(pid, %{})
      assert {:error, :no_session} = IsabelleClientFull.purge_theories(pid, %{})
      assert {:error, :no_session} = IsabelleClientFull.stop_session(pid)

      assert {:ok, commands} = IsabelleClientFull.help(pid)
      IsabelleTestSupport.assert_commands(commands)

      # This batch is the core Full-client property. Each caller expects its
      # own unique response from one shared TCP connection. Sharing the Mini
      # socket or stateful client directly across these tasks can let callers
      # steal each other's replies.
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
                  "client" => "full",
                  "n" => n,
                  "token" => "token-#{n}",
                  "framed" => String.duplicate(Integer.to_string(rem(n, 10)), 160)
                }

                assert {:ok, ^payload} = IsabelleClientFull.echo(pid, payload)

              {:help, _n} ->
                assert {:ok, commands} = IsabelleClientFull.help(pid)
                IsabelleTestSupport.assert_commands(commands)
            end

            send(parent, {:full_concurrent_result, ref, operation})
          end)
        end)

      Enum.each(concurrent_tasks, &send(&1.pid, {:go, release_ref}))

      concurrent_results = collect_results(ref, 30, 30_000)
      Enum.each(concurrent_tasks, &Elixir.Task.await(&1, 1_000))

      assert Enum.sort(concurrent_results) ==
               Enum.sort(Enum.map(1..25, &{:echo, &1}) ++ Enum.map(1..5, &{:help, &1}))

      assert {:ok, %IsabelleTask{status: :finished, result: %{"ok" => true}}} =
               IsabelleClientFull.build_session(
                 pid,
                 %{"session" => "HOL"},
                 IsabelleTestSupport.session_timeout()
               )

      assert {:ok, %IsabelleTask{status: :finished} = start_task} =
               IsabelleClientFull.start_session(
                 pid,
                 %{"session" => "HOL"},
                 IsabelleTestSupport.session_timeout()
               )

      assert is_binary(start_task.result["session_id"])

      assert {:ok, %{"phase" => "active_session"}} =
               IsabelleClientFull.echo(pid, %{"phase" => "active_session"})

      theory_dir =
        Path.join(System.tmp_dir!(), "isabelle_elixir_full_#{System.unique_integer([:positive])}")

      File.mkdir_p!(theory_dir)

      theories = [
        {"Example1", "lemma \"x = x\"\n  by simp", "theorem ?x = ?x"},
        {"Example2", "lemma \"xs @ [] = xs\"\n  by simp", "theorem ?xs @ [] = ?xs"},
        {"Example3", "lemma \"(A \\<longrightarrow> A) \\<and> True\"\n  by simp",
         "theorem (?A \\<longrightarrow> ?A) \\<and> True"}
      ]

      for {theory, body, _expected} <- theories do
        File.write!(Path.join(theory_dir, "#{theory}.thy"), """
        theory #{theory} imports Main
        begin

        #{body}

        end
        """)
      end

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
                  assert {:ok,
                          %IsabelleTask{status: :finished, result: %{"ok" => true}} = use_task} =
                           IsabelleClientFull.use_theories(
                             pid,
                             %{"theories" => [theory], "master_dir" => theory_dir},
                             IsabelleTestSupport.session_timeout()
                           )

                  assert [%{"theory_name" => theory_name}] = use_task.result["nodes"]
                  assert theory_name == "Draft.#{theory}"
                  assert IsabelleClientMini.extract_results(use_task) =~ expected_result
                  {:use_theories, theory, expected_result, use_task}
              end

            send(parent, {:full_concurrent_result, theory_ref, result})
          end)
        end)

      Enum.each(theory_tasks, &send(&1.pid, {:go, theory_release_ref}))
      theory_results = collect_results(theory_ref, length(theory_tasks), 120_000)
      Enum.each(theory_tasks, &Elixir.Task.await(&1, 1_000))

      assert theory_results
             |> Enum.map(fn {:use_theories, theory, _expected, %IsabelleTask{}} -> theory end)
             |> Enum.sort() == ~w(Example1 Example2 Example3)

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               IsabelleClientFull.purge_theories(pid, %{
                 "theories" => ~w(Example1 Example2 Example3),
                 "master_dir" => theory_dir
               })

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, %IsabelleTask{status: :finished, result: %{"ok" => true}}} =
               IsabelleClientFull.stop_session(pid, IsabelleTestSupport.session_timeout())

      assert {:ok, nil} = IsabelleClientFull.shutdown_server(pid)
      assert :ok = IsabelleClientFull.close(pid)
    end)
  end

  defp collect_results(ref, count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    for _ <- 1..count do
      receive do
        {:full_concurrent_result, ^ref, result} ->
          result
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          flunk("timed out waiting for concurrent result")
      end
    end
  end

  defp start_fake_authenticated_server(after_auth) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, "secret"} = recv_line(socket)
        :ok = :gen_tcp.send(socket, "OK\n")
        after_auth.(socket, parent)
        Process.sleep(:infinity)
      end)

    {:ok, pid} = IsabelleClientFull.connect(password: "secret", host: "127.0.0.1", port: port)
    :gen_tcp.close(listen)
    {:ok, pid, server}
  end

  defp recv_line(socket, acc \\ []) do
    case :gen_tcp.recv(socket, 1, 1_000) do
      {:ok, "\n"} -> {:ok, IO.iodata_to_binary(acc)}
      {:ok, byte} -> recv_line(socket, [acc, byte])
      {:error, reason} -> {:error, reason}
    end
  end

  defp assert_server_down(server) do
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server, _}
  end
end
