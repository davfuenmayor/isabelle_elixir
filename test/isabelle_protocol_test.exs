defmodule IsabelleProtocolTest do
  use ExUnit.Case, async: true

  alias IsabelleClient.Protocol
  alias IsabelleClient.Protocol.Response
  alias IsabelleClient.Arguments
  alias IsabelleClient.Result
  alias IsabelleClient.Server
  alias IsabelleClient.Task

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

  test "parses Isabelle server info" do
    data = "server \"elixir\" = 127.0.0.1:9999 (password \"secret\")\n"

    assert Server.parse_info(data) == [
             %{"name" => "elixir", "host" => "127.0.0.1", "port" => 9999, "password" => "secret"}
           ]
  end

  test "extracts use_theories messages" do
    task = %Task{
      status: :finished,
      result: %{
        "nodes" => [
          %{
            "messages" => [
              %{"message" => "first", "kind" => "writeln", "pos" => %{"line" => 1}},
              %{"message" => "second", "kind" => "warning", "pos" => %{"line" => 2}}
            ]
          },
          %{
            "messages" => [
              %{"message" => "", "kind" => "writeln", "pos" => %{"line" => 2}},
              %{"message" => "third", "kind" => "error", "pos" => %{"line" => 3}},
              %{"message" => "unpositioned", "kind" => "writeln"}
            ]
          }
        ]
      }
    }

    assert Result.messages(task) == ["first", "second", "third", "unpositioned"]
    assert IsabelleClient.messages(task) == ["first", "second", "third", "unpositioned"]
    assert IsabelleClient.messages(task, line: 2) == ["second"]
    assert IsabelleClient.messages(task, line: 2..3) == ["second", "third"]
    assert IsabelleClient.messages(task, line: [1, 3]) == ["first", "third"]
    assert IsabelleClient.warnings(task, line: 2) == ["second"]
    assert IsabelleClient.errors(task, line: 3) == ["third"]
    assert [%{"message" => "third"}] = IsabelleClient.diagnostics(task, line: 3)
    assert IsabelleClient.messages(%{"nodes" => []}) == []
  end

  test "extracts session ids from tasks and result maps" do
    task = %Task{status: :finished, result: %{"session_id" => "session-123"}}

    assert Result.extract_session(task) == "session-123"
    assert IsabelleClient.extract_session(task) == "session-123"
    assert IsabelleClientMini.extract_session(%{"session_id" => "session-123"}) == "session-123"
    assert Result.extract_session(%{}) == nil
  end

  test "normalizes keyword and atom-keyed Isabelle arguments" do
    assert Arguments.normalize(
             session: "HOL",
             dirs: ["src"],
             options: [threads: 4],
             nested: [%{print_mode: ["ASCII"]}]
           ) == %{
             "session" => "HOL",
             "dirs" => ["src"],
             "options" => %{"threads" => 4},
             "nested" => [%{"print_mode" => ["ASCII"]}]
           }
  end
end
