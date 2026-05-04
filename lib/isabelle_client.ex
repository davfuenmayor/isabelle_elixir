defmodule IsabelleClient do
  @moduledoc """
  Stateful, single-process Isabelle client.

  This is the ergonomic client for scripts and LiveBooks. It keeps the socket
  and current `session_id` in a struct, but it is not meant to be shared by
  multiple concurrent processes. Use `IsabelleClientFull` for that.
  """

  alias IsabelleClient.Task

  defstruct [:socket, :session_id]

  @type t :: %__MODULE__{socket: port(), session_id: String.t() | nil}

  def connect(password, opts \\ []) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 9999)
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, socket} <- IsabelleClientMini.connect(password, host, port, timeout) do
      {:ok, %__MODULE__{socket: socket}}
    end
  end

  def close(%__MODULE__{socket: socket}), do: IsabelleClientMini.close(socket)

  def command(%__MODULE__{socket: socket}, name, arg \\ nil) do
    IsabelleClientMini.command(socket, name, arg)
  end

  def echo(client, value), do: command(client, "echo", value)
  def help(client), do: command(client, "help")
  def shutdown_server(client), do: command(client, "shutdown")

  def build_session(%__MODULE__{socket: socket}, args, timeout \\ :infinity) do
    with {:ok, task} <- IsabelleClientMini.build_session(socket, args) do
      IsabelleClientMini.await_task(socket, task, timeout)
    end
  end

  def start_session(%__MODULE__{socket: socket} = client, args, timeout \\ :infinity) do
    with {:ok, task} <- IsabelleClientMini.start_session(socket, args),
         {:ok, %Task{result: %{"session_id" => session_id}} = task} <-
           IsabelleClientMini.await_task(socket, task, timeout) do
      {:ok, %{client | session_id: session_id}, task}
    end
  end

  def stop_session(%__MODULE__{session_id: nil}), do: {:error, :no_session}

  def stop_session(
        %__MODULE__{socket: socket, session_id: session_id} = client,
        timeout \\ :infinity
      ) do
    with {:ok, task} <- IsabelleClientMini.stop_session(socket, session_id),
         result <- IsabelleClientMini.await_task(socket, task, timeout) do
      case result do
        {:ok, task} -> {:ok, %{client | session_id: nil}, task}
        {:error, task} -> {:error, %{client | session_id: nil}, task}
      end
    end
  end

  def use_theories(client, args \\ nil, timeout \\ :infinity)

  def use_theories(%__MODULE__{session_id: nil}, _args, _timeout),
    do: {:error, :no_session}

  def use_theories(
        %__MODULE__{socket: socket, session_id: session_id},
        args,
        timeout
      ) do
    args = Map.put_new(args, "session_id", session_id)

    with {:ok, task} <- IsabelleClientMini.use_theories(socket, args) do
      IsabelleClientMini.await_task(socket, task, timeout)
    end
  end

  def purge_theories(%__MODULE__{session_id: nil}), do: {:error, :no_session}
  def purge_theories(%__MODULE__{session_id: nil}, _args), do: {:error, :no_session}

  def purge_theories(%__MODULE__{socket: socket, session_id: session_id}, args) do
    args = Map.put_new(args, "session_id", session_id)
    IsabelleClientMini.purge_theories(socket, args)
  end
end
