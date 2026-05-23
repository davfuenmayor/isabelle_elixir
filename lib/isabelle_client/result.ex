defmodule IsabelleClient.Result do
  @moduledoc """
  Helpers for extracting common values from Isabelle task results.
  """

  alias IsabelleClient.Task

  @doc "Extracts the `session_id` from a session-start task or result map."
  def extract_session(%Task{result: result}), do: extract_session(result)
  def extract_session(%{"session_id" => session_id}) when is_binary(session_id), do: session_id
  def extract_session(_), do: nil

  @doc "Returns raw diagnostic message maps from a `use_theories` task or result map."
  def diagnostics(%Task{result: result}), do: diagnostics(result)

  def diagnostics(%{"nodes" => nodes}) when is_list(nodes) do
    Enum.flat_map(nodes, &Map.get(&1, "messages", []))
  end

  def diagnostics(_), do: []

  @doc "Returns user-facing messages from a `use_theories` task or result map."
  def messages(result) do
    result
    |> diagnostics()
    |> message_texts()
  end

  @doc "Returns error messages from a `use_theories` task or result map."
  def errors(result), do: messages_by_kind(result, "error")

  @doc "Returns warning messages from a `use_theories` task or result map."
  def warnings(result), do: messages_by_kind(result, "warning")

  @doc "Extracts user-facing theory messages as a newline-separated string."
  def extract_results(result) do
    result
    |> messages()
    |> Enum.join("\n")
  end

  defp messages_by_kind(result, kind) do
    result
    |> diagnostics()
    |> Enum.filter(&(Map.get(&1, "kind") == kind))
    |> message_texts()
  end

  defp message_texts(diagnostics) do
    diagnostics
    |> Enum.map(&Map.get(&1, "message"))
    |> Enum.reject(&(&1 in [nil, ""]))
  end
end
