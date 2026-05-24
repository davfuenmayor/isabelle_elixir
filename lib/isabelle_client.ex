defmodule IsabelleClient do
  @moduledoc """
  Stateful, single-process Isabelle client.

  This is the ergonomic client for scripts and LiveBooks. It keeps the socket
  and current session in a struct, but it is not meant to be shared by
  multiple concurrent processes. Use `IsabelleClientFull` for that.
  """

  alias IsabelleClient.Arguments
  alias IsabelleClient.Result
  alias IsabelleClient.Session
  alias IsabelleClient.Task
  alias IsabelleClient.Theory

  defstruct [:socket, :session, :session_id, :tmp_dir, :server_name]

  @type t :: %__MODULE__{
          socket: port(),
          session: Session.t() | nil,
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
           connect(server.password,
             host: server.host,
             port: server.port,
             timeout: connect_timeout
           ) do
      client = %{client | server_name: server.name}

      case start_session(client, Session.args(opts), timeout) do
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
      session = Session.from_result(result)
      {:ok, %{client | session: session, session_id: session_id, tmp_dir: session.tmp_dir}, task}
    end
  end

  @doc """
  Stops a session.

  With the default arguments, this stops the active session and clears it from
  the client. Pass a `%IsabelleClient.Session{}` or session id to stop another
  server session explicitly.
  """
  def stop_session(client, session_or_timeout \\ :active, timeout \\ :infinity)

  def stop_session(%__MODULE__{} = client, timeout, :infinity)
      when is_integer(timeout) or timeout == :infinity do
    stop_session(client, :active, timeout)
  end

  def stop_session(%__MODULE__{} = client, :active, timeout) do
    case client.session_id do
      nil -> {:error, :no_session}
      session_id -> do_stop_session(client, session_id, timeout)
    end
  end

  def stop_session(%__MODULE__{} = client, session_or_id, timeout) do
    do_stop_session(client, Session.id(session_or_id), timeout)
  end

  defp do_stop_session(%__MODULE__{socket: socket} = client, session_id, timeout) do
    with {:ok, task} <- IsabelleClientMini.stop_session(socket, session_id),
         result <- IsabelleClientMini.await_task(socket, task, timeout) do
      client = Session.clear_active(client, session_id)

      case result do
        {:ok, task} -> {:ok, client, task}
        {:error, task} -> {:error, client, task}
      end
    end
  end

  @doc """
  Checks theories and waits for the task result.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to use another server session explicitly.
  """
  def use_theories(client, args \\ nil, timeout \\ :infinity)

  def use_theories(
        %__MODULE__{socket: socket} = client,
        args,
        timeout
      ) do
    args = Arguments.normalize(args)

    case Session.put_id(args, client.session_id) do
      {:ok, args} ->
        with {:ok, task} <- IsabelleClientMini.use_theories(socket, args) do
          IsabelleClientMini.await_task(socket, task, timeout)
        end

      :error ->
        {:error, :no_session}
    end
  end

  @doc """
  Purges theories from a session.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to purge theories from another server session.
  """
  def purge_theories(client, args \\ nil, timeout \\ 30_000)

  def purge_theories(%__MODULE__{socket: socket} = client, args, timeout) do
    args = Arguments.normalize(args)

    case Session.put_id(args, client.session_id) do
      {:ok, args} -> IsabelleClientMini.purge_theories(socket, args, timeout)
      :error -> {:error, :no_session}
    end
  end

  @doc """
  Checks an existing `.thy` file.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to use another server session explicitly.
  """
  def check_file(client, path, args \\ [], timeout \\ :infinity)

  def check_file(%__MODULE__{} = client, path, args, timeout) do
    use_theories(client, Theory.file_args(path, args), timeout)
  end

  @doc """
  Writes and checks a theory.

  If `text` is not a complete theory, it is wrapped as a theory body importing
  `Main`, or `opts[:imports]` when provided. By default this uses the active
  client session. Pass `"session_id"` or `:session_id` in the options to use
  another server session explicitly.
  """
  def check_text(client, theory, text, opts \\ [], timeout \\ :infinity)

  def check_text(%__MODULE__{} = client, theory, text, opts, timeout) do
    opts = Arguments.normalize(opts)
    master_dir = Map.get(opts, "master_dir") || Session.default_master_dir(client, opts)
    File.mkdir_p!(master_dir)

    File.write!(
      Path.join(master_dir, Theory.file(theory)),
      Theory.source(theory, text, Map.get(opts, "imports", "Main"))
    )

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

  @doc "Returns a typed session struct from a session-start task or result map."
  def session(%Task{result: result}), do: session(result)
  def session(result), do: Session.from_result(result)

  @doc "Returns a structured `use_theories` result, or `nil` for another result shape."
  defdelegate use_theories_result(result), to: Result

  @doc "Returns typed theory nodes from a `use_theories` result."
  defdelegate nodes(result), to: Result

  @doc "Finds a typed theory node by `node_name` or `theory_name`."
  defdelegate node(result, name), to: Result

  @doc "Returns typed exports from all theory nodes in a `use_theories` result."
  defdelegate exports(result), to: Result

  @doc "Returns typed top-level error messages from a `use_theories` result."
  defdelegate top_level_errors(result), to: Result
  defdelegate top_level_errors(result, opts), to: Result

  @doc "Returns diagnostic messages from a `use_theories` task or result."
  defdelegate diagnostics(result), to: Result
  defdelegate diagnostics(result, opts), to: Result

  @doc "Returns user-facing messages from a `use_theories` task or result map."
  defdelegate messages(result), to: Result
  defdelegate messages(result, opts), to: Result

  @doc "Returns error messages from a `use_theories` task or result map."
  defdelegate errors(result), to: Result
  defdelegate errors(result, opts), to: Result

  @doc "Returns warning messages from a `use_theories` task or result map."
  defdelegate warnings(result), to: Result
  defdelegate warnings(result, opts), to: Result

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
