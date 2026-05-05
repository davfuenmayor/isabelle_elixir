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
may safely share it across processes. Calls are serialized by design.

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
{:ok, [server]} = IsabelleClientMini.new_server("elixir", 0)

{:ok, client} =
  IsabelleClient.connect(server["password"],
    host: server["host"],
    port: server["port"]
  )

{:ok, client, _task} = IsabelleClient.start_session(client, %{"session" => "HOL"})

File.write!("/tmp/Example.thy", """
theory Example imports Main
begin

theorem "x = x"
  sledgehammer by simp

proposition "x = y"
  nitpick oops

end
""")

{:ok, task} =
  IsabelleClient.use_theories(client, %{
    "theories" => ["Example"],
    "master_dir" => "/tmp"
  })

IO.puts(IsabelleClientMini.extract_results(task))

{:ok, _client, _task} = IsabelleClient.stop_session(client)
```
