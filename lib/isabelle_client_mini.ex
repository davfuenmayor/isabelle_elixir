defmodule IsabelleClientMini do
  @moduledoc """
  Minimal stateless client for the Isabelle server.

  The module intentionally exposes the TCP socket and keeps no process state.
  It does, however, implement Isabelle's real line-message framing: replies may
  be either a single line (`OK ...`) or a byte length line followed by exactly
  that many bytes.
  """

  alias IsabelleClient.Protocol
  alias IsabelleClient.Protocol.Response
  alias IsabelleClient.Server
  alias IsabelleClient.Task

  @default_host "127.0.0.1"
  @default_port 9999
  @timeout 30_000

  def new_server(name \\ "elixir", port \\ @default_port), do: Server.start(name, port)
  def list_servers, do: Server.list()
  def kill_server(name), do: Server.kill(name)

  def connect(password, host \\ @default_host, port \\ @default_port, timeout \\ @timeout) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             to_charlist(host),
             port,
             [:binary, active: false, nodelay: true],
             timeout
           ),
         :ok <- Protocol.send(socket, Protocol.line_message(password)),
         {:ok, %Response{type: :ok}} <- Protocol.recv(socket, timeout) do
      {:ok, socket}
    else
      {:ok, response} -> {:error, {:authentication_failed, response}}
      {:error, _} = error -> error
    end
  end

  def close(socket), do: :gen_tcp.close(socket)

  def recv(socket, timeout \\ @timeout), do: Protocol.recv(socket, timeout)

  def command(socket, name, arg \\ nil, timeout \\ @timeout) do
    with :ok <- Protocol.send(socket, Protocol.command(name, arg)),
         {:ok, response} <- Protocol.recv(socket, timeout) do
      Protocol.ok_body(response)
    end
  end

  def async_command(socket, name, arg, timeout \\ @timeout) do
    with :ok <- Protocol.send(socket, Protocol.command(name, arg)),
         {:ok, response} <- Protocol.recv(socket, timeout),
         {:ok, task_id} <- Protocol.task_id(response) do
      {:ok, Task.new(task_id)}
    end
  end

  def await_task(socket, task_or_id, timeout \\ :infinity)

  def await_task(socket, %Task{id: id} = task, timeout) do
    await_task(socket, id, timeout, task)
  end

  def await_task(socket, task_id, timeout) when is_binary(task_id) do
    await_task(socket, task_id, timeout, Task.new(task_id))
  end

  defp await_task(socket, task_id, timeout, task) when is_binary(task_id) do
    deadline = deadline(timeout)
    do_await_task(socket, task, deadline)
  end

  def echo(socket, value), do: command(socket, "echo", value)
  def help(socket), do: command(socket, "help")
  def cancel_task(socket, task_id), do: command(socket, "cancel", %{"task" => task_id})
  def shutdown_server(socket), do: command(socket, "shutdown")

  def build_session(socket, args), do: async_command(socket, "session_build", args)
  def start_session(socket, args), do: async_command(socket, "session_start", args)

  def stop_session(socket, session_id),
    do: async_command(socket, "session_stop", %{"session_id" => session_id})

  def use_theories(socket, args), do: async_command(socket, "use_theories", args)
  def purge_theories(socket, args), do: command(socket, "purge_theories", args)

  def poll_status(socket, task_or_id, timeout \\ :infinity)

  def poll_status(socket, %Task{} = task, timeout),
    do: await_task(socket, task, timeout)

  def poll_status(socket, task_id, timeout) when is_binary(task_id),
    do: await_task(socket, task_id, timeout)

  def extract_session(%Task{status: :finished, result: %{"session_id" => session_id}}),
    do: session_id

  def extract_session(%{"session_id" => session_id}), do: session_id

  def extract_results(%Task{status: :finished, result: result}), do: extract_results(result)

  def extract_results(%{"nodes" => [node | _]}) do
    node
    |> Map.get("messages", [])
    |> Enum.map(&Map.get(&1, "message", ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  def extract_results(_), do: ""

  defp do_await_task(socket, %Task{id: id, notes: notes} = task, deadline) do
    with {:ok, response} <- Protocol.recv(socket, remaining(deadline)) do
      response_task = task_id(response.body)

      cond do
        response.type == :note and response_task in [nil, id] ->
          do_await_task(socket, %{task | notes: notes ++ [response.body]}, deadline)

        response.type == :finished and response_task == id ->
          {:ok, %{task | status: :finished, result: response.body}}

        response.type == :failed and response_task == id ->
          {:error, %{task | status: :failed, result: response.body}}

        true ->
          do_await_task(socket, task, deadline)
      end
    end
  end

  defp task_id(%{"task" => id}), do: id
  defp task_id(_), do: nil

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
