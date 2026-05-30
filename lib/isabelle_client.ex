defmodule IsabelleClient do
  @moduledoc """
  Default stateful Isabelle client.

  Use `%IsabelleClient{}` for scripts and LiveBooks that benefit from a session
  stack in a struct. The active session is the top of `client.sessions`. It is
  not meant to be shared by multiple concurrent processes; use
  `IsabelleClient.Shared` for that. Use `IsabelleClient.Raw` for protocol-level
  socket control.
  """

  alias IsabelleClient.Arguments
  alias IsabelleClient.Raw
  alias IsabelleClient.Result
  alias IsabelleClient.Session
  alias IsabelleClient.Task
  alias IsabelleClient.Theory

  @default_host "127.0.0.1"
  @default_port 9999
  @timeout 30_000

  defstruct [:socket, :server_name, sessions: []]

  @typedoc "Stateful client with one socket and a local stack of Isabelle sessions."
  @type t :: %__MODULE__{
          socket: port(),
          sessions: [Session.t()],
          server_name: String.t() | nil
        }

  @doc """
  Starts a local resident Isabelle server.

  Options:

    * `:server_name` - resident server name, defaults to a unique name
    * `:server_port` - resident server port, defaults to `0`
  """
  def start_server(opts \\ []) do
    server_name = Keyword.get(opts, :server_name, unique_server_name())
    server_port = Keyword.get(opts, :server_port, 0)

    Raw.new_server(server_name, server_port)
  end

  @doc """
  Connects to an Isabelle server and returns a stateful client struct.

  Pass a `%IsabelleClient.Server.Info{}` returned by `start_server/1`, or pass
  the server password with explicit `:host` and `:port` options for an already
  running local or remote server.
  """
  def connect(server_or_password, opts \\ [])

  def connect(%IsabelleClient.Server.Info{} = server, opts) do
    opts = Keyword.merge([host: server.host, port: server.port], opts)

    with {:ok, client} <- connect(server.password, opts) do
      {:ok, %{client | server_name: server.name}}
    end
  end

  def connect(password, opts) do
    host = Keyword.get(opts, :host, @default_host)
    port = Keyword.get(opts, :port, @default_port)
    timeout = Keyword.get(opts, :timeout, @timeout)

    with {:ok, socket} <- Raw.connect(password, host, port, timeout) do
      {:ok, %__MODULE__{socket: socket}}
    end
  end

  @doc "Closes the client's TCP socket."
  def close(%__MODULE__{socket: socket}), do: Raw.close(socket)

  @doc "Runs a synchronous Isabelle command, normalizing Elixir keyword arguments to JSON keys."
  def command(%__MODULE__{socket: socket}, name, arg \\ nil, timeout \\ @timeout),
    do: Raw.command(socket, name, arg, timeout)

  @doc "Round-trips a JSON value through Isabelle's `echo` command."
  def echo(client, value), do: command(client, "echo", value)

  @doc "Returns the server command names supported by Isabelle."
  def help(client), do: command(client, "help")

  @doc "Asks the connected Isabelle server process to shut down."
  def shutdown_server(client), do: command(client, "shutdown")

  @doc """
  Builds an Isabelle session image and waits for the async task result.

  `args` is forwarded to Isabelle's `session_build` command after key
  normalization. Typical keys are `:session`, `:dirs`, `:options`,
  `:include_sessions`, `:preferences`, and `:verbose`.
  """
  def build_session(%__MODULE__{socket: socket}, args, timeout \\ :infinity) do
    with {:ok, task} <- Raw.build_session(socket, args) do
      Raw.await_task(socket, task, timeout)
    end
  end

  @doc """
  Starts an Isabelle session and pushes it onto `client.sessions`.

  The argument list or map is forwarded to Isabelle's `session_start` command,
  which accepts `session_build` arguments (`:session`, `:preferences`,
  `:options`, `:dirs`, `:include_sessions`, `:verbose`) plus `:print_mode`.

  Pass `:label` to store a local label in the resulting session struct. Labels
  are not sent to Isabelle. Returns `{:ok, client, task}`.
  """
  def start_session(%__MODULE__{socket: socket} = client, args, timeout \\ :infinity) do
    {args, label} = Session.prepare_start_args(args)

    with {:ok, task} <- Raw.start_session(socket, args),
         {:ok, %Task{result: %{"session_id" => _} = result} = task} <-
           Raw.await_task(socket, task, timeout) do
      {:ok, Session.push(client, Session.from_result(result, args, label)), task}
    end
  end

  @doc """
  Stops a session.

  With the default arguments, this stops the active session and pops it from
  the client's session stack. Pass a `%IsabelleClient.Session{}` or session id
  to stop another server session explicitly.
  """
  def stop_session(client, session_or_timeout \\ :active, timeout \\ :infinity)

  def stop_session(%__MODULE__{} = client, timeout, :infinity)
      when is_integer(timeout) or timeout == :infinity do
    stop_session(client, :active, timeout)
  end

  def stop_session(%__MODULE__{} = client, :active, timeout) do
    case Session.active_id(client) do
      nil -> {:error, :no_session}
      session_id -> do_stop_session(client, session_id, timeout)
    end
  end

  def stop_session(%__MODULE__{} = client, session_or_id, timeout) do
    do_stop_session(client, Session.id(session_or_id), timeout)
  end

  defp do_stop_session(%__MODULE__{socket: socket} = client, session_id, timeout) do
    with {:ok, task} <- Raw.stop_session(socket, session_id),
         result <- Raw.await_task(socket, task, timeout) do
      client = Session.remove(client, session_id)

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
  Isabelle `use_theories` arguments are forwarded after key normalization:
  `:session_id`, `:theories`, `:master_dir`, `:pretty_margin`,
  `:unicode_symbols`, `:export_pattern`, `:check_delay`, `:check_limit`,
  `:watchdog_timeout`, and `:nodes_status_delay`.

  Returns `{:ok, task}` for a finished Isabelle task, or `{:error, task}` when
  Isabelle reports task failure.
  """
  def use_theories(
        %__MODULE__{socket: socket} = client,
        args \\ nil,
        timeout \\ :infinity
      ) do
    case Session.put_id(args, Session.active_id(client)) do
      {:ok, args} ->
        with {:ok, task} <- Raw.use_theories(socket, args) do
          Raw.await_task(socket, task, timeout)
        end

      :error ->
        {:error, :no_session}
    end
  end

  @doc """
  Purges theories from a session.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to purge theories from another server session.
  This is a synchronous Isabelle command.
  """
  def purge_theories(%__MODULE__{socket: socket} = client, args \\ nil, timeout \\ @timeout) do
    case Session.put_id(args, Session.active_id(client)) do
      {:ok, args} -> Raw.purge_theories(socket, args, timeout)
      :error -> {:error, :no_session}
    end
  end

  @doc """
  Checks an existing `.thy` file.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to use another server session explicitly.
  `master_dir` and `theories` are derived from `path` unless supplied.
  """
  def check_file(client, path, args \\ [], timeout \\ :infinity)

  def check_file(%__MODULE__{} = client, path, args, timeout) do
    use_theories(client, Theory.file_args(path, args), timeout)
  end

  @doc """
  Writes and checks a theory.

  If `text` is not a complete theory, it is written as:

      theory <name> imports Main begin
      <text>
      end

  Use `opts[:imports]` to replace `Main`. The provided text starts on line 2 of
  the written file, so Isabelle diagnostics line up as `text_line + 1`. By
  default this uses the active client session. Isabelle offsets remain
  whole-file symbol offsets: with default `Main`, the snippet starts after
  `27 + String.length(theory)` symbols from the generated header and newline.
  Pass `"session_id"` or `:session_id` in the options to use another server
  session explicitly.
  """
  def check_text(client, theory, text, opts \\ [], timeout \\ :infinity)

  def check_text(%__MODULE__{} = client, theory, text, opts, timeout) do
    opts = Arguments.normalize(opts)

    use_theories(
      client,
      Theory.write_args(theory, text, opts, default_master_dir(client, opts)),
      timeout
    )
  end

  @doc "Extracts the `session_id` from a session struct, session-start task, or result map."
  defdelegate extract_session(result), to: Result

  @doc "Returns the active session from the top of the client's session stack."
  def active_session(%__MODULE__{} = client), do: Session.active(client)

  @doc "Returns the client's session stack, newest session first."
  def sessions(%__MODULE__{sessions: sessions}), do: sessions

  @doc """
  Removes a session from the local client stack without contacting Isabelle.

  Use this when a session was stopped elsewhere, or when Isabelle reports
  `No session ...` for an id still remembered by this client.
  """
  def forget_session(%__MODULE__{} = client, session_or_id),
    do: Session.remove(client, Session.id(session_or_id))

  @doc "Decodes a `use_theories` result or task into a `%IsabelleClient.Result.UseTheoriesResult{}`."
  defdelegate use_theories_result(result), to: Result

  @doc "Decodes a `session_build` result or task into a `%IsabelleClient.Result.SessionBuildResult{}`."
  defdelegate session_build_result(result), to: Result

  @doc "Returns typed theory nodes from a `use_theories` result."
  defdelegate nodes(result), to: Result

  @doc "Finds a typed theory node by `node_name` or `theory_name`."
  defdelegate node(result, name), to: Result

  @doc "Returns typed exports from all theory nodes in a `use_theories` result."
  defdelegate exports(result), to: Result

  @doc "Returns typed top-level error messages from a `use_theories` result."
  defdelegate top_level_errors(result), to: Result
  defdelegate top_level_errors(result, opts), to: Result

  @doc "Returns diagnostic messages from a task, result map, or task notes."
  defdelegate diagnostics(result), to: Result
  defdelegate diagnostics(result, opts), to: Result

  @doc "Returns user-facing message strings from a task, result map, or task notes."
  defdelegate messages(result), to: Result
  defdelegate messages(result, opts), to: Result

  @doc "Returns error messages from a task or result map, with optional position filters."
  defdelegate errors(result), to: Result
  defdelegate errors(result, opts), to: Result

  @doc "Returns warning messages from a task or result map, with optional position filters."
  defdelegate warnings(result), to: Result
  defdelegate warnings(result, opts), to: Result

  defp unique_server_name do
    "isabelle_elixir_#{System.unique_integer([:positive])}"
  end

  defp default_master_dir(client, opts),
    do: Map.get(opts, "master_dir") || Session.default_master_dir(Session.active(client), opts)
end
