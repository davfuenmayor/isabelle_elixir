defmodule IsabelleClient.WebSocket do
  @moduledoc false
  use WebSockex
  @limit 16 * 1024 * 1024

  def connect(url, timeout) do
    WebSockex.start(url, __MODULE__, %{buffer: "", pending: nil, owner: self()},
      socket_connect_timeout: timeout,
      socket_recv_timeout: timeout,
      insecure: false,
      ssl_options: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    )
  end

  def send_bytes(pid, bytes) when byte_size(bytes) <= @limit,
    do: request(pid, {:send, bytes}, 30_000)

  def send_bytes(_, _), do: {:error, :message_too_large}
  def recv(pid, size, timeout), do: request(pid, {:recv, size}, timeout)
  def owner(pid, owner), do: request(pid, {:owner, owner}, 30_000)

  def close(pid) do
    if Process.alive?(pid), do: WebSockex.cast(pid, :close)
    :ok
  end

  defp request(pid, message, timeout) do
    ref = Process.monitor(pid)
    WebSockex.cast(pid, {message, self(), ref})

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, _} ->
        {:error, :closed}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        close(pid)
        {:error, :timeout}
    end
  end

  @impl true
  def handle_connect(_conn, state) do
    # Cap the library's frame reassembly and mailbox as well as our byte buffer.
    Process.flag(:max_heap_size, %{
      size: 8_000_000,
      kill: true,
      error_logger: false,
      include_shared_binaries: true
    })

    {:ok, %{state | owner: Process.monitor(state.owner)}}
  end

  @impl true
  def handle_cast({{:send, bytes}, caller, ref}, state) do
    send(caller, {ref, :ok})
    {:reply, {:binary, bytes}, state}
  end

  def handle_cast({{:owner, pid}, caller, ref}, state) do
    Process.demonitor(state.owner, [:flush])
    send(caller, {ref, :ok})
    {:ok, %{state | owner: Process.monitor(pid)}}
  end

  def handle_cast({{:recv, size}, caller, ref}, %{pending: nil} = state),
    do: deliver(%{state | pending: {caller, ref, size}})

  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_frame({:binary, bytes}, state) do
    if byte_size(state.buffer) + byte_size(bytes) > @limit,
      do: {:close, {1009, "receive buffer limit"}, state},
      else: deliver(%{state | buffer: state.buffer <> bytes})
  end

  def handle_frame(_, state), do: {:close, {1003, "binary frames required"}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state), do: {:close, state}
  def handle_info(_, state), do: {:ok, state}

  defp deliver(%{pending: {caller, ref, size}, buffer: buffer} = state)
       when byte_size(buffer) >= size do
    <<bytes::binary-size(^size), rest::binary>> = buffer
    send(caller, {ref, {:ok, bytes}})
    {:ok, %{state | buffer: rest, pending: nil}}
  end

  defp deliver(state), do: {:ok, state}
end
