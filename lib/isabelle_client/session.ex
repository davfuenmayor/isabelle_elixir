defmodule IsabelleClient.Session do
  @moduledoc """
  Isabelle server session resource.

  Sessions live in the Isabelle server process and may be used from different
  client connections when their `id` is known.
  """

  defstruct [:id, :tmp_dir, :args, :label]

  @typedoc """
  Isabelle server session known to the Elixir client.

  `id` is Isabelle's session handle. `tmp_dir`, `args`, and `label` are local
  conveniences recorded from session startup.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          tmp_dir: String.t() | nil,
          args: map() | nil,
          label: String.t() | nil
        }

  @doc "Builds a session struct from a `session_start` result map, or returns `nil`."
  def from_result(result, args \\ nil, label \\ nil)

  def from_result(%{"session_id" => id} = result, args, label) when is_binary(id) do
    %__MODULE__{id: id, tmp_dir: Map.get(result, "tmp_dir"), args: args, label: label}
  end

  def from_result(_, _, _), do: nil

  @doc false
  def prepare_start_args(args) do
    args = IsabelleClient.Arguments.normalize(args)
    {Map.delete(args, "label"), Map.get(args, "label")}
  end

  @doc false
  def args(opts) do
    opts
    |> Keyword.get(:session_args, [])
    |> IsabelleClient.Arguments.normalize()
    |> Map.put_new("session", Keyword.get(opts, :session, "HOL"))
  end

  @doc "Returns the session id from a session struct or id string."
  def id(%__MODULE__{id: id}), do: id
  def id(id) when is_binary(id), do: id
  def id(nil), do: nil

  @doc false
  def put_id(args, active_id),
    do: args |> IsabelleClient.Arguments.normalize() |> do_put_id(active_id)

  defp do_put_id(%{"session_id" => session_id} = args, _active_id) when is_binary(session_id),
    do: {:ok, args}

  defp do_put_id(args, active_id) when is_binary(active_id),
    do: {:ok, Map.put(args, "session_id", active_id)}

  defp do_put_id(_args, _active_id), do: :error

  @doc false
  def has_id?(args) do
    match?({:ok, _}, put_id(args, nil))
  end

  @doc false
  def push(%{sessions: sessions} = client, %__MODULE__{} = session),
    do: %{client | sessions: [session | sessions]}

  @doc false
  def active(%{sessions: [session | _]}), do: session
  def active(%{sessions: []}), do: nil

  @doc false
  def active_id(client), do: client |> active() |> id()

  @doc false
  def remove(%{sessions: sessions} = client, session_id) when is_binary(session_id) do
    %{client | sessions: Enum.reject(sessions, &(&1.id == session_id))}
  end

  def remove(client, _session_id), do: client

  @doc false
  def default_master_dir(%__MODULE__{id: session_id, tmp_dir: tmp_dir}, %{
        "session_id" => session_id
      })
      when is_binary(session_id) and is_binary(tmp_dir),
      do: tmp_dir

  def default_master_dir(%__MODULE__{tmp_dir: tmp_dir}, args) when is_binary(tmp_dir) do
    if Map.has_key?(args, "session_id"), do: fresh_tmp_dir(), else: tmp_dir
  end

  def default_master_dir(_session, _args), do: fresh_tmp_dir()

  @doc false
  def fetch(%__MODULE__{id: id}, key) when key in [:id, :session_id, "id", "session_id"],
    do: {:ok, id}

  def fetch(%__MODULE__{tmp_dir: tmp_dir}, key) when key in [:tmp_dir, "tmp_dir"],
    do: {:ok, tmp_dir}

  def fetch(%__MODULE__{args: args}, key) when key in [:args, "args"], do: {:ok, args}
  def fetch(%__MODULE__{label: label}, key) when key in [:label, "label"], do: {:ok, label}

  def fetch(%__MODULE__{}, _key), do: :error

  defp fresh_tmp_dir do
    Path.join(System.tmp_dir!(), "isabelle_elixir_#{System.unique_integer([:positive])}")
  end
end
