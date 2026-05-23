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

  @doc "Checks an existing `.thy` file in the active session."
  def check_file(server, path, args \\ [], timeout \\ :infinity),
    do: GenServer.call(server, {:check_file, path, args, timeout}, call_timeout(timeout))

  @doc "Writes and checks a theory in the active session."
  def check_text(server, theory, text, opts \\ [], timeout \\ :infinity),
    do: GenServer.call(server, {:check_text, theory, text, opts, timeout}, call_timeout(timeout))

  @impl true
  def init(opts) do
    case init_client(opts) do
      {:ok, client} -> {:ok, client}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %IsabelleClient{server_name: name} = client) when is_binary(name) do
    IsabelleClient.shutdown_server(client)
    IsabelleClient.close(client)
    IsabelleClientMini.kill_server(name)
  end

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

  def handle_call({:check_file, path, args, timeout}, _from, client) do
    {:reply, IsabelleClient.check_file(client, path, args, timeout), client}
  end

  def handle_call({:check_text, theory, text, opts, timeout}, _from, client) do
    {:reply, IsabelleClient.check_text(client, theory, text, opts, timeout), client}
  end

  defp init_client(opts) do
    case Keyword.fetch(opts, :password) do
      {:ok, password} -> connect_existing(password, opts)
      :error -> start_local(opts)
    end
  end

  defp start_local(opts) do
    case IsabelleClient.start(opts) do
      {:ok, client, _task} -> {:ok, client}
      {:error, _reason} = error -> error
    end
  end

  defp connect_existing(password, opts) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 9999)
    connect_timeout = Keyword.get(opts, :connect_timeout, Keyword.get(opts, :timeout, 30_000))
    session = Keyword.get(opts, :session)
    timeout = Keyword.get(opts, :timeout, :infinity)

    with {:ok, client} <-
           IsabelleClient.connect(password, host: host, port: port, timeout: connect_timeout) do
      if session do
        start_existing_session(client, opts, timeout)
      else
        {:ok, client}
      end
    end
  end

  defp start_existing_session(client, opts, timeout) do
    case IsabelleClient.start_session(client, session_args(opts), timeout) do
      {:ok, client, _task} -> {:ok, client}
      {:error, _reason} = error -> error
    end
  end

  defp session_args(opts) do
    opts
    |> Keyword.get(:session_args, [])
    |> IsabelleClient.Arguments.normalize()
    |> Map.put_new("session", Keyword.get(opts, :session, "HOL"))
  end

  defp call_timeout(:infinity), do: :infinity

  defp call_timeout(timeout) when is_integer(timeout) and timeout >= 0,
    do: timeout + @call_timeout_grace
end
