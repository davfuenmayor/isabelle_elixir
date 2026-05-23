defmodule IsabelleClient.Result do
  @moduledoc """
  Helpers for extracting common values from Isabelle task results.
  """

  alias IsabelleClient.Task

  @doc "Extracts the `session_id` from a session-start task or result map."
  def extract_session(%Task{result: result}), do: extract_session(result)
  def extract_session(%{"session_id" => session_id}) when is_binary(session_id), do: session_id
  def extract_session(_), do: nil

  @doc "Returns user-facing messages from a `use_theories` task or result map."
  def messages(%Task{result: result}), do: messages(result)

  def messages(%{"nodes" => nodes}) when is_list(nodes) do
    nodes
    |> Enum.flat_map(fn node ->
      node
      |> Map.get("messages", [])
      |> Enum.map(&Map.get(&1, "message", ""))
    end)
    |> Enum.reject(&(&1 == ""))
  end

  def messages(_), do: []

  @doc "Extracts user-facing theory messages as a newline-separated string."
  def extract_results(result) do
    result
    |> messages()
    |> Enum.join("\n")
  end
end
