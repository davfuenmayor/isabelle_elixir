# Isabelle Elixir

Elixir clients for the [Isabelle](https://isabelle.in.tum.de/) server.

The library speaks Isabelle's server protocol directly. See Chapter 4 in the [Isabelle system manual](https://isabelle.in.tum.de/doc/system.pdf) for the specification.

## Clients

`IsabelleClientMini` is the low-level building block. It is stateless, exposes
the TCP socket, and gives you explicit `command/3`, `async_command/3`, and
`await_task/3` helpers.

`IsabelleClient` is the default client for scripts and notebooks. It keeps the
socket and current `session_id` in a struct, and awaits asynchronous Isabelle
tasks for the common session workflow.

`IsabelleClientFull` is a `GenServer` wrapper. It owns the socket, so callers
may safely share it across processes while concurrent Isabelle tasks are routed
back to the right caller by task id.

## Tutorial Livebooks

The notebooks in `livebook_examples/` are intended to be read and run in this
order:

1. `IsabelleClientMini.livemd` introduces the wire-level building blocks and
   explicit task handling.
2. `IsabelleClient.livemd` shows the default stateful client for ordinary use.
3. `IsabelleClientFull.livemd` shows the process-owning client and why it is
   the right choice when multiple Elixir processes share one Isabelle
   connection.

Together they serve as the tutorial for the library. They start local Isabelle
servers, run smoke tests, build and start a `HOL` session, check theories,
purge, stop, and clean up. The "Full" notebook additionally demonstrates
concurrency-safe access.

## Example

Make sure Isabelle is available on `PATH`:

```sh
export PATH=/path/to/Isabelle2025-2/bin:$PATH
```

Then:

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

`messages/1` returns the user-facing Isabelle messages as a list of strings.
Use `diagnostics/1` when you need the raw message maps, including source
positions. When Isabelle attaches a `"pos" => %{"line" => n}` field, all result
helpers can filter by line:

```elixir
IsabelleClient.messages(task, line: 5)
IsabelleClient.diagnostics(task, line: 5)
IsabelleClient.warnings(task, line: 5..10)
IsabelleClient.errors(task, line: [5, 10])
```

### Keyword Arguments

The client accepts Isabelle-style maps and ordinary Elixir keyword arguments:

```elixir
IsabelleClient.start_session(client, session: "HOL")
IsabelleClient.use_theories(client, theories: ["Example"], master_dir: "/tmp")
```

### Checking Files

For existing `.thy` files, `check_file/4` derives the theory name and
`master_dir` from the path:

```elixir
{:ok, task} = IsabelleClient.check_file(client, "/tmp/Example.thy", [], 120_000)
IsabelleClient.messages(task, line: 5)
```

### Shared Clients

Use `IsabelleClientFull` when multiple Elixir processes share one Isabelle
connection. It owns the socket and routes async `NOTE` / `FINISHED` / `FAILED`
messages by Isabelle task id:

```elixir
{:ok, pid} = IsabelleClientFull.start_link(session: "HOL", timeout: 120_000)

parent = self()

task =
  Task.async(fn ->
    IsabelleClientFull.use_theories(
      pid,
      [theories: ["Example"], master_dir: "/tmp"],
      120_000,
      on_note: fn note -> send(parent, {:isabelle_note, note}) end
    )
  end)

{:ok, checked} = Task.await(task, 120_000)
IsabelleClient.messages(checked)
```
