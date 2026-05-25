# Isabelle Elixir

Elixir clients for the [Isabelle](https://isabelle.in.tum.de/) server.

The library speaks Isabelle's server protocol directly. See Chapter 4 in the [Isabelle system manual](https://isabelle.in.tum.de/doc/system.pdf) for the specification.

## Clients

`IsabelleClient` is the default stateful client. It keeps the socket and current
session in a struct, and awaits asynchronous Isabelle tasks for common session
operations.

`IsabelleClient.Shared` is a `GenServer` wrapper. It owns the socket, so callers
may safely share it across processes while concurrent Isabelle tasks are routed
back to the right caller by task id.

`IsabelleClient.Raw` is the protocol-level client. It exposes the TCP socket,
keeps no session state, and gives you explicit `command/3`, `async_command/3`,
and `await_task/3` helpers.

## Tutorial Livebooks

The notebooks in `livebook_examples/` are intended to be read and run in this
order:

1. `IsabelleClient.livemd` shows the default stateful client for ordinary use:
   start `HOL`, check theory text, inspect messages, and clean up.
2. `IsabelleClientShared.livemd` shows the process-owning client and why it is
   the right choice when multiple Elixir processes share one Isabelle
   connection.
3. `IsabelleClientRaw.livemd` introduces the raw-socket building blocks,
   protocol commands, and explicit task handling.

Together they serve as the tutorial for the library. They start local Isabelle
servers, run smoke tests, build and start a `HOL` session, check theories,
purge, stop, and clean up. The default notebook is the best starting point;
the Shared and Raw notebooks are for concurrency and protocol-level control.

## Setup

The local server helpers read the full Isabelle executable path from
`ISABELLE_TOOL`:

```sh
export ISABELLE_TOOL=/path/to/Isabelle2025-2/bin/isabelle
```

If `ISABELLE_TOOL` is not set, the library falls back to looking up `isabelle`
on `PATH` and stores the resolved path in `ISABELLE_TOOL`.

## Example

Start a local `HOL` session and check theory text:

```elixir
{:ok, task} =
  IsabelleClient.with_session([session: "HOL"], fn client ->
    IsabelleClient.check_text(client, "Example", """
    theorem "x = x"
      sledgehammer
      by simp

    theorem "xs @ [] = xs"
      sledgehammer
      by simp
    """)
  end)

IO.puts(Enum.join(IsabelleClient.messages(task), "\n"))
```

### Messages And Line Filters

`messages/1` returns the user-facing Isabelle node messages as a list of
strings. Use `diagnostics/1` when you need the raw node message maps,
including source positions. `errors/1` returns Isabelle's cumulative
top-level errors plus node-level error messages. When Isabelle attaches
position fields, all result helpers can filter by line and by Isabelle symbol
offset:

```elixir
IsabelleClient.messages(task, line: 5)
IsabelleClient.messages(task, line: 5, offset: 42)
IsabelleClient.diagnostics(task, line: 5)
IsabelleClient.warnings(task, line: 5..10)
IsabelleClient.errors(task, line: [5, 10])
```

`offset: n` matches diagnostics whose `pos.offset..pos.end_offset` range
contains `n`.

### Keyword Arguments

The client accepts Isabelle-style maps and ordinary Elixir keyword arguments:

```elixir
IsabelleClient.start_session(client, session: "HOL")
IsabelleClient.use_theories(client, theories: ["Example"], master_dir: "/tmp")
```

### Typed Results And Sessions

Task results remain raw Isabelle maps for direct access, but common results can
be decoded into small structs:

```elixir
session = IsabelleClient.session(start_task)
typed = IsabelleClient.Result.decode(task)
```

`session` is an `%IsabelleClient.Session{}`. `use_theories` results decode to
`%IsabelleClient.Result.UseTheoriesResult{}` with typed nodes, messages,
positions, and exports.

```elixir
typed = IsabelleClient.use_theories_result(task)
nodes = IsabelleClient.nodes(task)
node = IsabelleClient.node(task, "Draft.Example")
exports = IsabelleClient.exports(task)
top_level_errors = IsabelleClient.top_level_errors(task)
```

Isabelle sessions live in the server independently of a single client
connection. The stateful clients keep an active session for convenience, but
you may pass an explicit session id when using or stopping another session:

```elixir
IsabelleClient.use_theories(client,
  session_id: session.id,
  theories: ["Example"],
  master_dir: "/tmp"
)

IsabelleClient.stop_session(client, session, 120_000)
```

### Checking Files

For existing `.thy` files, `check_file/4` derives the theory name and
`master_dir` from the path:

```elixir
{:ok, task} = IsabelleClient.check_file(client, "/tmp/Example.thy", [], 120_000)
IsabelleClient.messages(task, line: 5)
```

### Shared Clients

Use `IsabelleClient.Shared` when multiple Elixir processes share one Isabelle
connection. It owns the socket and routes async `NOTE` / `FINISHED` / `FAILED`
messages by Isabelle task id. Use `on_event` to receive task lifecycle events,
including notes:

```elixir
{:ok, pid} = IsabelleClient.Shared.start_link(session: "HOL", timeout: 120_000)

parent = self()

task =
  Task.async(fn ->
    IsabelleClient.Shared.use_theories(
      pid,
      [theories: ["Example"], master_dir: "/tmp"],
      120_000,
      on_event: fn event -> send(parent, {:isabelle_event, event}) end
    )
  end)

{:ok, checked} = Task.await(task, 120_000)
IsabelleClient.messages(checked)
```

### Raw Client

Use `IsabelleClient.Raw` when you want direct socket ownership and explicit
task waiting:

```elixir
{:ok, [server]} = IsabelleClient.Raw.new_server("example", 0)
{:ok, socket} = IsabelleClient.Raw.connect(server.password, server.host, server.port)

{:ok, task} = IsabelleClient.Raw.start_session(socket, session: "HOL")
{:ok, task} = IsabelleClient.Raw.await_task(socket, task, 120_000)

session_id = IsabelleClient.extract_session(task)
```
