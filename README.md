# Isabelle Elixir bindings and more

[![Hex version](https://img.shields.io/hexpm/v/isabelle_elixir.svg)](https://hex.pm/packages/isabelle_elixir)
[![HexDocs](https://img.shields.io/badge/hex-docs-brightgreen.svg)](https://hexdocs.pm/isabelle_elixir)

> **Elixir bindings and utilities for the [Isabelle](https://isabelle.in.tum.de) proof assistant**

`isabelle_elixir` lets you drive Isabelle’s *resident server* from Elixir code: start/stop the JVM server, launch logic sessions, compile & check theories, stream build progress, and retrieve generated artefacts – all with familiar Elixir APIs.

---

## ✨ Features

* **Zero-pain server control** – start, list, kill Isabelle servers programmatically.  
* **TCP client** – synchronous helpers for every core server command (`session_start`, `use_theories`, …).  
* **Streaming status** – follow `NOTE`/`FINISHED`/`FAILED` messages and extract results.  
* **Stateless by design** – works in scripts, Mix tasks, GenServers or LiveBooks.  
* **Pure Elixir** – no NIFs.  

---

## 📦 Installation

Add the dependency to your `mix.exs` and fetch it:

```elixir
defp deps do
  [
    {:isabelle_elixir, "~> 0.1"}
  ]
end
