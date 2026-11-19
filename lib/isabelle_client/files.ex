defmodule IsabelleClient.Files do
  @moduledoc false
  alias IsabelleClient.{Arguments, Session, Theory, Transport}
  alias IsabelleClient.Files.Remote

  def write(client, path, text, opts, command) do
    if Transport.websocket?(client.socket) do
      with {:ok, args} <- session_args(client, opts) do
        Remote.write_session(command, args["session_id"], path, text)
      end
    else
      opts = Arguments.normalize(opts)

      session =
        Enum.find(client.sessions, &(Map.get(opts, "session_id") == &1.id)) ||
          Session.active(client)

      dir = Session.default_master_dir(session, opts)
      target = if Path.type(path) == :absolute, do: path, else: Path.join(dir, path)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, text),
           do: {:ok, target}
    end
  end

  def prepare(client, theory, text, opts, command) do
    opts = Arguments.normalize(opts)

    if Transport.websocket?(client.socket) do
      with {:ok, opts} <- session_args(client, opts),
           {:ok, path} <-
             Remote.write_session(
               command,
               opts["session_id"],
               Theory.file(theory),
               Theory.source(theory, text, Map.get(opts, "imports", "Main"))
             ) do
        {:ok, Theory.file_args(path, Map.drop(opts, ["imports", "master_dir"]))}
      end
    else
      dir =
        Map.get(opts, "master_dir") || Session.default_master_dir(Session.active(client), opts)

      {:ok, Theory.write_args(theory, text, opts, dir)}
    end
  end

  defp session_args(client, opts) do
    case Session.put_id(opts, Session.active_id(client)) do
      :error -> {:error, :no_session}
      result -> result
    end
  end
end
