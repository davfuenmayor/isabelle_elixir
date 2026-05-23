defmodule IsabelleClient.Result do
  @moduledoc """
  Helpers for extracting common values from Isabelle task results.
  """

  alias IsabelleClient.Task

  @doc "Extracts the `session_id` from a session-start task or result map."
  def extract_session(%Task{result: result}), do: extract_session(result)
  def extract_session(%{"session_id" => session_id}) when is_binary(session_id), do: session_id
  def extract_session(_), do: nil

  @doc """
  Returns raw diagnostic message maps from a `use_theories` task or result map.

  Pass `line: n`, `line: first..last`, or `line: [n, ...]` to keep only
  diagnostics whose position has that source line.
  """
  def diagnostics(result, opts \\ [])

  def diagnostics(%Task{result: result}, opts), do: diagnostics(result, opts)

  def diagnostics(%{"nodes" => nodes}, opts) when is_list(nodes) do
    Enum.flat_map(nodes, &Map.get(&1, "messages", []))
    |> filter_diagnostics(opts)
  end

  def diagnostics(_, _opts), do: []

  @doc "Returns user-facing messages from a `use_theories` task or result map."
  def messages(result, opts \\ []) do
    result
    |> diagnostics(opts)
    |> message_texts()
  end

  @doc "Returns error messages from a `use_theories` task or result map."
  def errors(result, opts \\ []), do: messages_by_kind(result, "error", opts)

  @doc "Returns warning messages from a `use_theories` task or result map."
  def warnings(result, opts \\ []), do: messages_by_kind(result, "warning", opts)

  defp messages_by_kind(result, kind, opts) do
    result
    |> diagnostics(opts)
    |> Enum.filter(&(Map.get(&1, "kind") == kind))
    |> message_texts()
  end

  defp filter_diagnostics(diagnostics, opts) do
    case Keyword.get(opts, :line) do
      nil -> diagnostics
      line -> Enum.filter(diagnostics, &(line_number(&1) |> line_matches?(line)))
    end
  end

  defp line_number(%{"pos" => %{"line" => line}}), do: line
  defp line_number(_), do: nil

  defp line_matches?(nil, _wanted), do: false
  defp line_matches?(line, wanted) when is_integer(wanted), do: line == wanted
  defp line_matches?(line, %Range{} = wanted), do: line in wanted
  defp line_matches?(line, wanted) when is_list(wanted), do: line in wanted
  defp line_matches?(_line, _wanted), do: false

  defp message_texts(diagnostics) do
    diagnostics
    |> Enum.map(&Map.get(&1, "message"))
    |> Enum.reject(&(&1 in [nil, ""]))
  end
end
