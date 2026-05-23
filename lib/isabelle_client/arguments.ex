defmodule IsabelleClient.Arguments do
  @moduledoc false

  def normalize(nil), do: %{}

  def normalize(args) when is_list(args) do
    if Keyword.keyword?(args) do
      args
      |> Map.new(fn {key, value} -> {normalize_key(key), normalize(value)} end)
    else
      Enum.map(args, &normalize/1)
    end
  end

  def normalize(%{} = args) do
    Map.new(args, fn {key, value} -> {normalize_key(key), normalize(value)} end)
  end

  def normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: key
end
