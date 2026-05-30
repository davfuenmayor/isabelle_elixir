defmodule IsabelleProtocolTest do
  use ExUnit.Case, async: true

  alias IsabelleClient.Protocol
  alias IsabelleClient.Protocol.Response
  alias IsabelleClient.Arguments
  alias IsabelleClient.Result
  alias IsabelleClient.Result.UseTheoriesResult
  alias IsabelleClient.Session
  alias IsabelleClient.Server
  alias IsabelleClient.Server.Info
  alias IsabelleClient.Task
  alias IsabelleClient.Theory

  test "encodes short and long Isabelle line messages" do
    assert IO.iodata_to_binary(Protocol.command("help")) == "help\n"

    long = String.duplicate("x", 101)
    assert IO.iodata_to_binary(Protocol.command("echo", long)) == "109\necho \"" <> long <> "\"\n"

    assert IO.iodata_to_binary(Protocol.command("echo", %{"a" => 1})) == "echo {\"a\":1}\n"
    assert IO.iodata_to_binary(Protocol.line_message("123")) == "4\n123\n"
  end

  test "parses all Isabelle response variants" do
    assert Protocol.parse("OK {\"task\":\"abc\"}") ==
             {:ok, %Response{type: :ok, body: %{"task" => "abc"}, raw: "OK {\"task\":\"abc\"}"}}

    assert Protocol.parse("ERROR {\"kind\":\"error\"}") ==
             {:ok,
              %Response{
                type: :error,
                body: %{"kind" => "error"},
                raw: "ERROR {\"kind\":\"error\"}"
              }}

    assert Protocol.parse("NOTE {\"task\":\"abc\"}") ==
             {:ok,
              %Response{type: :note, body: %{"task" => "abc"}, raw: "NOTE {\"task\":\"abc\"}"}}

    assert Protocol.parse("FINISHED {\"ok\":true,\"task\":\"abc\"}") ==
             {:ok,
              %Response{
                type: :finished,
                body: %{"ok" => true, "task" => "abc"},
                raw: "FINISHED {\"ok\":true,\"task\":\"abc\"}"
              }}

    assert Protocol.parse("FAILED {\"message\":\"bad\",\"task\":\"abc\"}") ==
             {:ok,
              %Response{
                type: :failed,
                body: %{"message" => "bad", "task" => "abc"},
                raw: "FAILED {\"message\":\"bad\",\"task\":\"abc\"}"
              }}
  end

  test "reports malformed and unknown responses" do
    assert Protocol.parse("") == {:error, {:malformed_response, ""}}
    assert Protocol.parse("BOGUS {}") == {:error, {:unknown_response, "BOGUS"}}
  end

  test "extracts ok bodies and task ids" do
    response = %Response{type: :ok, body: %{"task" => "abc"}}
    assert Protocol.ok_body(response) == {:ok, %{"task" => "abc"}}
    assert Protocol.task_id(response) == {:ok, "abc"}

    assert Protocol.ok_body(%Response{type: :error, body: %{"message" => "bad"}}) ==
             {:error, %{"message" => "bad"}}

    assert {:error, {:missing_task, _}} = Protocol.task_id(%Response{type: :ok, body: nil})
  end

  test "receives length-framed responses from a socket" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        :ok = :gen_tcp.send(socket, "17\nOK {\"long\":true}\n")
        send(parent, :sent)
        :gen_tcp.close(socket)
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    assert Protocol.recv(client) ==
             {:ok,
              %Response{
                type: :ok,
                body: %{"long" => true},
                raw: "OK {\"long\":true}",
                length: 17
              }}

    assert_receive :sent
    :gen_tcp.close(client)
    :gen_tcp.close(listen)
    ref = Process.monitor(server)
    assert_receive {:DOWN, ^ref, :process, ^server, _}
  end

  test "applies receive timeout as one frame deadline" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)

        for byte <- String.graphemes("OK true\n") do
          :gen_tcp.send(socket, byte)
          Process.sleep(20)
        end

        :gen_tcp.close(socket)
      end)

    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    started = System.monotonic_time(:millisecond)
    assert Protocol.recv(client, 50) == {:error, :timeout}
    assert System.monotonic_time(:millisecond) - started < 150

    :gen_tcp.close(client)
    :gen_tcp.close(listen)
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server, _}
  end

  test "parses Isabelle server info" do
    data = "server \"elixir\" = 127.0.0.1:9999 (password \"secret\")\n"

    assert Server.parse_info(data) == [
             %Info{name: "elixir", host: "127.0.0.1", port: 9999, password: "secret"}
           ]

    assert [%{} = info] = Server.parse_info(data)
    assert info.name == "elixir"
    assert info["password"] == "secret"
    assert info[:password] == "secret"
  end

  test "extracts use_theories messages" do
    task = %Task{
      status: :finished,
      result: %{
        "errors" => [
          %{
            "message" => "top-level error",
            "kind" => "error",
            "pos" => %{"line" => 4, "offset" => 50, "end_offset" => 55}
          }
        ],
        "nodes" => [
          %{
            "node_name" => "node-1",
            "theory_name" => "Draft.One",
            "status" => %{
              "ok" => true,
              "total" => 3,
              "unprocessed" => 0,
              "running" => 0,
              "warned" => 1,
              "failed" => 0,
              "finished" => 3,
              "canceled" => false,
              "consolidated" => true,
              "percentage" => 100
            },
            "messages" => [
              %{
                "message" => "line 1",
                "kind" => "writeln",
                "pos" => %{"file" => "One.thy", "line" => 1, "offset" => 10, "end_offset" => 15}
              },
              %{
                "message" => "line 2 early",
                "kind" => "warning",
                "pos" => %{"file" => "One.thy", "line" => 2, "offset" => 20, "end_offset" => 25}
              },
              %{
                "message" => "line 2 late",
                "kind" => "writeln",
                "pos" => %{"file" => "One.thy", "line" => 2, "offset" => 30, "end_offset" => 35}
              }
            ],
            "exports" => [
              %{"name" => "export/one", "base64" => false, "body" => "plain"}
            ]
          },
          %{
            "node_name" => "node-2",
            "theory_name" => "Draft.Two",
            "status" => %{
              "ok" => false,
              "total" => 2,
              "unprocessed" => 0,
              "running" => 0,
              "warned" => 0,
              "failed" => 1,
              "finished" => 1,
              "canceled" => false,
              "consolidated" => false,
              "percentage" => 50
            },
            "messages" => [
              %{"message" => "", "kind" => "writeln", "pos" => %{"line" => 2}},
              %{
                "message" => "line 3",
                "kind" => "error",
                "pos" => %{"file" => "Two.thy", "line" => 3, "offset" => 40, "end_offset" => 45}
              },
              %{"message" => "unpositioned", "kind" => "writeln"}
            ]
          }
        ]
      }
    }

    assert Result.messages(task) == [
             "line 1",
             "line 2 early",
             "line 2 late",
             "line 3",
             "unpositioned"
           ]

    assert IsabelleClient.messages(task, line: 2) == ["line 2 early", "line 2 late"]
    assert IsabelleClient.messages(task, line: 2..3) == ["line 2 early", "line 2 late", "line 3"]
    assert IsabelleClient.messages(task, line: [1, 3]) == ["line 1", "line 3"]

    assert IsabelleClient.messages(task, offset: 20) == ["line 2 early"]
    assert IsabelleClient.messages(task, offset: 25) == ["line 2 early"]
    assert IsabelleClient.messages(task, offset: 32) == ["line 2 late"]
    assert IsabelleClient.messages(task, offset: 45) == ["line 3"]
    assert IsabelleClient.messages(task, offset: 46) == []

    assert IsabelleClient.messages(task, line: 2, offset: 32) == ["line 2 late"]
    assert IsabelleClient.messages(task, line: 3, offset: 32) == []

    assert IsabelleClient.messages(task, file: "One.thy") == [
             "line 1",
             "line 2 early",
             "line 2 late"
           ]

    assert IsabelleClient.messages(task, file: ["Two.thy"]) == ["line 3"]
    assert IsabelleClient.messages(task, file: "One.thy", line: 2, offset: 32) == ["line 2 late"]
    assert IsabelleClient.messages(task, file: "Two.thy", line: 2) == []
    assert IsabelleClient.warnings(task, line: 2, offset: 22) == ["line 2 early"]
    assert IsabelleClient.errors(task) == ["top-level error", "line 3"]
    assert IsabelleClient.errors(task, offset: 42) == ["line 3"]
    assert IsabelleClient.errors(task, line: 4) == ["top-level error"]
    assert [%{"message" => "line 3"}] = IsabelleClient.diagnostics(task, line: 3)
    assert IsabelleClient.messages(%{"nodes" => []}) == []

    assert %UseTheoriesResult{ok: nil, errors: [top_level], nodes: [first, second]} =
             IsabelleClient.use_theories_result(task)

    assert top_level.message == "top-level error"
    assert first.node_name == "node-1"
    assert first.theory_name == "Draft.One"

    assert first.status == %Result.NodeStatus{
             ok: true,
             total: 3,
             unprocessed: 0,
             running: 0,
             warned: 1,
             failed: 0,
             finished: 3,
             canceled: false,
             consolidated: true,
             percentage: 100
           }

    assert IsabelleClient.nodes(task) == [first, second]
    assert IsabelleClient.node(task, "node-1") == first
    assert IsabelleClient.node(task, "Draft.Two") == second
    assert [%{name: "export/one", base64: false, body: "plain"}] = IsabelleClient.exports(task)
    assert [^top_level] = IsabelleClient.top_level_errors(task)

    node_error = Enum.find(second.messages, &(&1.kind == "error"))
    assert node_error.pos.line == 3
    assert IsabelleClient.messages(Result.decode(task), line: 3) == ["line 3"]
    assert IsabelleClient.errors(Result.decode(task)) == ["top-level error", "line 3"]
  end

  test "extracts session ids and session_start task messages" do
    task = %Task{
      status: :finished,
      result: %{"session_id" => "session-123"},
      notes: [
        note("start-task", "writeln", "Started HOL", 1, 10),
        note("start-task", "warning", "Session warning", 11, 20),
        note("start-task", "error", "Session error", 21, 30),
        %{"task" => "start-task", "kind" => "theory_progress", "theory" => "HOL"}
      ]
    }

    assert Result.extract_session(task) == "session-123"
    assert Result.extract_session(%Session{id: "session-123"}) == "session-123"
    assert IsabelleClient.extract_session(task) == "session-123"
    assert IsabelleClient.extract_session(%{"session_id" => "session-123"}) == "session-123"
    assert %Session{} = session = Result.decode(task)
    assert session == %Session{id: "session-123", tmp_dir: nil}
    assert session["session_id"] == "session-123"
    assert session[:session_id] == "session-123"
    assert Result.extract_session(%{}) == nil

    assert_notes(task, [
      note("start-task", "writeln", "Started HOL", 1, 10),
      note("start-task", "warning", "Session warning", 11, 20),
      note("start-task", "error", "Session error", 21, 30)
    ])

    assert IsabelleClient.warnings(task) == ["Session warning"]
    assert IsabelleClient.errors(task) == ["Session error"]
    assert IsabelleClient.messages(task, file: "ROOT", line: 1, offset: 5) == ["Started HOL"]
  end

  test "decodes session_build results" do
    result = %{
      "ok" => true,
      "return_code" => 0,
      "sessions" => [
        %{
          "session" => "HOL",
          "ok" => true,
          "return_code" => 0,
          "timeout" => false,
          "timing" => %{"elapsed" => 1.0, "cpu" => 0.8, "gc" => 0.0}
        }
      ]
    }

    task = %Task{
      status: :finished,
      result: result,
      notes: [
        note("build-task", "writeln", "Building HOL", 10, 20),
        %{"task" => "build-task", "kind" => "theory_progress", "theory" => "HOL"}
      ]
    }

    assert %Result.SessionBuildResult{} = decoded = Result.decode(task)
    assert decoded.ok == true
    assert decoded.return_code == 0

    assert [%Result.SessionBuildEntry{} = session] = decoded.sessions
    assert session.session == "HOL"
    assert session.ok == true
    assert session.return_code == 0
    assert session.timeout == false
    assert session.timing == %{"elapsed" => 1.0, "cpu" => 0.8, "gc" => 0.0}

    assert IsabelleClient.session_build_result(task) == decoded
    assert IsabelleClient.session_build_result(%{}) == nil

    assert_notes(task, [note("build-task", "writeln", "Building HOL", 10, 20)])
    assert IsabelleClient.messages(task, file: "ROOT", line: 1, offset: 15) == ["Building HOL"]
  end

  test "normalizes keyword and atom-keyed Isabelle arguments" do
    assert Arguments.normalize(
             session: "HOL",
             dirs: ["src"],
             options: [threads: 4],
             include_sessions: [],
             nested: [%{print_mode: ["ASCII"]}]
           ) == %{
             "session" => "HOL",
             "dirs" => ["src"],
             "options" => %{"threads" => 4},
             "include_sessions" => [],
             "nested" => [%{"print_mode" => ["ASCII"]}]
           }

    assert Session.put_id([session_id: "explicit"], "active") ==
             {:ok, %{"session_id" => "explicit"}}

    assert Session.put_id([], "active") == {:ok, %{"session_id" => "active"}}
    assert Session.put_id([], nil) == :error

    assert Session.prepare_start_args(session: "HOL", label: "main", print_mode: ["ASCII"]) ==
             {%{"session" => "HOL", "print_mode" => ["ASCII"]}, "main"}
  end

  test "prepares theory files and use_theories arguments" do
    dir =
      Path.join(System.tmp_dir!(), "isabelle_elixir_theory_#{System.unique_integer([:positive])}")

    assert Theory.write_args(
             "Scratch.Example",
             "lemma \"x = x\"\n  by simp",
             [imports: "Main"],
             dir
           ) ==
             %{"master_dir" => dir, "theories" => ["Scratch.Example"]}

    assert File.read!(Path.join(dir, "Example.thy")) ==
             "theory Scratch.Example imports Main begin\nlemma \"x = x\"\n  by simp\nend\n"

    assert Theory.source("Scratch.Preserved", "lemma True\n  by simp\n\n") ==
             "theory Scratch.Preserved imports Main begin\nlemma True\n  by simp\n\nend\n"

    complete_theory = """
    theory CompleteExample imports Main begin

    lemma True
      by simp

    end
    """

    assert Theory.source("IgnoredName", complete_theory) == complete_theory
  end

  defp note(task, kind, message, offset, end_offset) do
    %{
      "task" => task,
      "kind" => kind,
      "message" => message,
      "pos" => %{"file" => "ROOT", "line" => 1, "offset" => offset, "end_offset" => end_offset}
    }
  end

  defp assert_notes(task, notes) do
    assert IsabelleClient.diagnostics(task) == notes
    assert IsabelleClient.messages(task) == Enum.map(notes, & &1["message"])
  end
end
