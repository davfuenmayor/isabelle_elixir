defmodule IsabelleClient.TransportTest do
  use ExUnit.Case, async: true

  test "loopback URL preserves native TCP and EOF releases an infinite Shared caller" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, "secret\n"} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, "OK\n")
        {:ok, "help\n"} = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
      end)

    {:ok, shared} =
      IsabelleClient.Shared.connect(url: "tcp://127.0.0.1:#{port}", password: "secret")

    assert {:error, {:connection_closed, :closed}} =
             IsabelleClient.Shared.command(shared, "help", nil, :infinity)

    IsabelleClient.Shared.close(shared)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "IPv6 loopback URLs also use native TCP" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:inet6, :binary, active: false, ip: {0, 0, 0, 0, 0, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    {:ok, socket} = IsabelleClient.Transport.connect("tcp://[::1]:#{port}", 5_000)
    {:ok, peer} = :gen_tcp.accept(listener)
    assert is_port(socket)
    IsabelleClient.Transport.close(socket)
    :gen_tcp.close(peer)
    :gen_tcp.close(listener)
  end

  test "unencrypted non-loopback URLs are rejected" do
    assert {:error, :expected_loopback_or_https_url} =
             IsabelleClient.connect("secret", url: "http://example.org/isabelle")
  end
end
