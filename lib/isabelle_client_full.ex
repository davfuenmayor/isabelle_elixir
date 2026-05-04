defmodule IsabelleClientFull do
  @moduledoc """
  GenServer-backed Isabelle client.

  The process owns the TCP socket, so callers may safely use the same client
  from multiple processes. Operations are serialized deliberately: Isabelle's
  server can run asynchronous tasks, but a single TCP stream is still easiest
  to reason about when one process owns reads and writes.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def connect(opts), do: start_link(opts)

  def close(server), do: GenServer.stop(server, :normal)

  def command(server, name, arg \\ nil, timeout \\ :infinity),
    do: GenServer.call(server, {:command, name, arg}, timeout)

  def echo(server, value), do: command(server, "echo", value)
  def help(server), do: command(server, "help")
  def shutdown_server(server), do: command(server, "shutdown")

  def build_session(server, args, timeout \\ :infinity),
    do: GenServer.call(server, {:async, :build_session, args}, timeout)

  def start_session(server, args, timeout \\ :infinity),
    do: GenServer.call(server, {:async, :start_session, args}, timeout)

  def stop_session(server, timeout \\ :infinity),
    do: GenServer.call(server, :stop_session, timeout)

  def use_theories(server, args, timeout \\ :infinity),
    do: GenServer.call(server, {:async, :use_theories, args}, timeout)

  def purge_theories(server, args, timeout \\ :infinity),
    do: GenServer.call(server, {:purge_theories, args}, timeout)

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
  def handle_call({:command, name, arg}, _from, client) do
    {:reply, IsabelleClient.command(client, name, arg), client}
  end

  def handle_call({:async, :build_session, args}, _from, client) do
    {:reply, IsabelleClient.build_session(client, args), client}
  end

  def handle_call({:async, :start_session, args}, _from, client) do
    case IsabelleClient.start_session(client, args) do
      {:ok, client, task} -> {:reply, {:ok, task}, client}
      other -> {:reply, other, client}
    end
  end

  def handle_call(:stop_session, _from, client) do
    case IsabelleClient.stop_session(client) do
      {:ok, client, task} -> {:reply, {:ok, task}, client}
      {:error, client, task} -> {:reply, {:error, task}, client}
      other -> {:reply, other, client}
    end
  end

  def handle_call({:async, :use_theories, args}, _from, client) do
    {:reply, IsabelleClient.use_theories(client, args), client}
  end

  def handle_call({:purge_theories, args}, _from, client) do
    {:reply, IsabelleClient.purge_theories(client, args), client}
  end
end
