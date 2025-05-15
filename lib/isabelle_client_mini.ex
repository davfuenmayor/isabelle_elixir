defmodule IsabelleClientMini do
  @moduledoc """
  **Minimalistic stateless Elixir client for the Isabelle Server**

  This module wraps the Isabelle Server command‑line tools (`isabelle server`,
  `isabelle client`) and its TCP protocol (see *Isabelle System Manual*,
  Chapter 4 under https://isabelle.in.tum.de/doc/system.pdf) in a set of
  synchronous helper functions that remain completely stateless. You can use
  these to spin up a resident server, connect to it, fire high‑level
  commands (`session_start`, `use_theories`, …) and consume the streamed
  results without having to parse the Isabelle wire protocol yourself.


  ### Typical lifecycle

  1. (optionally) **Start** a resident server with `new_server/2` (or reuse
     an existing one found via `list_servers/0`). Both commands require a
     local Isabelle installation whose *`bin/`* directory is on the `PATH`.
  2. **Connect** using the password/token reported by the server (`connect/3`).
     The corresponding Isabelle server only needs to be accessible via TCP.
  3. **Launch** a session once per logic image (`start_session/2`).
  4. **Edit/compile** theories with `use_theories/2`, polling for
     `FINISHED | FAILED | NOTE` messages via `poll_status/2`.
  5. **Extract** results or artefacts with helpers such as `extract_results/1`.
  6. **Stop** the session (`stop_session/2`).
  7. (optionally) **Shutdown** the server (`shutdown_server/1`).
     If running Isabelle locally you can alternatively use `kill_server/1`.


  ### Caveats

  * The client is intentionally **stateless** — it does **not** keep
    supervision trees, reconnect, or monitor server liveness for you.  Compose
    it inside your own supervision strategy if you need robustness.
  * Network I/O is done via `:gen_tcp` in passive mode; all helpers block the
    calling process.  For high‑latency sessions consider running them inside
    a dedicated Task or GenServer.
  """

  @default_name "elixir"
  @default_host "127.0.0.1"
  @default_port 9999
  @isabelle_exec "isabelle"
  @timeout 7_000
  @newline "\n"

  #
  # ---------------------------------------------------------------------------
  # Shell helpers (wrap `isabelle server` CLI)
  # ---------------------------------------------------------------------------

  @doc """
  Spawn a **resident Isabelle Server** in the background.

  The function runs `isabelle server -n <name> -p <port>` via an Erlang port,
  waits for its first line of output, parses the server descriptor and then
  closes the port (leaving the JVM process running detached).
  Note that if you want to start (and list) Isabelle servers programmatically
  (via the functions: new_server and list_servers) you have to make sure
  that the "bin" directory in your Isabelle installation is in the PATH.

  ## Parameters
  * `name` – arbitrary label used to identify the server in `list_servers/0`.
    Defaults to `"#{@default_name}"`.
  * `port` – TCP port on which the server accepts connections. Defaults to
    `#{@default_port}`.

  ## Return value
  `[%{"name" => name, "host" => host, "port" => port, "password" => pw}]` on
  success, or `{:error, reason}` on failure / timeout.
  """
  def new_server(name \\ @default_name, port \\ @default_port) do
    port =
      Port.open({:spawn_executable, System.find_executable(@isabelle_exec)}, [
        :binary,
        args: ["server", "-n", name, "-p", to_string(port)]
      ])

    result =
      receive do
        {^port, {:data, data}} -> parse_server_info(data)
      after
        @timeout -> {:error, "timeout"}
      end

    Port.close(port)
    result
  end

  @doc """
  List **all locally running Isabelle servers**. Under the hood this simply invokes
  `isabelle server -l` and parses its stdout. Same caveat apply as with `new_server/2`.
  """
  def list_servers() do
    {data, 0} = System.cmd("isabelle", ["server", "-l"], stderr_to_stdout: true)
    parse_server_info(data)
  end

  @doc """
  Force‑terminate a named Isabelle server **process** via the CLI
  (`isabelle server -n <name> -x`). In case you really want to kill the Isabelle server,
   you can use this as a last resort if a clean `shutdown` over the TCP protocol is impossible.
  """
  def kill_server(name) do
    System.cmd("isabelle", ["server", "-n", name, "-x"], stderr_to_stdout: true)
  end

  # ---------------------------------------------------------------------------
  # TCP helpers
  # ---------------------------------------------------------------------------

  @doc """
  Send a `shutdown` command over the given socket, causing the **server
  process itself** to exit (all connected sessions will be dropped).
  """
  def shutdown_server(socket), do: cmd_sync(socket, "shutdown")

  @doc """
  Open a TCP connection to an Isabelle server and perform the initial password
  handshake.

  ## Parameters
  * `password` – token obtained from the server descriptor (returned by
    `new_server/2` or `list_servers/0` if running locally).
  * `host` – IPv4 address as string (default `#{@default_host}`).
  * `port` – TCP port (default `#{@default_port}`).

  ## Return value
  * `socket` – a live socket ready for further commands.
  * `{:error, reason}` on connection failures.
  """
  def connect(password, host_str \\ @default_host, port \\ @default_port) do
    with host = to_charlist(host_str),
         {:ok, socket} <-
           :gen_tcp.connect(host, port, [:binary, active: false, nodelay: true], @timeout),
         :ok <- :gen_tcp.send(socket, password <> @newline),
         {:ok, "OK" <> _} <- :gen_tcp.recv(socket, 0, @timeout) do
      socket
    end
  end

  @doc "Close a previously opened TCP connection."
  def close(socket), do: :gen_tcp.close(socket)

  @doc """
  Round‑trip test helper that sends `echo <json>` and returns the decoded value.
  Useful for verifying the connection.
  """
  def echo(socket, value), do: cmd_sync(socket, "echo " <> JSON.encode!(value))

  @doc "Return the list of command names supported by the server (`help`)."
  def help(socket), do: cmd_sync(socket, "help")

  @doc "Cancel a running asynchronous *task* (identified by its UUID)."
  def cancel_task(socket, task_id),
    do: cmd_sync(socket, "cancel " <> JSON.encode!(%{"task" => task_id}))

  @doc "Build session images (wrapper around `session_build`)."
  def build_session(socket, session_args),
    do: cmd_sync(socket, "session_build " <> JSON.encode!(session_args))

  @doc "Start an Isabelle PIDE session, implicitly building images if needed."
  def start_session(socket, session_args),
    do: cmd_sync(socket, "session_start " <> JSON.encode!(session_args))

  @doc "Gracefully stop a running session (`session_stop`)."
  def stop_session(socket, session_id),
    do: cmd_sync(socket, "session_stop " <> JSON.encode!(%{"session_id" => session_id}))

  @doc "Load / re‑load theories into the session (`use_theories`)."
  def use_theories(socket, use_theories_args),
    do: cmd_sync(socket, "use_theories " <> JSON.encode!(use_theories_args))

  @doc "Purge theories from heap to reclaim memory (`purge_theories`)."
  def purge_theories(socket, purge_theories_args),
    do: cmd_sync(socket, "purge_theories " <> JSON.encode!(purge_theories_args))

  @doc """
  Recursively poll the socket until the server finishes an async task.

  The function returns **immediately** when it encounters one of the following
  conditions in the buffered stream:

  * `{:finished, ...}` – successful result (see `extract_results/1`).
  * `{:failed, ...}`   – task failed.
  * `{:error, reason}` – protocol mismatch / time‑out / empty buffer.

  Internally it keeps a growing accumulator so you don't lose any partial
  chunks.
  """
  def poll_status(socket, acc \\ <<>>) do
    data = recv_full(socket, acc)

    lines =
      data
      |> String.trim()
      |> String.split("\n")
      |> Enum.filter(fn l -> !match?({_num, ""}, Integer.parse(l)) end)

    status =
      for line <- lines do
        case extract_payload(line, "NOTE") do
          {:error, _} ->
            case extract_payload(line, "FINISHED") do
              {:error, _} ->
                extract_payload(line, "FAILED")

              result ->
                result
            end

          result ->
            result
        end
      end

    cond do
      String.trim(data) == "" -> {:error, "nothing in buffer... wait a bit"}
      Keyword.has_key?(status, :error) -> {:error, Keyword.fetch!(status, :error)}
      Keyword.has_key?(status, :finished) -> status
      Keyword.has_key?(status, :failed) -> status
      true -> poll_status(socket, data)
    end
  end

  @doc "Extract the plain‑text messages from a `:finished` status keyword list."
  def extract_results(status) do
    status
    |> Keyword.fetch!(:finished)
    |> Map.fetch!("nodes")
    |> Enum.at(0)
    |> Map.fetch!("messages")
    |> Enum.map(&Map.fetch!(&1, "message"))
    |> Enum.join("\n")
  end

  @doc "Grab the `session_id` UUID from a `:finished` status keyword list."
  def extract_session(status) do
    Keyword.fetch!(status, :finished)["session_id"]
  end

  # ---------------------------------------------------------------------------
  # Internal helpers (private)
  # ---------------------------------------------------------------------------

  defp recv_full(socket, acc) do
    case :gen_tcp.recv(socket, 0, 10) do
      {:ok, chunk} -> recv_full(socket, acc <> chunk)
      {:error, :timeout} -> acc
      {:error, :closed} -> acc
      {:error, reason} -> {:error, reason}
    end
  end

  defp cmd_sync(socket, cmd) do
    _drainage = recv_full(socket, <<>>)

    with :ok <- :gen_tcp.send(socket, cmd <> @newline),
         {:ok, info} <- :gen_tcp.recv(socket, 0, @timeout) do
      extract_payload(info, "OK")
    end
  end

  defp extract_payload(str, cmd) do
    payload = str |> String.trim() |> String.split(cmd, parts: 2) |> Enum.at(1)

    if payload == nil do
      {:error, "result didn't match #{cmd}"}
    else
      status = cmd |> String.downcase() |> String.to_atom()
      trimmed = String.trim(payload)
      if trimmed == "", do: status, else: {status, JSON.decode!(trimmed)}
    end
  end

  defp parse_server_info(data) do
    regex = ~r/
        server\s+'(?<name>[^']+)'              # extract server name
        \s*=\s*
        (?<host>\d{1,3}(?:\.\d{1,3}){3})       # extract host
        :(?<port>\d+)                          # extract port
        \s+\(password\s+'(?<password>[^']+)'\) # extract password
      /x

    data
    |> String.trim()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.replace(&1, "\"", "'"))
    |> Enum.map(&Regex.named_captures(regex, &1))
  end
end
