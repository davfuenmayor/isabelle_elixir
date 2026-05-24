defmodule IsabelleClient do
  @moduledoc """
  Isabelle client for raw-socket and stateful workflows.

  Use raw sockets when you want explicit protocol commands and task polling.
  Use `%IsabelleClient{}` for scripts and LiveBooks that benefit from an active
  session stored in a struct. Neither workflow is meant to be shared by multiple
  concurrent processes; use `IsabelleClient.Shared` for that.
  """

  alias IsabelleClient.Arguments
  alias IsabelleClient.Protocol
  alias IsabelleClient.Protocol.Response
  alias IsabelleClient.Result
  alias IsabelleClient.Session
  alias IsabelleClient.Server
  alias IsabelleClient.Task
  alias IsabelleClient.Theory

  @default_host "127.0.0.1"
  @default_port 9999
  @timeout 30_000

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

    with {:ok, [server]} <- new_server(server_name, server_port),
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
    host = Keyword.get(opts, :host, @default_host)
    port = Keyword.get(opts, :port, @default_port)
    timeout = Keyword.get(opts, :timeout, @timeout)

    with {:ok, socket} <- connect_socket(password, host, port, timeout) do
      {:ok, %__MODULE__{socket: socket}}
    end
  end

  @doc "Starts a local resident Isabelle server via `isabelle server`."
  def new_server(name \\ "elixir", port \\ @default_port), do: Server.start(name, port)

  @doc "Lists local resident Isabelle servers known to Isabelle."
  def list_servers, do: Server.list()

  @doc "Force-kills a local resident Isabelle server by name."
  def kill_server(name), do: Server.kill(name)

  @doc "Connects to an Isabelle server and returns a raw TCP socket."
  def connect_socket(password, host \\ @default_host, port \\ @default_port, timeout \\ @timeout) do
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

  @doc "Closes the client's socket."
  def close(%__MODULE__{socket: socket}), do: close(socket)

  def close(socket) when is_port(socket), do: :gen_tcp.close(socket)

  @doc "Receives one framed Isabelle server response from a raw socket."
  def recv(socket, timeout \\ @timeout) when is_port(socket), do: Protocol.recv(socket, timeout)

  @doc "Runs a synchronous Isabelle command."
  def command(client_or_socket, name, arg \\ nil, timeout \\ @timeout)

  def command(%__MODULE__{socket: socket}, name, arg, timeout) do
    command(socket, name, arg, timeout)
  end

  def command(socket, name, arg, timeout) when is_port(socket) do
    with :ok <- Protocol.send(socket, Protocol.command(name, normalize_command_arg(arg))),
         {:ok, response} <- Protocol.recv(socket, timeout) do
      Protocol.ok_body(response)
    end
  end

  @doc "Round-trips a JSON value through Isabelle's `echo` command."
  def echo(client, value), do: command(client, "echo", value)

  @doc "Returns the server command names supported by Isabelle."
  def help(client), do: command(client, "help")

  @doc "Asks the Isabelle server process to shut down."
  def shutdown_server(client), do: command(client, "shutdown")

  @doc "Requests cancellation of an Isabelle asynchronous task."
  def cancel_task(socket, task_id) when is_port(socket),
    do: command(socket, "cancel", %{"task" => task_id}, @timeout)

  @doc "Starts an asynchronous Isabelle command on a raw socket."
  def async_command(socket, name, arg, timeout \\ @timeout) when is_port(socket) do
    with :ok <- Protocol.send(socket, Protocol.command(name, normalize_command_arg(arg))),
         {:ok, response} <- Protocol.recv(socket, timeout),
         {:ok, task_id} <- Protocol.task_id(response) do
      {:ok, Task.new(task_id)}
    end
  end

  @doc "Waits for an asynchronous Isabelle task on a raw socket to finish or fail."
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

  @doc "Builds an Isabelle session image or starts a raw `session_build` task."
  def build_session(client_or_socket, args, timeout \\ :infinity)

  def build_session(%__MODULE__{socket: socket}, args, timeout) do
    with {:ok, task} <- build_session(socket, args) do
      await_task(socket, task, timeout)
    end
  end

  def build_session(socket, args, _timeout) when is_port(socket),
    do: async_command(socket, "session_build", args)

  @doc "Starts an Isabelle session, storing it for stateful clients."
  def start_session(client_or_socket, args, timeout \\ :infinity)

  def start_session(%__MODULE__{socket: socket} = client, args, timeout) do
    with {:ok, task} <- start_session(socket, args),
         {:ok, %Task{result: %{"session_id" => session_id} = result} = task} <-
           await_task(socket, task, timeout) do
      session = Session.from_result(result)
      {:ok, %{client | session: session, session_id: session_id, tmp_dir: session.tmp_dir}, task}
    end
  end

  def start_session(socket, args, _timeout) when is_port(socket),
    do: async_command(socket, "session_start", args)

  @doc """
  Stops a session.

  With the default arguments, this stops the active session and clears it from
  the client. Pass a `%IsabelleClient.Session{}` or session id to stop another
  server session explicitly.
  """
  def stop_session(client_or_socket, session_or_timeout \\ :active, timeout \\ :infinity)

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

  def stop_session(socket, %Session{id: session_id}, _timeout) when is_port(socket),
    do: stop_session(socket, session_id, :infinity)

  def stop_session(socket, session_id, _timeout) when is_port(socket) and is_binary(session_id),
    do: async_command(socket, "session_stop", %{"session_id" => session_id})

  defp do_stop_session(%__MODULE__{socket: socket} = client, session_id, timeout) do
    with {:ok, task} <- stop_session(socket, session_id),
         result <- await_task(socket, task, timeout) do
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
  def use_theories(client_or_socket, args \\ nil, timeout \\ :infinity)

  def use_theories(
        %__MODULE__{socket: socket} = client,
        args,
        timeout
      ) do
    case Session.put_id(args, client.session_id) do
      {:ok, args} ->
        with {:ok, task} <- use_theories(socket, args) do
          await_task(socket, task, timeout)
        end

      :error ->
        {:error, :no_session}
    end
  end

  def use_theories(socket, args, _timeout) when is_port(socket),
    do: async_command(socket, "use_theories", args)

  @doc """
  Purges theories from a session.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to purge theories from another server session.
  """
  def purge_theories(client_or_socket, args \\ nil, timeout \\ @timeout)

  def purge_theories(%__MODULE__{socket: socket} = client, args, timeout) do
    case Session.put_id(args, client.session_id) do
      {:ok, args} -> purge_theories(socket, args, timeout)
      :error -> {:error, :no_session}
    end
  end

  def purge_theories(socket, args, timeout) when is_port(socket),
    do: command(socket, "purge_theories", args, timeout)

  @doc "Alias for `await_task/3`, useful in raw-socket workflows."
  def poll_status(socket, task_or_id, timeout \\ :infinity)

  def poll_status(socket, %Task{} = task, timeout) when is_port(socket),
    do: await_task(socket, task, timeout)

  def poll_status(socket, task_id, timeout) when is_port(socket) and is_binary(task_id),
    do: await_task(socket, task_id, timeout)

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

    use_theories(
      client,
      Theory.write_args(theory, text, opts, default_master_dir(client, opts)),
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

  defp normalize_command_arg(nil), do: nil
  defp normalize_command_arg(arg), do: Arguments.normalize(arg)

  defp default_master_dir(client, opts),
    do: Map.get(opts, "master_dir") || Session.default_master_dir(client, opts)

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp close_local_session(client, timeout) do
    stop_session(client, timeout)
    shutdown_server(client)
    close(client)
    kill_local_server(client)
  end

  defp kill_local_server(%__MODULE__{server_name: nil}), do: :ok
  defp kill_local_server(%__MODULE__{server_name: name}), do: kill_server(name)
end
