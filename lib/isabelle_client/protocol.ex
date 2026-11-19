defmodule IsabelleClient.Protocol do
  @moduledoc false

  defmodule Response do
    @moduledoc false
    defstruct [:type, :body, :raw, :length]
  end

  @timeout 30_000

  def command_options(arg, opts, default_timeout) when is_list(opts) do
    format = Keyword.get(opts, :format, :yxml)
    {command_arg(arg, format), Keyword.get(opts, :timeout, default_timeout)}
  end

  def command_options(arg, timeout, _default_timeout), do: {command_arg(arg, :yxml), timeout}

  defp command_arg(nil, format) when format in [:json, :yxml], do: nil
  defp command_arg({:yxml, payload}, :yxml), do: command_arg(payload, :yxml)
  defp command_arg(<<"\x05\x06", _::binary>> = payload, :yxml), do: {:yxml, payload}

  defp command_arg(_, :yxml),
    do: raise(ArgumentError, "expected a pre-encoded YXML element or format: :json")

  defp command_arg({:yxml, _}, :json),
    do: raise(ArgumentError, "expected a JSON argument, got YXML")

  defp command_arg(arg, :json), do: {:json, arg}

  defp command_arg(_, format),
    do: raise(ArgumentError, "unsupported command format: #{inspect(format)}")

  def line_message(data) when is_binary(data) do
    size = byte_size(data)

    if size > 100 or String.contains?(data, ["\r", "\n"]) or digits?(data) do
      [Integer.to_string(size + 1), "\n", data, "\n"]
    else
      [data, "\n"]
    end
  end

  def command(name, arg \\ nil) when is_binary(name) do
    case arg do
      nil -> line_message(name)
      "" -> line_message(name)
      {:json, []} -> line_message(name <> " []")
      {:json, value} -> json_command(name, value)
      {:yxml, payload} -> line_message(name <> " " <> payload)
      arg -> json_command(name, arg)
    end
  end

  defp json_command(name, arg),
    do: line_message(name <> " " <> JSON.encode!(IsabelleClient.Arguments.normalize(arg)))

  def send(socket, iodata), do: IsabelleClient.Transport.send(socket, iodata)

  def recv(socket, timeout \\ @timeout) do
    deadline = deadline(timeout)

    with {:ok, line} <- recv_line(socket, deadline),
         {:ok, raw, length} <- read_body(socket, line, deadline) do
      parse(raw, length)
    end
  catch
    :response_too_large ->
      IsabelleClient.Transport.close(socket)
      {:error, :response_too_large}
  end

  def parse(raw, length \\ nil) when is_binary(raw) do
    {name, body} = split_name(raw)

    if name == "" do
      {:error, {:malformed_response, raw}}
    else
      with {:ok, type} <- response_type(name),
           {:ok, decoded} <- decode_body(body) do
        {:ok, %Response{type: type, body: decoded, raw: raw, length: length}}
      end
    end
  end

  def ok_body(%Response{type: :ok, body: body}), do: {:ok, body}
  def ok_body(%Response{type: :error, body: body}), do: {:error, body}
  def ok_body(%Response{} = response), do: {:error, {:unexpected_response, response}}

  def task_id(%Response{type: :ok, body: %{"task" => task}}), do: {:ok, task}
  def task_id(%Response{} = response), do: {:error, {:missing_task, response}}

  defp read_body(socket, line, deadline) do
    if digits?(line) do
      length = String.to_integer(line)

      if IsabelleClient.Transport.websocket?(socket) and length > 16 * 1024 * 1024,
        do: throw(:response_too_large)

      with {:ok, data} <- recv_exact(socket, length, deadline) do
        {:ok, String.trim_trailing(data, "\n"), length}
      end
    else
      {:ok, line, nil}
    end
  end

  defp recv_line(socket, deadline, acc \\ []) do
    case IsabelleClient.Transport.recv(socket, 1, remaining(deadline)) do
      {:ok, "\n"} -> {:ok, acc |> IO.iodata_to_binary() |> String.trim_trailing("\r")}
      {:ok, byte} -> recv_line(socket, deadline, [acc, byte])
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_exact(socket, length, deadline, acc \\ [])
  defp recv_exact(_socket, 0, _deadline, acc), do: {:ok, IO.iodata_to_binary(acc)}

  defp recv_exact(socket, length, deadline, acc) do
    case IsabelleClient.Transport.recv(socket, length, remaining(deadline)) do
      {:ok, data} -> recv_exact(socket, length - byte_size(data), deadline, [acc, data])
      {:error, reason} -> {:error, reason}
    end
  end

  def deadline(:infinity), do: :infinity
  def deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  def remaining(:infinity), do: :infinity

  def remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp split_name(raw) do
    size = name_size(raw, 0)
    <<name::binary-size(^size), body::binary>> = raw
    {name, String.trim_leading(body)}
  end

  defp name_size(<<char, rest::binary>>, size)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?.],
       do: name_size(rest, size + 1)

  defp name_size(_, size), do: size

  defp response_type("OK"), do: {:ok, :ok}
  defp response_type("ERROR"), do: {:ok, :error}
  defp response_type("FINISHED"), do: {:ok, :finished}
  defp response_type("FAILED"), do: {:ok, :failed}
  defp response_type("NOTE"), do: {:ok, :note}
  defp response_type(other), do: {:error, {:unknown_response, other}}

  defp decode_body(""), do: {:ok, nil}

  defp decode_body(<<"\x05\x06", _::binary>> = body), do: {:ok, {:yxml, body}}

  defp decode_body(body) do
    case JSON.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:ok, body}
    end
  end

  defp digits?(""), do: false
  defp digits?(data), do: digit_suffix?(data)

  defp digit_suffix?(<<char, rest::binary>>) when char in ?0..?9, do: digit_suffix?(rest)
  defp digit_suffix?(""), do: true
  defp digit_suffix?(_), do: false
end
