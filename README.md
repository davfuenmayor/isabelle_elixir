# Isabelle Elixir

Elixir clients for the [Isabelle](https://isabelle.in.tum.de/) server.

The library works with the server included in a standard Isabelle installation.
It speaks Isabelle's native protocol over TCP or through a WebSocket tunnel.
For protocol details, see chapter 4 of the
[Isabelle system manual](https://isabelle.in.tum.de/doc/system.pdf).

## Installation

```elixir
{:isabelle_elixir, "~> 0.4"}
```

Local server helpers need the Isabelle executable. Set `ISABELLE_TOOL` when
`isabelle` is not already on `PATH`:

```sh
export ISABELLE_TOOL=/path/to/Isabelle2026/bin/isabelle
```

## Client profiles

Start with `IsabelleClient` (see corresponding livebook tutorial). It owns one socket and keeps a local LIFO stack of
sessions, with the most recently started session treated as active.

Use `IsabelleClient.Shared` when several Elixir processes should share one
connection. It owns the socket in a `GenServer` and routes async task replies by
Isabelle task id. If a command or task times out, the shared connection is
currently closed conservatively (reusing the socket before the stale reply is handled could return the wrong result to a later caller).

Use `IsabelleClient.Raw` when you want protocol-level control: explicit socket
ownership, explicit session ids, and explicit task waiting.

## Usage example

```elixir
{:ok, server} = IsabelleClient.start_server()
{:ok, client} = IsabelleClient.connect(server)
{:ok, client, _task} = IsabelleClient.start_session(client, session: "HOL")

{:ok, task} =
  IsabelleClient.check_text(client, "Example", """
  theorem "x = x"
    by simp
  """)

IsabelleClient.messages(task)
```

`check_text/5` is a convenience for snippets. It writes a temporary theory of
this shape:

```isabelle
theory Example imports Main begin
<your text starts on line 2>
end
```

So Isabelle diagnostics report line 1 as the generated header; snippet line `n`
appears as Isabelle line `n + 1`. Offsets are absolute Isabelle symbol offsets
from the start of the generated file.

For TPTP/THF examples, `IsabelleClient.TPTP.check/5` wraps `check_text/5` with
Unicode output, routine message filtering, and optional `from:`, `to:`, and
`show_thf_app:` notation setup.

## More Examples

The main tutorials are in the Livebooks:

1. `livebook_examples/Client.livemd`: default client, diagnostics,
   line/offset filtering, sessions, checking files/text, building sessions.
2. `livebook_examples/ClientShared.livemd`: shared process-owned
   client for concurrent callers.
3. `livebook_examples/ClientRaw.livemd`: raw socket usage, server
   management, protocol commands, explicit async tasks.
4. `livebook_examples/Unification.livemd`: Isabelle unification and matching
   examples from Elixir.
5. `livebook_examples/TPTP.livemd`: TPTP/THF-style syntax and pretty-printing.

## Existing Servers

You do not have to start a local server from Elixir. If an Isabelle server is
already reachable, connect with its password, host, and port:

```elixir
{:ok, client} =
  IsabelleClient.connect("server-password",
    host: "127.0.0.1",
    port: 9999
  )
```

The same applies to `IsabelleClient.Shared` and `IsabelleClient.Raw`.

If the server is behind a WebSocket tunnel, pass its HTTPS or WSS address and
the Isabelle server password:

```elixir
{:ok, client} = IsabelleClient.connect(password, url: "https://isabelle.example.org/isabelle")
# Or: IsabelleClient.Shared.connect(password: password, url: url)
```

Non-loopback HTTPS and WSS URLs use certificate-verified WebSockets. Loopback
URLs and explicit host/port connections use native TCP.

On TCP, `write_file`, `check_text`, and TPTP loading write to the client's
filesystem, where Isabelle must be able to read the files. Over WebSocket, they
place files through the optional file commands provided by
[Isabelle BYOM](https://github.com/davfuenmayor/isabelle-byom), with an 8 MiB
limit per UTF-8 write. The `create_project`, `write_project_file`, and
`remove_project` helpers use the same extension for sources that need to exist
before a session starts.

A connection closed before authentication completes returns
`{:error, {:authentication_failed, :closed}}`. Check the server status and
current native password. Isabelle closes the socket for invalid passwords and
generates a new password when the server restarts.

### Select a command argument format

`IsabelleClient.command/4`, `IsabelleClient.Shared.command/4`, and
`IsabelleClient.Raw.command/4` accept `format: :json` or `format: :yxml` in
their options. YXML is the default and takes a pre-encoded element. Pass
`format: :json` to send Elixir values as JSON. Each Isabelle command determines
which formats it accepts. For example, `echo` accepts both, while
`session_start` expects JSON. Helpers such as `start_session` and
`use_theories` select the format Isabelle requires.

```elixir
{:ok, %{"message" => "hello"}} =
  IsabelleClient.command(client, "echo", %{message: "hello"}, format: :json)

yxml = "\x05\x06example\x05hello\x05\x06\x05"
{:ok, {:yxml, ^yxml}} =
  IsabelleClient.command(client, "echo", yxml, timeout: 5_000)
```

The option selects the argument format. Omit the argument or pass `nil` for
commands such as `help` that take none. Replies are decoded according to what
Isabelle sends. `echo/3` and `IsabelleClient.Raw.async_command/4` accept the same
options. See sections 1.6 and 4.2 of the Isabelle System Manual for YXML and
message framing.

## Sessions

Isabelle sessions live in the server and are addressed by session id.
`IsabelleClient` keeps local session bookkeeping for ergonomics:

```elixir
{:ok, client, _task} = IsabelleClient.start_session(client, session: "HOL", label: "main")

IsabelleClient.sessions(client)
IsabelleClient.active_session(client)
```

Starting a session pushes it onto `client.sessions`. Stopping a session removes
it; if it was active, the previous session becomes active again. Pass
`session_id:` when you want to address a non-active session explicitly.

Sessions may outlive a client connection, and a client may use a session started
elsewhere if given its id. `client.sessions` is local state, not a server-side
session query.

## Results

`messages/1` returns user-facing Isabelle messages. `diagnostics/1` returns the
raw diagnostic maps, including positions when Isabelle provides them.

```elixir
IsabelleClient.messages(task)
IsabelleClient.errors(task)
IsabelleClient.warnings(task, line: 5)
IsabelleClient.diagnostics(task, file: "Example.thy", line: 5, offset: 42)
```

Position filters support `file:`, `line:`, and `offset:`. Offsets are Isabelle
symbol offsets, not columns.

Common results can also be decoded:

```elixir
IsabelleClient.session_build_result(task)
IsabelleClient.use_theories_result(task)
IsabelleClient.nodes(task)
IsabelleClient.exports(task)
```
