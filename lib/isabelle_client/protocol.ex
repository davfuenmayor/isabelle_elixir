defmodule IsabelleClient.Protocol do
  @moduledoc false

  defmodule Response do
    @moduledoc false
    defstruct [:type, :body, :raw, :length]
  end

  @timeout 30_000

  def line_message(data) when is_binary(data) do
    size = byte_size(data)

    if size > 100 or String.contains?(data, "\n") or digits?(data) do
      [Integer.to_string(size + 1), "\n", data, "\n"]
    else
      [data, "\n"]
    end
  end

  def command(name, arg \\ nil) when is_binary(name) do
    case arg do
      nil -> line_message(name)
      "" -> line_message(name)
      arg -> line_message(name <> " " <> JSON.encode!(arg))
    end
  end

  def send(socket, iodata), do: :gen_tcp.send(socket, iodata)

  def recv(socket, timeout \\ @timeout) do
    deadline = deadline(timeout)

    with {:ok, line} <- recv_line(socket, deadline),
         {:ok, raw, length} <- read_body(socket, line, deadline) do
      parse(raw, length)
    end
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

      with {:ok, data} <- recv_exact(socket, length, deadline) do
        {:ok, String.trim_trailing(data, "\n"), length}
      end
    else
      {:ok, line, nil}
    end
  end

  defp recv_line(socket, deadline, acc \\ []) do
    case :gen_tcp.recv(socket, 1, remaining(deadline)) do
      {:ok, "\n"} -> {:ok, acc |> IO.iodata_to_binary() |> String.trim_trailing("\r")}
      {:ok, byte} -> recv_line(socket, deadline, [acc, byte])
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_exact(socket, length, deadline, acc \\ [])
  defp recv_exact(_socket, 0, _deadline, acc), do: {:ok, IO.iodata_to_binary(acc)}

  defp recv_exact(socket, length, deadline, acc) do
    case :gen_tcp.recv(socket, length, remaining(deadline)) do
      {:ok, data} -> recv_exact(socket, length - byte_size(data), deadline, [acc, data])
      {:error, reason} -> {:error, reason}
    end
  end

  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp split_name(raw) do
    name = raw |> String.to_charlist() |> Enum.take_while(&name_char?/1) |> to_string()

    body =
      raw
      |> binary_part(byte_size(name), byte_size(raw) - byte_size(name))
      |> String.trim_leading()

    {name, body}
  end

  defp name_char?(char),
    do: char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?.]

  defp response_type("OK"), do: {:ok, :ok}
  defp response_type("ERROR"), do: {:ok, :error}
  defp response_type("FINISHED"), do: {:ok, :finished}
  defp response_type("FAILED"), do: {:ok, :failed}
  defp response_type("NOTE"), do: {:ok, :note}
  defp response_type(other), do: {:error, {:unknown_response, other}}

  defp decode_body(""), do: {:ok, nil}

  defp decode_body(body) do
    case JSON.decode(body) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:ok, body}
    end
  end

  defp digits?(""), do: false
  defp digits?(data), do: data |> String.to_charlist() |> Enum.all?(&(&1 in ?0..?9))
end
