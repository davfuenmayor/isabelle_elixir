defmodule IsabelleClient do
  @moduledoc """
  Stateful, single-process Isabelle client.

  This is the ergonomic client for scripts and LiveBooks. It keeps the socket
  and current `session_id` in a struct, but it is not meant to be shared by
  multiple concurrent processes. Use `IsabelleClientFull` for that.
  """

  alias IsabelleClient.Result
  alias IsabelleClient.Task

  defstruct [:socket, :session_id]

  @type t :: %__MODULE__{socket: port(), session_id: String.t() | nil}

  @doc "Connects to an Isabelle server and returns a stateful client struct."
  def connect(password, opts \\ []) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 9999)
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, socket} <- IsabelleClientMini.connect(password, host, port, timeout) do
      {:ok, %__MODULE__{socket: socket}}
    end
  end

  @doc "Closes the client's socket."
  def close(%__MODULE__{socket: socket}), do: IsabelleClientMini.close(socket)

  @doc "Runs a synchronous Isabelle command."
  def command(%__MODULE__{socket: socket}, name, arg \\ nil, timeout \\ 30_000) do
    IsabelleClientMini.command(socket, name, arg, timeout)
  end

  @doc "Round-trips a JSON value through Isabelle's `echo` command."
  def echo(client, value), do: command(client, "echo", value)

  @doc "Returns the server command names supported by Isabelle."
  def help(client), do: command(client, "help")

  @doc "Asks the Isabelle server process to shut down."
  def shutdown_server(client), do: command(client, "shutdown")

  @doc "Builds an Isabelle session image and waits for the task result."
  def build_session(%__MODULE__{socket: socket}, args, timeout \\ :infinity) do
    with {:ok, task} <- IsabelleClientMini.build_session(socket, args) do
      IsabelleClientMini.await_task(socket, task, timeout)
    end
  end

  @doc "Starts an Isabelle session, stores its `session_id`, and returns the updated client."
  def start_session(%__MODULE__{socket: socket} = client, args, timeout \\ :infinity) do
    with {:ok, task} <- IsabelleClientMini.start_session(socket, args),
         {:ok, %Task{result: %{"session_id" => session_id}} = task} <-
           IsabelleClientMini.await_task(socket, task, timeout) do
      {:ok, %{client | session_id: session_id}, task}
    end
  end

  @doc "Stops the active Isabelle session and clears `session_id`."
  def stop_session(client, timeout \\ :infinity)

  def stop_session(%__MODULE__{session_id: nil}, _timeout), do: {:error, :no_session}

  def stop_session(
        %__MODULE__{socket: socket, session_id: session_id} = client,
        timeout
      ) do
    with {:ok, task} <- IsabelleClientMini.stop_session(socket, session_id),
         result <- IsabelleClientMini.await_task(socket, task, timeout) do
      case result do
        {:ok, task} -> {:ok, %{client | session_id: nil}, task}
        {:error, task} -> {:error, %{client | session_id: nil}, task}
      end
    end
  end

  @doc "Checks theories in the active session and waits for the task result."
  def use_theories(client, args \\ nil, timeout \\ :infinity)

  def use_theories(%__MODULE__{session_id: nil}, _args, _timeout),
    do: {:error, :no_session}

  def use_theories(
        %__MODULE__{socket: socket, session_id: session_id},
        args,
        timeout
      ) do
    args = args || %{}
    args = Map.put_new(args, "session_id", session_id)

    with {:ok, task} <- IsabelleClientMini.use_theories(socket, args) do
      IsabelleClientMini.await_task(socket, task, timeout)
    end
  end

  @doc "Purges theories from the active session."
  def purge_theories(client, args \\ nil, timeout \\ 30_000)

  def purge_theories(%__MODULE__{session_id: nil}, _args, _timeout), do: {:error, :no_session}

  def purge_theories(%__MODULE__{socket: socket, session_id: session_id}, args, timeout) do
    args = args || %{}
    args = Map.put_new(args, "session_id", session_id)
    IsabelleClientMini.purge_theories(socket, args, timeout)
  end

  @doc "Extracts the `session_id` from a finished session-start task or result map."
  defdelegate extract_session(result), to: Result

  @doc "Extracts user-facing theory messages from a finished `use_theories` task or result map."
  defdelegate extract_results(result), to: Result
end
