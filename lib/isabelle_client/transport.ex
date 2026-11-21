defmodule IsabelleClient.Transport do
  @moduledoc false
  alias IsabelleClient.WebSocket

  def connect(url, timeout) do
    uri = URI.parse(url)
    loopback = uri.host in ["localhost", "127.0.0.1", "::1"]

    cond do
      uri.scheme in ["https", "wss"] and is_binary(uri.host) ->
        WebSocket.connect(URI.to_string(%{uri | scheme: "wss"}), timeout)

      uri.scheme == "ws" and loopback ->
        WebSocket.connect(url, timeout)

      loopback ->
        connect(uri.host, uri.port || 9999, timeout)

      true ->
        {:error, :expected_loopback_or_https_url}
    end
  end

  def connect(host, port, timeout) do
    family = if String.contains?(to_string(host), ":"), do: [:inet6], else: []

    :gen_tcp.connect(
      to_charlist(host),
      port,
      family ++ [:binary, active: false, nodelay: true],
      timeout
    )
  end

  def send(socket, data) when is_pid(socket),
    do: WebSocket.send_bytes(socket, IO.iodata_to_binary(data))

  def send(socket, data), do: :gen_tcp.send(socket, data)
  def recv(socket, size, timeout) when is_pid(socket), do: WebSocket.recv(socket, size, timeout)
  def recv(socket, size, timeout), do: :gen_tcp.recv(socket, size, timeout)
  def close(socket) when is_pid(socket), do: WebSocket.close(socket)
  def close(socket), do: :gen_tcp.close(socket)

  def controlling_process(socket, pid) when is_pid(socket), do: WebSocket.owner(socket, pid)
  def controlling_process(socket, pid), do: :gen_tcp.controlling_process(socket, pid)

  def websocket?(socket), do: is_pid(socket)
end
