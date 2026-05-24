defmodule IsabelleClient.Session do
  @moduledoc """
  Isabelle server session resource.

  Sessions live in the Isabelle server process and may be used from different
  client connections when their `id` is known.
  """

  defstruct [:id, :tmp_dir]

  @type t :: %__MODULE__{
          id: String.t(),
          tmp_dir: String.t() | nil
        }

  @doc "Builds a session struct from a `session_start` result map."
  def from_result(%{"session_id" => id} = result) when is_binary(id) do
    %__MODULE__{id: id, tmp_dir: Map.get(result, "tmp_dir")}
  end

  def from_result(_), do: nil

  def args(opts) do
    opts
    |> Keyword.get(:session_args, [])
    |> IsabelleClient.Arguments.normalize()
    |> Map.put_new("session", Keyword.get(opts, :session, "HOL"))
  end

  def id(%__MODULE__{id: id}), do: id
  def id(id) when is_binary(id), do: id

  def put_id(args, active_id),
    do: args |> IsabelleClient.Arguments.normalize() |> do_put_id(active_id)

  defp do_put_id(%{"session_id" => session_id} = args, _active_id) when is_binary(session_id),
    do: {:ok, args}

  defp do_put_id(args, active_id) when is_binary(active_id),
    do: {:ok, Map.put(args, "session_id", active_id)}

  defp do_put_id(_args, _active_id), do: :error

  def has_id?(args) do
    match?({:ok, _}, put_id(args, nil))
  end

  def clear_active(client, nil), do: clear(client)

  def clear_active(%{session_id: session_id} = client, session_id), do: clear(client)

  def clear_active(client, _session_id), do: client

  def default_master_dir(%{session_id: session_id, tmp_dir: tmp_dir}, %{
        "session_id" => session_id
      })
      when is_binary(session_id) and is_binary(tmp_dir),
      do: tmp_dir

  def default_master_dir(%{tmp_dir: tmp_dir}, args) when is_binary(tmp_dir) do
    if Map.has_key?(args, "session_id"), do: fresh_tmp_dir(), else: tmp_dir
  end

  def default_master_dir(_client, _args), do: fresh_tmp_dir()

  def fetch(%__MODULE__{id: id}, key) when key in [:id, :session_id, "id", "session_id"],
    do: {:ok, id}

  def fetch(%__MODULE__{tmp_dir: tmp_dir}, key) when key in [:tmp_dir, "tmp_dir"],
    do: {:ok, tmp_dir}

  def fetch(%__MODULE__{}, _key), do: :error

  defp clear(client), do: %{client | session: nil, session_id: nil, tmp_dir: nil}

  defp fresh_tmp_dir do
    Path.join(System.tmp_dir!(), "isabelle_elixir_#{System.unique_integer([:positive])}")
  end
end
