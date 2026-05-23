defmodule IsabelleClientFull do
  @moduledoc """
  GenServer-backed Isabelle client.

  The process owns the TCP socket, so callers may safely use the same client
  from multiple processes. Operations are serialized deliberately: Isabelle's
  server can run asynchronous tasks, but a single TCP stream is still easiest
  to reason about when one process owns reads and writes.
  """

  use GenServer

  @default_timeout 30_000
  @call_timeout_grace 1_000

  @doc "Starts a GenServer-backed Isabelle client."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "Alias for `start_link/1`."
  def connect(opts), do: start_link(opts)

  @doc "Stops the client process and closes its socket."
  def close(server), do: GenServer.stop(server, :normal)

  @doc "Runs a synchronous Isabelle command through the client process."
  def command(server, name, arg \\ nil, timeout \\ @default_timeout),
    do: GenServer.call(server, {:command, name, arg, timeout}, call_timeout(timeout))

  @doc "Round-trips a JSON value through Isabelle's `echo` command."
  def echo(server, value), do: command(server, "echo", value)

  @doc "Returns the server command names supported by Isabelle."
  def help(server), do: command(server, "help")

  @doc "Asks the Isabelle server process to shut down."
  def shutdown_server(server), do: command(server, "shutdown")

  @doc "Builds an Isabelle session image and waits for the task result."
  def build_session(server, args, timeout \\ :infinity),
    do: GenServer.call(server, {:async, :build_session, args, timeout}, call_timeout(timeout))

  @doc "Starts an Isabelle session and stores its `session_id` in the client process."
  def start_session(server, args, timeout \\ :infinity),
    do: GenServer.call(server, {:async, :start_session, args, timeout}, call_timeout(timeout))

  @doc "Stops the active Isabelle session."
  def stop_session(server, timeout \\ :infinity),
    do: GenServer.call(server, {:stop_session, timeout}, call_timeout(timeout))

  @doc "Checks theories in the active session and waits for the task result."
  def use_theories(server, args, timeout \\ :infinity),
    do: GenServer.call(server, {:async, :use_theories, args, timeout}, call_timeout(timeout))

  @doc "Purges theories from the active session."
  def purge_theories(server, args, timeout \\ @default_timeout),
    do: GenServer.call(server, {:purge_theories, args, timeout}, call_timeout(timeout))

  @impl true
  def init(opts) do
    password = Keyword.fetch!(opts, :password)
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 9999)
    timeout = Keyword.get(opts, :timeout, 30_000)

    case IsabelleClient.connect(password, host: host, port: port, timeout: timeout) do
      {:ok, client} -> {:ok, client}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, client), do: IsabelleClient.close(client)

  @impl true
  def handle_call({:command, name, arg, timeout}, _from, client) do
    {:reply, IsabelleClient.command(client, name, arg, timeout), client}
  end

  def handle_call({:async, :build_session, args, timeout}, _from, client) do
    {:reply, IsabelleClient.build_session(client, args, timeout), client}
  end

  def handle_call({:async, :start_session, args, timeout}, _from, client) do
    case IsabelleClient.start_session(client, args, timeout) do
      {:ok, client, task} -> {:reply, {:ok, task}, client}
      other -> {:reply, other, client}
    end
  end

  def handle_call({:stop_session, timeout}, _from, client) do
    case IsabelleClient.stop_session(client, timeout) do
      {:ok, client, task} -> {:reply, {:ok, task}, client}
      {:error, client, task} -> {:reply, {:error, task}, client}
      other -> {:reply, other, client}
    end
  end

  def handle_call({:async, :use_theories, args, timeout}, _from, client) do
    {:reply, IsabelleClient.use_theories(client, args, timeout), client}
  end

  def handle_call({:purge_theories, args, timeout}, _from, client) do
    {:reply, IsabelleClient.purge_theories(client, args, timeout), client}
  end

  defp call_timeout(:infinity), do: :infinity

  defp call_timeout(timeout) when is_integer(timeout) and timeout >= 0,
    do: timeout + @call_timeout_grace
end
