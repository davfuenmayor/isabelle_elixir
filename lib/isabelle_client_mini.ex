defmodule IsabelleClientMini do
  @moduledoc """
  Minimal stateless client for the Isabelle server.

  The module intentionally exposes the TCP socket and keeps no process state.
  It does, however, implement Isabelle's real line-message framing: replies may
  be either a single line (`OK ...`) or a byte length line followed by exactly
  that many bytes.
  """

  alias IsabelleClient.Arguments
  alias IsabelleClient.Protocol
  alias IsabelleClient.Protocol.Response
  alias IsabelleClient.Result
  alias IsabelleClient.Session
  alias IsabelleClient.Server
  alias IsabelleClient.Task

  @default_host "127.0.0.1"
  @default_port 9999
  @timeout 30_000

  @doc "Starts a local resident Isabelle server via `isabelle server`."
  def new_server(name \\ "elixir", port \\ @default_port), do: Server.start(name, port)

  @doc "Lists local resident Isabelle servers known to Isabelle."
  def list_servers, do: Server.list()

  @doc "Force-kills a local resident Isabelle server by name."
  def kill_server(name), do: Server.kill(name)

  @doc "Connects to an Isabelle server and authenticates with its password."
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

  @doc "Closes a raw Isabelle TCP socket."
  def close(socket), do: :gen_tcp.close(socket)

  @doc "Receives one framed Isabelle server response."
  def recv(socket, timeout \\ @timeout), do: Protocol.recv(socket, timeout)

  @doc "Runs a synchronous Isabelle server command and returns its `OK` body."
  def command(socket, name, arg \\ nil, timeout \\ @timeout) do
    with :ok <- Protocol.send(socket, Protocol.command(name, normalize_command_arg(arg))),
         {:ok, response} <- Protocol.recv(socket, timeout) do
      Protocol.ok_body(response)
    end
  end

  @doc "Starts an asynchronous Isabelle command and returns an `%IsabelleClient.Task{}`."
  def async_command(socket, name, arg, timeout \\ @timeout) do
    with :ok <- Protocol.send(socket, Protocol.command(name, normalize_command_arg(arg))),
         {:ok, response} <- Protocol.recv(socket, timeout),
         {:ok, task_id} <- Protocol.task_id(response) do
      {:ok, Task.new(task_id)}
    end
  end

  @doc "Waits for an asynchronous Isabelle task to finish or fail."
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

  @doc "Round-trips a JSON value through Isabelle's `echo` command."
  def echo(socket, value), do: command(socket, "echo", value)

  @doc "Returns the server command names supported by Isabelle."
  def help(socket), do: command(socket, "help")

  @doc "Requests cancellation of an Isabelle asynchronous task."
  def cancel_task(socket, task_id), do: command(socket, "cancel", %{"task" => task_id})

  @doc "Asks the Isabelle server process to shut down."
  def shutdown_server(socket), do: command(socket, "shutdown")

  @doc "Starts an Isabelle `session_build` task."
  def build_session(socket, args), do: async_command(socket, "session_build", args)

  @doc "Starts an Isabelle `session_start` task."
  def start_session(socket, args), do: async_command(socket, "session_start", args)

  @doc "Starts an Isabelle `session_stop` task for a session id."
  def stop_session(socket, %Session{id: session_id}), do: stop_session(socket, session_id)

  def stop_session(socket, session_id),
    do: async_command(socket, "session_stop", %{"session_id" => session_id})

  @doc "Starts an Isabelle `use_theories` task."
  def use_theories(socket, args), do: async_command(socket, "use_theories", args)

  @doc "Runs Isabelle `purge_theories` for the given session arguments."
  def purge_theories(socket, args, timeout \\ @timeout),
    do: command(socket, "purge_theories", args, timeout)

  @doc "Alias for `await_task/3`, kept for the original Mini workflow."
  def poll_status(socket, task_or_id, timeout \\ :infinity)

  def poll_status(socket, %Task{} = task, timeout),
    do: await_task(socket, task, timeout)

  def poll_status(socket, task_id, timeout) when is_binary(task_id),
    do: await_task(socket, task_id, timeout)

  @doc "Extracts the `session_id` from a finished session-start result."
  defdelegate extract_session(result), to: Result

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

  defp normalize_command_arg(nil), do: nil
  defp normalize_command_arg(arg), do: Arguments.normalize(arg)

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
