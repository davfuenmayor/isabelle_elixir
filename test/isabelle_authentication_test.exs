defmodule IsabelleClient.AuthenticationTest do
  use ExUnit.Case, async: true

  test "a server close during authentication identifies the failed phase" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, "incorrect\n"} = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
      end)

    try do
      assert {:error, {:authentication_failed, :closed}} =
               IsabelleClient.connect("incorrect", host: "127.0.0.1", port: port)

      Task.await(server)
    after
      :gen_tcp.close(listener)
    end
  end
end
