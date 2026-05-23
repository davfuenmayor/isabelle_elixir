defmodule IsabelleClient do
  @moduledoc """
  Stateful, single-process Isabelle client.

  This is the ergonomic client for scripts and LiveBooks. It keeps the socket
  and current `session_id` in a struct, but it is not meant to be shared by
  multiple concurrent processes. Use `IsabelleClientFull` for that.
  """

  alias IsabelleClient.Arguments
  alias IsabelleClient.Result
  alias IsabelleClient.Task

  defstruct [:socket, :session_id, :tmp_dir, :server_name]

  @type t :: %__MODULE__{
          socket: port(),
          session_id: String.t() | nil,
          tmp_dir: String.t() | nil,
          server_name: String.t() | nil
        }

  @doc """
  Starts a local Isabelle server, connects to it, and starts a session.

  Options:

    * `:session` - Isabelle session name, defaults to `"HOL"`
    * `:session_args` - additional `session_start` arguments
    * `:server_name` - resident server name, defaults to a unique name
    * `:server_port` - resident server port, defaults to `0`
    * `:connect_timeout` - TCP/authentication timeout, defaults to `30_000`
    * `:timeout` - session startup timeout, defaults to `:infinity`
  """
  def start(opts \\ []) do
    server_name = Keyword.get(opts, :server_name, unique_server_name())
    server_port = Keyword.get(opts, :server_port, 0)
    connect_timeout = Keyword.get(opts, :connect_timeout, 30_000)
    timeout = Keyword.get(opts, :timeout, :infinity)

    with {:ok, [server]} <- IsabelleClientMini.new_server(server_name, server_port),
         {:ok, client} <-
           connect(server["password"],
             host: server["host"],
             port: server["port"],
             timeout: connect_timeout
           ) do
      client = %{client | server_name: server["name"]}

      case start_session(client, session_args(opts), timeout) do
        {:ok, _client, _task} = ok ->
          ok

        error ->
          close_local_session(client, timeout)
          error
      end
    end
  end

  @doc "Runs a function with a fresh local Isabelle session, then stops and shuts it down."
  def with_session(fun) when is_function(fun), do: with_session([], fun)

  def with_session(opts, fun) when is_function(fun) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    with {:ok, client, _task} <- start(opts) do
      try do
        fun.(client)
      after
        close_local_session(client, timeout)
      end
    end
  end

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
         {:ok, %Task{result: %{"session_id" => session_id} = result} = task} <-
           IsabelleClientMini.await_task(socket, task, timeout) do
      {:ok, %{client | session_id: session_id, tmp_dir: Map.get(result, "tmp_dir")}, task}
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
        {:ok, task} -> {:ok, %{client | session_id: nil, tmp_dir: nil}, task}
        {:error, task} -> {:error, %{client | session_id: nil, tmp_dir: nil}, task}
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
    args = Arguments.normalize(args)
    args = Map.put_new(args, "session_id", session_id)

    with {:ok, task} <- IsabelleClientMini.use_theories(socket, args) do
      IsabelleClientMini.await_task(socket, task, timeout)
    end
  end

  @doc "Purges theories from the active session."
  def purge_theories(client, args \\ nil, timeout \\ 30_000)

  def purge_theories(%__MODULE__{session_id: nil}, _args, _timeout), do: {:error, :no_session}

  def purge_theories(%__MODULE__{socket: socket, session_id: session_id}, args, timeout) do
    args = Arguments.normalize(args)
    args = Map.put_new(args, "session_id", session_id)
    IsabelleClientMini.purge_theories(socket, args, timeout)
  end

  @doc "Checks an existing `.thy` file in the active session."
  def check_file(client, path, args \\ [], timeout \\ :infinity)

  def check_file(%__MODULE__{} = client, path, args, timeout) do
    args =
      args
      |> Arguments.normalize()
      |> Map.put_new("master_dir", Path.dirname(path))
      |> Map.put_new("theories", [path |> Path.basename() |> Path.rootname()])

    use_theories(client, args, timeout)
  end

  @doc """
  Writes and checks a theory in the active session.

  If `text` is not a complete theory, it is wrapped as a theory body importing
  `Main`, or `opts[:imports]` when provided.
  """
  def check_text(client, theory, text, opts \\ [], timeout \\ :infinity)

  def check_text(%__MODULE__{} = client, theory, text, opts, timeout) do
    opts = Arguments.normalize(opts)
    master_dir = Map.get(opts, "master_dir") || client.tmp_dir || fresh_tmp_dir()
    File.mkdir_p!(master_dir)

    source = theory_source(theory, text, Map.get(opts, "imports", "Main"))
    File.write!(Path.join(master_dir, theory_file(theory)), source)

    use_theories(
      client,
      opts
      |> Map.delete("imports")
      |> Map.put_new("master_dir", master_dir)
      |> Map.put_new("theories", [theory]),
      timeout
    )
  end

  @doc "Extracts the `session_id` from a finished session-start task or result map."
  defdelegate extract_session(result), to: Result

  @doc "Returns user-facing messages from a `use_theories` task or result map."
  defdelegate messages(result), to: Result

  @doc "Returns error messages from a `use_theories` task or result map."
  defdelegate errors(result), to: Result

  @doc "Returns warning messages from a `use_theories` task or result map."
  defdelegate warnings(result), to: Result

  @doc "Extracts user-facing theory messages from a finished `use_theories` task or result map."
  defdelegate extract_results(result), to: Result

  defp session_args(opts) do
    opts
    |> Keyword.get(:session_args, [])
    |> Arguments.normalize()
    |> Map.put_new("session", Keyword.get(opts, :session, "HOL"))
  end

  defp theory_source(theory, text, imports) do
    if Regex.match?(~r/\A\s*theory\s+/u, text) do
      text
    else
      """
      theory #{theory} imports #{imports}
      begin

      #{text}

      end
      """
    end
  end

  defp theory_file(theory) do
    theory
    |> String.split(".")
    |> List.last()
    |> Kernel.<>(".thy")
  end

  defp fresh_tmp_dir do
    Path.join(System.tmp_dir!(), "isabelle_elixir_#{System.unique_integer([:positive])}")
  end

  defp unique_server_name do
    "isabelle_elixir_#{System.unique_integer([:positive])}"
  end

  defp close_local_session(client, timeout) do
    stop_session(client, timeout)
    shutdown_server(client)
    close(client)
    kill_local_server(client)
  end

  defp kill_local_server(%__MODULE__{server_name: nil}), do: :ok
  defp kill_local_server(%__MODULE__{server_name: name}), do: IsabelleClientMini.kill_server(name)
end
