# Changelog

## 0.4.0

- Require Elixir `~> 1.20`. Compiled with Elixir 1.20.1 on Erlang/OTP 29.
- Fixed bug in the "shared" client where replies became desynchronized after a timeout (see livebook "ClientShared").
- Added Module `IsabelleClient.TPTP` with convenient TPTP-related functionality.
