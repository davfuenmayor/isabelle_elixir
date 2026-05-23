defmodule IsabelleClientFull do
  @moduledoc """
  GenServer-backed Isabelle client.

  The process owns command ordering and routes Isabelle async task messages by
  task id, so multiple callers can wait on concurrent Isabelle tasks safely.
  """

  use GenServer

  alias IsabelleClient.Arguments
  alias IsabelleClient.Protocol
  alias IsabelleClient.Protocol.Response
  alias IsabelleClient.Task

  @default_timeout 30_000
  @call_timeout_grace 1_000

  defstruct [:client, :reader, pending: [], tasks: %{}]

  @doc "Starts a GenServer-backed Isabelle client."
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

  @doc "Builds an Isabelle session image and waits for the task result."
  def build_session(server, args, timeout \\ :infinity, opts \\ []),
    do: async_call(server, :build_session, args, timeout, opts)

  @doc "Starts an Isabelle session and stores its `session_id` in the client process."
  def start_session(server, args, timeout \\ :infinity, opts \\ []),
    do: async_call(server, :start_session, args, timeout, opts)

  @doc "Stops the active Isabelle session."
  def stop_session(server, timeout \\ :infinity, opts \\ []),
    do: GenServer.call(server, {:stop_session, timeout, opts}, call_timeout(timeout))

  @doc "Checks theories in the active session and waits for the task result."
  def use_theories(server, args, timeout \\ :infinity, opts \\ []),
    do: async_call(server, :use_theories, args, timeout, opts)

  @doc "Purges theories from the active session."
  def purge_theories(server, args, timeout \\ @default_timeout),
    do: GenServer.call(server, {:purge_theories, args, timeout}, call_timeout(timeout))

  @doc "Checks an existing `.thy` file in the active session."
  def check_file(server, path, args \\ [], timeout \\ :infinity, opts \\ []) do
    args =
      args
      |> Arguments.normalize()
      |> Map.put_new("master_dir", Path.dirname(path))
      |> Map.put_new("theories", [path |> Path.basename() |> Path.rootname()])

    use_theories(server, args, timeout, opts)
  end

  @doc "Writes and checks a theory in the active session."
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
    if client.server_name, do: IsabelleClientMini.kill_server(client.server_name)
  end

  @impl true
  def handle_call({:command, name, arg, timeout}, from, state) do
    enqueue_command(state, from, name, arg, {:sync, timeout})
  end

  def handle_call({:async, action, args, timeout, opts}, from, state)
      when action in [:build_session, :start_session] do
    enqueue_async(state, from, action, args, timeout, opts)
  end

  def handle_call({:async, action, args, timeout, opts}, from, state) do
    with_session(state, fn state ->
      enqueue_async(state, from, action, args, timeout, opts)
    end)
  end

  def handle_call({:stop_session, timeout, opts}, from, state) do
    with_session(state, fn %{client: client} = state ->
      enqueue_async(
        state,
        from,
        :stop_session,
        %{"session_id" => client.session_id},
        timeout,
        opts
      )
    end)
  end

  def handle_call({:purge_theories, args, timeout}, from, state) do
    with_session(state, fn %{client: client} = state ->
      args = args |> Arguments.normalize() |> Map.put_new("session_id", client.session_id)
      enqueue_command(state, from, "purge_theories", args, {:sync, timeout})
    end)
  end

  def handle_call({:check_text, theory, text, opts, timeout}, from, state) do
    with_session(state, fn %{client: client} = state ->
      opts = Arguments.normalize(opts)
      master_dir = Map.get(opts, "master_dir") || client.tmp_dir || fresh_tmp_dir()
      File.mkdir_p!(master_dir)

      File.write!(
        Path.join(master_dir, theory_file(theory)),
        theory_source(theory, text, Map.get(opts, "imports", "Main"))
      )

      args =
        opts
        |> Map.delete("imports")
        |> Map.put_new("master_dir", master_dir)
        |> Map.put_new("theories", [theory])

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
      |> maybe_session_id(client.session_id, action)

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
        notify(task.on_note, note)

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
        on_note: Keyword.get(opts, :on_note),
        task: Task.new(id),
        timer: task_timer(id, timeout),
        notes: []
      }

      {:noreply, %{state | tasks: Map.put(state.tasks, id, waiter)}}
    else
      {:error, _} ->
        GenServer.reply(from, Protocol.ok_body(response))
        {:noreply, state}
    end
  end

  defp task_reply(:start_session, %Task{status: :finished, result: result} = task, client) do
    client = %{client | session_id: result["session_id"], tmp_dir: result["tmp_dir"]}
    {{:ok, task}, client}
  end

  defp task_reply(:stop_session, task, client) do
    {task_result(task), %{client | session_id: nil, tmp_dir: nil}}
  end

  defp task_reply(_action, task, client), do: {task_result(task), client}

  defp task_result(%Task{status: :finished} = task), do: {:ok, task}
  defp task_result(%Task{status: :failed} = task), do: {:error, task}

  defp finish_task(task, :finished, result, notes),
    do: %{task | status: :finished, result: result, notes: Enum.reverse(notes)}

  defp finish_task(task, :failed, result, notes),
    do: %{task | status: :failed, result: result, notes: Enum.reverse(notes)}

  defp with_session(%{client: %{session_id: nil}} = state, _fun),
    do: {:reply, {:error, :no_session}, state}

  defp with_session(state, fun), do: fun.(state)

  defp maybe_session_id(args, session_id, action) when action in [:use_theories],
    do: Map.put_new(args, "session_id", session_id)

  defp maybe_session_id(args, _session_id, _action), do: args

  defp command_name(:build_session), do: "session_build"
  defp command_name(:start_session), do: "session_start"
  defp command_name(:use_theories), do: "use_theories"
  defp command_name(:stop_session), do: "session_stop"

  defp normalize_arg(nil), do: nil
  defp normalize_arg(arg), do: Arguments.normalize(arg)

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

  defp notify(nil, _note), do: :ok
  defp notify(fun, note) when is_function(fun, 1), do: fun.(note)

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
    case IsabelleClient.start(opts) do
      {:ok, client, _task} -> {:ok, client}
      {:error, _reason} = error -> error
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
             session_args(opts),
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

  defp theory_file(theory), do: theory |> String.split(".") |> List.last() |> Kernel.<>(".thy")

  defp fresh_tmp_dir,
    do: Path.join(System.tmp_dir!(), "isabelle_elixir_#{System.unique_integer([:positive])}")

  defp call_timeout(:infinity), do: :infinity

  defp call_timeout(timeout) when is_integer(timeout) and timeout >= 0,
    do: timeout + @call_timeout_grace
end
