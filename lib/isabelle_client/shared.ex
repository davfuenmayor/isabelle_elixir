defmodule IsabelleClient.Shared do
  @moduledoc """
  GenServer-backed Isabelle client.

  The process owns command ordering and routes Isabelle async task messages by
  task id, so multiple callers can wait on concurrent Isabelle tasks safely.
  """

  use GenServer

  alias IsabelleClient.Arguments
  alias IsabelleClient.Protocol
  alias IsabelleClient.Protocol.Response
  alias IsabelleClient.Raw
  alias IsabelleClient.Session
  alias IsabelleClient.Task
  alias IsabelleClient.Theory

  @default_timeout 30_000
  @call_timeout_grace 1_000

  defstruct [:client, :reader, pending: [], tasks: %{}]

  @doc """
  Starts a GenServer-backed Isabelle client.

  Pass `:password`, `:host`, and `:port` to connect to an existing Isabelle
  server. Without `:password`, a local server is started. Pass `:session` to
  start an initial session.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

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

  @doc """
  Builds an Isabelle session image and waits for the task result.

  Options:

    * `:on_event` - called with `%{type: type, task: id, body: body}` for
      `:started`, `:note`, `:finished`, and `:failed` task events
  """
  def build_session(server, args, timeout \\ :infinity, opts \\ []),
    do: async_call(server, :build_session, args, timeout, opts)

  @doc """
  Starts an Isabelle session and stores it in the client process.

  The argument list or map is forwarded to Isabelle's `session_start` command,
  which accepts `session_build` arguments (`:session`, `:preferences`,
  `:options`, `:dirs`, `:include_sessions`, `:verbose`) plus `:print_mode`.
  Pass `:label` to store a local label in the resulting session struct. Labels
  are not sent to Isabelle.

  Accepts the same async task options as `build_session/4`.
  """
  def start_session(server, args, timeout \\ :infinity, opts \\ []),
    do: async_call(server, :start_session, args, timeout, opts)

  @doc """
  Stops the active Isabelle session.

  Returns `{:ok, task}` or `{:error, task}` and removes the stopped session from
  the local client stack. Accepts the same async task options as
  `build_session/4`.
  """
  def stop_session(server), do: stop_session(server, :infinity, [])

  def stop_session(server, timeout) when is_integer(timeout) or timeout == :infinity,
    do: stop_session(server, timeout, [])

  def stop_session(server, timeout, opts) when is_integer(timeout) or timeout == :infinity,
    do: GenServer.call(server, {:stop_session, timeout, opts}, call_timeout(timeout))

  def stop_session(server, session_or_id, timeout),
    do: stop_session(server, session_or_id, timeout, [])

  @doc """
  Stops an explicit Isabelle session id or `%IsabelleClient.Session{}`.

  Stopping a non-active session removes it from the local stack without changing
  the active session.
  """
  def stop_session(server, session_or_id, timeout, opts) do
    GenServer.call(server, {:stop_session, session_or_id, timeout, opts}, call_timeout(timeout))
  end

  @doc """
  Checks theories and waits for the task result.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to use another server session explicitly.
  Isabelle `use_theories` arguments are forwarded after key normalization:
  `:session_id`, `:theories`, `:master_dir`, `:pretty_margin`,
  `:unicode_symbols`, `:export_pattern`, `:check_delay`, `:check_limit`,
  `:watchdog_timeout`, and `:nodes_status_delay`.

  Accepts the same async task options as `build_session/4`.
  """
  def use_theories(server, args, timeout \\ :infinity, opts \\ []),
    do: async_call(server, :use_theories, args, timeout, opts)

  @doc """
  Purges theories from a session.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to purge theories from another server session.
  This is a synchronous Isabelle command.
  """
  def purge_theories(server, args, timeout \\ @default_timeout),
    do: GenServer.call(server, {:purge_theories, args, timeout}, call_timeout(timeout))

  @doc """
  Checks an existing `.thy` file.

  By default this uses the active client session. Pass `"session_id"` or
  `:session_id` in the arguments to use another server session explicitly.
  `master_dir` and `theories` are derived from `path` unless supplied. Accepts
  the same async task options as `build_session/4`.
  """
  def check_file(server, path, args \\ [], timeout \\ :infinity, opts \\ []) do
    use_theories(server, Theory.file_args(path, args), timeout, opts)
  end

  @doc """
  Writes and checks a theory.

  If `text` is not a complete theory, it is written as a theory importing
  `Main` with the provided text starting on line 2 of the file. By default this
  uses the active client session. Isabelle offsets are whole-file symbol offsets,
  so the generated header contributes to reported offsets. Pass `"session_id"`
  or `:session_id` in the options to use another server session explicitly.
  """
  def check_text(server, theory, text, opts \\ [], timeout \\ :infinity) do
    GenServer.call(server, {:check_text, theory, text, opts, timeout}, call_timeout(timeout))
  end

  @impl true
  def init(opts) do
    with {:ok, client} <- init_client(opts),
         {:ok, reader} <- start_reader(client.socket) do
      {:ok, %__MODULE__{client: client, reader: reader}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %__MODULE__{client: client, reader: reader}) do
    if reader, do: Process.exit(reader, :normal)
    IsabelleClient.close(client)
    if client.server_name, do: Raw.kill_server(client.server_name)
  end

  @impl true
  def handle_call({:command, name, arg, timeout}, from, state) do
    enqueue_command(state, from, name, arg, {:sync, timeout})
  end

  def handle_call({:async, action, args, timeout, opts}, from, state)
      when action in [:build_session, :start_session] do
    enqueue_async(state, from, action, args, timeout, opts)
  end

  def handle_call({:async, :use_theories = action, args, timeout, opts}, from, state) do
    require_session_args(state, args, fn state ->
      enqueue_async(state, from, action, args, timeout, opts)
    end)
  end

  def handle_call({:stop_session, timeout, opts}, from, state) do
    require_active_session(state, fn %{client: client} = state ->
      session_id = Session.active_id(client)

      enqueue_async(
        state,
        from,
        {:stop_session, session_id},
        %{"session_id" => session_id},
        timeout,
        opts
      )
    end)
  end

  def handle_call({:stop_session, session_or_id, timeout, opts}, from, state) do
    session_id = Session.id(session_or_id)

    enqueue_async(
      state,
      from,
      {:stop_session, session_id},
      %{"session_id" => session_id},
      timeout,
      opts
    )
  end

  def handle_call({:purge_theories, args, timeout}, from, state) do
    require_session_args(state, args, fn %{client: client} = state ->
      {:ok, args} = Session.put_id(args, Session.active_id(client))

      enqueue_command(state, from, "purge_theories", args, {:sync, timeout})
    end)
  end

  def handle_call({:check_text, theory, text, opts, timeout}, from, state) do
    require_session_args(state, opts, fn %{client: client} = state ->
      opts = Arguments.normalize(opts)
      args = Theory.write_args(theory, text, opts, default_master_dir(client, opts))

      enqueue_async(state, from, :use_theories, args, timeout, [])
    end)
  end

  @impl true
  def handle_info({:isabelle_response, response}, state), do: handle_response(response, state)

  def handle_info({:command_timeout, ref}, state) do
    case pop_pending(state.pending, ref) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}

      {request, pending} ->
        GenServer.reply(request.from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:task_timeout, id}, state) do
    case Map.pop(state.tasks, id) do
      {nil, tasks} ->
        {:noreply, %{state | tasks: tasks}}

      {task, tasks} ->
        Protocol.send(state.client.socket, Protocol.command("cancel", %{"task" => id}))
        GenServer.reply(task.from, {:error, :timeout})
        {:noreply, %{state | tasks: tasks}}
    end
  end

  def handle_info({:isabelle_reader_error, reason}, state) do
    fail_waiters(state, reason)
    {:noreply, %{state | pending: [], tasks: %{}}}
  end

  defp async_call(server, action, args, timeout, opts) do
    GenServer.call(server, {:async, action, args, timeout, opts}, call_timeout(timeout))
  end

  defp enqueue_async(%{client: client} = state, from, action, args, timeout, opts) do
    args =
      args
      |> Arguments.normalize()
      |> maybe_session_id(Session.active_id(client), action)

    {action, args} = prepare_async_action(action, args)

    enqueue_command(state, from, command_name(action), args, {:async, action, timeout, opts})
  end

  defp enqueue_command(%{client: client} = state, from, name, arg, kind) do
    case Protocol.send(client.socket, Protocol.command(name, normalize_arg(arg))) do
      :ok ->
        ref = make_ref()
        request = %{ref: ref, from: from, kind: kind, timer: command_timer(kind, ref)}
        {:noreply, %{state | pending: state.pending ++ [request]}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle_response(%Response{type: :note, body: %{"task" => id} = note}, state) do
    case Map.get(state.tasks, id) do
      nil ->
        {:noreply, state}

      task ->
        notify_event(task.on_event, :note, note)

        {:noreply,
         %{state | tasks: Map.put(state.tasks, id, %{task | notes: [note | task.notes]})}}
    end
  end

  defp handle_response(%Response{type: type} = response, state) when type in [:ok, :error] do
    case state.pending do
      [request | pending] ->
        cancel_timer(request.timer)
        finish_command(request, response, %{state | pending: pending})

      [] ->
        {:noreply, state}
    end
  end

  defp handle_response(%Response{type: type, body: %{"task" => id} = result}, state)
       when type in [:finished, :failed] do
    case Map.pop(state.tasks, id) do
      {nil, tasks} ->
        {:noreply, %{state | tasks: tasks}}

      {waiter, tasks} ->
        cancel_timer(waiter.timer)
        notify_event(waiter.on_event, type, result)
        task = finish_task(waiter.task, type, result, waiter.notes)
        {reply, client} = task_reply(waiter.action, task, state.client)
        GenServer.reply(waiter.from, reply)
        {:noreply, %{state | client: client, tasks: tasks}}
    end
  end

  defp handle_response(_response, state), do: {:noreply, state}

  defp finish_command(%{kind: {:sync, _}, from: from}, response, state) do
    GenServer.reply(from, Protocol.ok_body(response))
    {:noreply, state}
  end

  defp finish_command(%{kind: {:async, action, timeout, opts}, from: from}, response, state) do
    with {:ok, id} <- Protocol.task_id(response) do
      waiter = %{
        action: action,
        from: from,
        on_event: Keyword.get(opts, :on_event),
        task: Task.new(id),
        timer: task_timer(id, timeout),
        notes: []
      }

      notify_event(waiter.on_event, :started, %{"task" => id})

      {:noreply, %{state | tasks: Map.put(state.tasks, id, waiter)}}
    else
      {:error, _} ->
        GenServer.reply(from, Protocol.ok_body(response))
        {:noreply, state}
    end
  end

  defp task_reply(
         {:start_session, args, label},
         %Task{status: :finished, result: result} = task,
         client
       ) do
    session = Session.from_result(result, args, label)
    {{:ok, task}, Session.push(client, session)}
  end

  defp task_reply({:stop_session, session_id}, task, client) do
    {task_result(task), Session.remove(client, session_id)}
  end

  defp task_reply(_action, task, client), do: {task_result(task), client}

  defp task_result(%Task{status: :finished} = task), do: {:ok, task}
  defp task_result(%Task{status: :failed} = task), do: {:error, task}

  defp finish_task(task, :finished, result, notes),
    do: %{task | status: :finished, result: result, notes: Enum.reverse(notes)}

  defp finish_task(task, :failed, result, notes),
    do: %{task | status: :failed, result: result, notes: Enum.reverse(notes)}

  defp require_active_session(%{client: %{sessions: []}} = state, _fun),
    do: {:reply, {:error, :no_session}, state}

  defp require_active_session(state, fun), do: fun.(state)

  defp require_session_args(%{client: %{sessions: []}} = state, args, fun) do
    if Session.has_id?(args), do: fun.(state), else: {:reply, {:error, :no_session}, state}
  end

  defp require_session_args(state, _args, fun), do: fun.(state)

  defp maybe_session_id(args, session_id, :use_theories) do
    {:ok, args} = Session.put_id(args, session_id)
    args
  end

  defp maybe_session_id(args, _session_id, _action), do: args

  defp prepare_async_action(:start_session, args) do
    {args, label} = Session.prepare_start_args(args)
    {{:start_session, args, label}, args}
  end

  defp prepare_async_action(action, args), do: {action, args}

  defp command_name(:build_session), do: "session_build"
  defp command_name({:start_session, _args, _label}), do: "session_start"
  defp command_name(:use_theories), do: "use_theories"
  defp command_name({:stop_session, _session_id}), do: "session_stop"

  defp normalize_arg(nil), do: nil
  defp normalize_arg(arg), do: Arguments.normalize(arg)

  defp default_master_dir(client, opts),
    do: Map.get(opts, "master_dir") || Session.default_master_dir(Session.active(client), opts)

  defp command_timer({:sync, timeout}, ref), do: timer({:command_timeout, ref}, timeout)

  defp command_timer({:async, _action, timeout, _opts}, ref),
    do: timer({:command_timeout, ref}, timeout)

  defp task_timer(_id, :infinity), do: nil
  defp task_timer(id, timeout), do: Process.send_after(self(), {:task_timeout, id}, timeout)

  defp timer(_message, :infinity), do: nil
  defp timer(message, timeout), do: Process.send_after(self(), message, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp pop_pending(pending, ref) do
    request = Enum.find(pending, &(&1.ref == ref))
    {request, Enum.reject(pending, &(&1.ref == ref))}
  end

  defp notify_event(nil, _type, _body), do: :ok
  defp notify_event(fun, type, body) when is_function(fun, 1), do: fun.(event(type, body))

  defp event(type, %{"task" => task} = body), do: %{type: type, task: task, body: body}
  defp event(type, body), do: %{type: type, task: nil, body: body}

  defp fail_waiters(state, reason) do
    Enum.each(state.pending, &GenServer.reply(&1.from, {:error, reason}))
    Enum.each(state.tasks, fn {_id, task} -> GenServer.reply(task.from, {:error, reason}) end)
  end

  defp init_client(opts) do
    case Keyword.fetch(opts, :password) do
      {:ok, password} -> connect_existing(password, opts)
      :error -> start_local(opts)
    end
  end

  defp start_local(opts) do
    with {:ok, server} <- IsabelleClient.start_server(opts),
         {:ok, client} <-
           IsabelleClient.connect(server,
             timeout: Keyword.get(opts, :connect_timeout, Keyword.get(opts, :timeout, 30_000))
           ) do
      maybe_start_session(client, opts)
    end
  end

  defp connect_existing(password, opts) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    port = Keyword.get(opts, :port, 9999)
    connect_timeout = Keyword.get(opts, :connect_timeout, Keyword.get(opts, :timeout, 30_000))

    with {:ok, client} <-
           IsabelleClient.connect(password, host: host, port: port, timeout: connect_timeout) do
      maybe_start_session(client, opts)
    end
  end

  defp maybe_start_session(client, opts) do
    if Keyword.has_key?(opts, :session) do
      case IsabelleClient.start_session(
             client,
             Session.args(opts),
             Keyword.get(opts, :timeout, :infinity)
           ) do
        {:ok, client, _task} -> {:ok, client}
        {:error, _reason} = error -> error
      end
    else
      {:ok, client}
    end
  end

  defp start_reader(socket) do
    parent = self()

    reader =
      spawn_link(fn ->
        receive do
          :go -> reader_loop(socket, parent)
        end
      end)

    with :ok <- :gen_tcp.controlling_process(socket, reader) do
      send(reader, :go)
      {:ok, reader}
    end
  end

  defp reader_loop(socket, parent) do
    case Protocol.recv(socket, :infinity) do
      {:ok, response} ->
        send(parent, {:isabelle_response, response})
        reader_loop(socket, parent)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(parent, {:isabelle_reader_error, reason})
    end
  end

  defp call_timeout(:infinity), do: :infinity

  defp call_timeout(timeout) when is_integer(timeout) and timeout >= 0,
    do: timeout + @call_timeout_grace
end
