defmodule IsabelleClient.RawTest do
  use ExUnit.Case, async: false

  alias IsabelleClient.Raw
  alias IsabelleClient.Result
  alias IsabelleClient.Protocol
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

      {build_session, build_dir} = build_session_dir()

      assert {:ok, build_task} =
               Raw.build_session(socket,
                 session: build_session,
                 dirs: [build_dir],
                 options: ["document=false"],
                 include_sessions: ["HOL-Library"],
                 verbose: true
               )

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = build_task} =
               await(socket, build_task)

      assert %Result.SessionBuildResult{ok: true, sessions: build_sessions} =
               IsabelleClient.session_build_result(build_task)

      assert Enum.any?(build_sessions, &(&1.session == build_session and &1.ok == true))
      assert_task_note_messages(build_task)

      assert {:ok, start_task} =
               Raw.start_session(socket,
                 session: build_session,
                 dirs: [build_dir],
                 print_mode: ["ASCII"],
                 verbose: true
               )

      assert {:ok, %Task{status: :finished} = start_task} = await(socket, start_task)
      assert_task_note_messages(start_task)

      session_id = IsabelleClient.extract_session(start_task)
      assert is_binary(session_id)

      assert {:ok, use_task} =
               Raw.use_theories(socket,
                 session_id: session_id,
                 theories: ["combinators"],
                 master_dir: build_dir,
                 nodes_status_delay: 0.1
               )

      assert {:ok, %Task{status: :finished, result: %{"ok" => true}} = use_task} =
               await(socket, use_task)

      assert Enum.join(IsabelleClient.messages(use_task), "\n") =~ "theorem ?xs @ [] = ?xs"

      Process.sleep(200)

      {second_build_session, second_build_dir} = build_session_dir()

      assert {:ok, second_build_task} =
               Raw.build_session(socket,
                 session: second_build_session,
                 dirs: [second_build_dir],
                 options: ["document=false"],
                 verbose: true
               )

      assert_finished(socket, second_build_task)

      assert {:ok, %{"purged" => purged, "retained" => retained}} =
               Raw.purge_theories(socket,
                 session_id: session_id,
                 theories: ["combinators"],
                 master_dir: build_dir
               )

      assert is_list(purged)
      assert is_list(retained)

      assert {:ok, stop_task} = Raw.stop_session(socket, session_id)

      assert_finished(socket, stop_task)

      assert {:ok, nil} = Raw.shutdown_server(socket)
      assert :ok = Raw.close(socket)
    end)
  end

  test "build_session sends Isabelle session_build arguments" do
    {socket, listen, server} = start_command_server(%{"task" => "build-task"})

    assert {:ok, %Task{id: "build-task", status: :running}} =
             Raw.build_session(
               socket,
               session: "HOL-Algebra",
               preferences: "some Isabelle preference text",
               options: ["document=false", "timeout=60"],
               dirs: ["src"],
               include_sessions: ["HOL-Library"],
               verbose: true
             )

    assert_receive {:command, "session_build " <> json}

    assert JSON.decode!(json) == %{
             "session" => "HOL-Algebra",
             "preferences" => "some Isabelle preference text",
             "options" => ["document=false", "timeout=60"],
             "dirs" => ["src"],
             "include_sessions" => ["HOL-Library"],
             "verbose" => true
           }

    close_command_server(socket, listen, server)
  end

  test "sync commands skip queued notes before the command response" do
    {socket, listen, server} =
      start_command_server(%{"ok" => true}, [
        %{"kind" => "nodes_status", "nodes_status" => []}
      ])

    assert {:ok, %{"ok" => true}} = Raw.command(socket, "echo", %{"ok" => true})

    assert_receive {:command, "echo " <> json}
    assert JSON.decode!(json) == %{"ok" => true}

    close_command_server(socket, listen, server)
  end

  test "async commands skip queued notes before the task acknowledgement" do
    {socket, listen, server} =
      start_command_server(%{"task" => "build-task"}, [
        %{"kind" => "nodes_status", "nodes_status" => []}
      ])

    assert {:ok, %Task{id: "build-task", status: :running}} =
             Raw.build_session(socket, session: "HOL")

    assert_receive {:command, "session_build " <> json}
    assert JSON.decode!(json) == %{"session" => "HOL"}

    close_command_server(socket, listen, server)
  end

  test "start_session sends Isabelle session_start arguments" do
    {socket, listen, server} = start_command_server(%{"task" => "start-task"})

    assert {:ok, %Task{id: "start-task", status: :running}} =
             Raw.start_session(
               socket,
               session: "HOL",
               preferences: "some Isabelle preference text",
               options: ["document=false", "timeout=60"],
               dirs: ["src"],
               include_sessions: ["HOL-Library"],
               verbose: true,
               print_mode: ["ASCII"]
             )

    assert_receive {:command, "session_start " <> json}

    assert JSON.decode!(json) == %{
             "session" => "HOL",
             "preferences" => "some Isabelle preference text",
             "options" => ["document=false", "timeout=60"],
             "dirs" => ["src"],
             "include_sessions" => ["HOL-Library"],
             "verbose" => true,
             "print_mode" => ["ASCII"]
           }

    close_command_server(socket, listen, server)
  end

  test "use_theories sends Isabelle use_theories arguments" do
    {socket, listen, server} = start_command_server(%{"task" => "use-task"})

    assert {:ok, %Task{id: "use-task", status: :running}} =
             Raw.use_theories(
               socket,
               session_id: "session-1",
               theories: ["Example"],
               master_dir: "/tmp/example",
               pretty_margin: 100.0,
               unicode_symbols: true,
               export_pattern: "document/*",
               check_delay: 0.2,
               check_limit: 5,
               watchdog_timeout: 10.0,
               nodes_status_delay: 0.5
             )

    assert_receive {:command, "use_theories " <> json}

    assert JSON.decode!(json) == %{
             "session_id" => "session-1",
             "theories" => ["Example"],
             "master_dir" => "/tmp/example",
             "pretty_margin" => 100.0,
             "unicode_symbols" => true,
             "export_pattern" => "document/*",
             "check_delay" => 0.2,
             "check_limit" => 5,
             "watchdog_timeout" => 10.0,
             "nodes_status_delay" => 0.5
           }

    close_command_server(socket, listen, server)
  end

  defp start_command_server(ok_body, notes_before_ok \\ []) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, command} = recv_client_command(socket)
        send(parent, {:command, command})

        for note <- notes_before_ok do
          :ok = :gen_tcp.send(socket, Protocol.command("NOTE", note))
        end

        :ok = :gen_tcp.send(socket, Protocol.command("OK", ok_body))
        :gen_tcp.close(socket)
      end)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    {socket, listen, server}
  end

  defp close_command_server(socket, listen, server) do
    :gen_tcp.close(socket)
    :gen_tcp.close(listen)
    ref = Process.monitor(server)
    assert_receive {:DOWN, ^ref, :process, ^server, _}
  end

  defp assert_finished(socket, task) do
    assert {:ok, %Task{status: :finished, result: %{"ok" => true}}} = await(socket, task)
  end

  defp await(socket, task) do
    Raw.await_task(socket, task, IsabelleTestSupport.session_timeout())
  end

  defp assert_task_note_messages(%Task{notes: notes} = task) do
    note_messages =
      notes
      |> Enum.filter(&is_binary(Map.get(&1, "message")))
      |> Enum.map(& &1["message"])
      |> Enum.reject(&(&1 == ""))

    assert note_messages != []
    assert IsabelleClient.messages(task) == note_messages
    assert Enum.all?(IsabelleClient.diagnostics(task), &match?(%{"message" => _}, &1))
  end

  defp build_session_dir do
    suffix = System.unique_integer([:positive])
    session = "Elixir-Build-Theory-#{suffix}"
    dir = Path.join(System.tmp_dir!(), "isabelle_elixir_build_theory_#{suffix}")
    File.mkdir_p!(dir)

    File.write!(Path.join(dir, "ROOT"), """
    session "#{session}" = "HOL" +
      options [document = false, show_question_marks = false]
      theories
        combinators
    """)

    File.write!(Path.join(dir, "combinators.thy"), """
    theory combinators
      imports Main
    begin

    lemma "xs @ [] = xs"
      by simp

    end
    """)

    {session, dir}
  end

  defp recv_client_command(socket) do
    with {:ok, line} <- IsabelleTestSupport.recv_line(socket) do
      if String.match?(line, ~r/^\d+$/) do
        length = String.to_integer(line)

        with {:ok, data} <- :gen_tcp.recv(socket, length, 1_000) do
          {:ok, String.trim_trailing(data, "\n")}
        end
      else
        {:ok, line}
      end
    end
  end
end
