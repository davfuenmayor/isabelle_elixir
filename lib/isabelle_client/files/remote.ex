defmodule IsabelleClient.Files.Remote do
  @moduledoc false
  # Wire format for the optional server-side file placement commands.
  @max_file_bytes 8 * 1024 * 1024
  @yxml_start "\x05\x06"
  @yxml_end "\x05\x06\x05"

  def create_project(command), do: request(command, "byom_create_project", nil)

  def remove_project(project, command) do
    with {:ok, owner} <- owner_attribute("project_id", project["project_id"]) do
      request(command, "byom_remove_project", element("project", owner, ""))
    end
  end

  def write_project(project, path, text, command) do
    remote_write(
      command,
      "byom_write_project_file",
      {"project_id", project["project_id"]},
      path,
      text
    )
  end

  def write_session(command, id, path, text) do
    with {:ok, %{"path" => remote}} <-
           remote_write(command, "byom_write_file", {"session_id", id}, path, text) do
      {:ok, remote}
    end
  end

  defp remote_write(_command, _name, _owner, _path, text)
       when byte_size(text) > @max_file_bytes,
       do: {:error, %{"kind" => "error", "message" => "File exceeds 8 MiB"}}

  defp remote_write(command, name, {owner_key, id}, path, text) do
    with {:ok, owner} <- owner_attribute(owner_key, id) do
      attrs = owner <> "\x06path=" <> Base.encode64(path)
      request(command, name, element("file", attrs, Base.encode64(text)))
    end
  end

  defp owner_attribute(key, id) do
    if is_binary(id) and id != "" and :binary.match(id, ["\x05", "\x06"]) == :nomatch do
      {:ok, key <> "=" <> id}
    else
      {:error, %{"kind" => "error", "message" => "Invalid #{key}"}}
    end
  end

  defp element(name, attrs, text),
    do: {:yxml, @yxml_start <> name <> "\x06" <> attrs <> "\x05" <> text <> @yxml_end}

  defp request(command, name, arg) do
    case command.(name, arg) do
      {:ok, {:yxml, payload}} -> decode_result(payload)
      {:ok, _} -> {:error, :invalid_byom_response}
      error -> error
    end
  end

  defp decode_result(<<@yxml_start, "byom\x06", rest::binary>>) do
    case :binary.split(rest, "\x05") do
      [attrs, "\x05\x06\x05"] ->
        attrs
        |> :binary.split("\x06", [:global])
        |> Enum.reduce_while({:ok, %{}}, fn attribute, {:ok, fields} ->
          with [key, encoded] <- :binary.split(attribute, "="),
               {:ok, value} <- Base.decode64(encoded) do
            {:cont, {:ok, Map.put(fields, key, value)}}
          else
            _ -> {:halt, {:error, :invalid_byom_response}}
          end
        end)

      _ ->
        {:error, :invalid_byom_response}
    end
  end

  defp decode_result(_), do: {:error, :invalid_byom_response}
end
