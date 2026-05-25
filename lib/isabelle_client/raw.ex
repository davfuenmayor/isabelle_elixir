defmodule IsabelleClient.Raw do
  @moduledoc """
  Raw-socket Isabelle client.

  This profile exposes the TCP socket and leaves session ids and asynchronous
  task waiting explicit. It is useful for protocol-level control and for
  understanding Isabelle server messages directly.
  """

  alias IsabelleClient.Arguments
  alias IsabelleClient.Protocol
  alias IsabelleClient.Protocol.Response
  alias IsabelleClient.Server
  alias IsabelleClient.Session
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

  @doc "Connects to an Isabelle server and returns a raw TCP socket."
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

  @doc "Closes a raw TCP socket."
  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)

  @doc "Receives one framed Isabelle server response from a raw socket."
  def recv(socket, timeout \\ @timeout) when is_port(socket), do: Protocol.recv(socket, timeout)

  @doc "Runs a synchronous Isabelle command."
  def command(socket, name, arg \\ nil, timeout \\ @timeout) when is_port(socket) do
    with :ok <- Protocol.send(socket, Protocol.command(name, normalize_arg(arg))),
         {:ok, response} <- Protocol.recv(socket, timeout) do
      Protocol.ok_body(response)
    end
  end

  @doc "Round-trips a JSON value through Isabelle's `echo` command."
  def echo(socket, value), do: command(socket, "echo", value)

  @doc "Returns the server command names supported by Isabelle."
  def help(socket), do: command(socket, "help")

  @doc "Asks the Isabelle server process to shut down."
  def shutdown_server(socket), do: command(socket, "shutdown")

  @doc "Requests cancellation of an Isabelle asynchronous task."
  def cancel_task(socket, task_id) when is_port(socket),
    do: command(socket, "cancel", %{"task" => task_id}, @timeout)

  @doc "Sends an async command and returns the task handle from Isabelle's `OK` reply."
  def async_command(socket, name, arg, timeout \\ @timeout) when is_port(socket) do
    with :ok <- Protocol.send(socket, Protocol.command(name, normalize_arg(arg))),
         {:ok, response} <- Protocol.recv(socket, timeout),
         {:ok, task_id} <- Protocol.task_id(response) do
      {:ok, Task.new(task_id)}
    end
  end

  @doc "Waits for an asynchronous task to finish or fail."
  def await_task(socket, task_or_id, timeout \\ :infinity)

  def await_task(socket, %Task{id: id} = task, timeout) when is_port(socket) do
    await_task(socket, id, timeout, task)
  end

  def await_task(socket, task_id, timeout) when is_port(socket) and is_binary(task_id) do
    await_task(socket, task_id, timeout, Task.new(task_id))
  end

  defp await_task(socket, task_id, timeout, task) when is_binary(task_id) do
    do_await_task(socket, task, deadline(timeout))
  end

  @doc "Starts a `session_build` task and returns its task handle."
  def build_session(socket, args, timeout \\ @timeout) when is_port(socket),
    do: async_command(socket, "session_build", args, timeout)

  @doc "Starts a `session_start` task and returns its task handle."
  def start_session(socket, args, timeout \\ @timeout) when is_port(socket),
    do: async_command(socket, "session_start", args, timeout)

  @doc "Starts a `session_stop` task and returns its task handle."
  def stop_session(socket, session_or_id, timeout \\ @timeout)

  def stop_session(socket, %Session{id: session_id}, timeout) when is_port(socket),
    do: stop_session(socket, session_id, timeout)

  def stop_session(socket, session_id, timeout)
      when is_port(socket) and is_binary(session_id),
      do: async_command(socket, "session_stop", %{"session_id" => session_id}, timeout)

  @doc "Starts a `use_theories` task and returns its task handle."
  def use_theories(socket, args, timeout \\ @timeout) when is_port(socket),
    do: async_command(socket, "use_theories", args, timeout)

  @doc "Purges theories from a session."
  def purge_theories(socket, args, timeout \\ @timeout) when is_port(socket),
    do: command(socket, "purge_theories", args, timeout)

  @doc "Alias for `await_task/3`."
  def poll_status(socket, task_or_id, timeout \\ :infinity),
    do: await_task(socket, task_or_id, timeout)

  defp do_await_task(socket, %Task{id: id, notes: notes} = task, deadline) do
    with {:ok, response} <- Protocol.recv(socket, remaining(deadline)) do
      response_task = task_id(response.body)

      cond do
        response.type == :note and response_task in [nil, id] ->
          do_await_task(socket, %{task | notes: [response.body | notes]}, deadline)

        response.type == :finished and response_task == id ->
          {:ok, %{task | status: :finished, result: response.body, notes: Enum.reverse(notes)}}

        response.type == :failed and response_task == id ->
          {:error, %{task | status: :failed, result: response.body, notes: Enum.reverse(notes)}}

        true ->
          do_await_task(socket, task, deadline)
      end
    end
  end

  defp task_id(%{"task" => id}), do: id
  defp task_id(_), do: nil

  defp normalize_arg(nil), do: nil
  defp normalize_arg(arg), do: Arguments.normalize(arg)

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
