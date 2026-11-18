defmodule IsabelleClient.Files do
  @moduledoc false
  alias IsabelleClient.{Arguments, Session, Theory, Transport}

  def write(client, path, text, opts, command) do
    if Transport.remote?(client.socket) do
      with {:ok, args} <- session_args(client, opts),
           {:ok, %{"path" => remote}} <-
             command.("byom_write_file", Map.merge(args, %{"path" => path, "text" => text})) do
        {:ok, remote}
      else
        :error -> {:error, :no_session}
        other -> other
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

    if Transport.remote?(client.socket) do
      with {:ok, opts} <- session_args(client, opts),
           {:ok, path} <-
             write(
               client,
               Theory.file(theory),
               Theory.source(theory, text, Map.get(opts, "imports", "Main")),
               opts,
               command
             ) do
        {:ok, Theory.file_args(path, Map.drop(opts, ["imports", "master_dir"]))}
      else
        :error -> {:error, :no_session}
        error -> error
      end
    else
      dir =
        Map.get(opts, "master_dir") || Session.default_master_dir(Session.active(client), opts)

      {:ok, Theory.write_args(theory, text, opts, dir)}
    end
  end

  defp session_args(client, opts), do: Session.put_id(opts, Session.active_id(client))
end
