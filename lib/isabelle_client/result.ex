defmodule IsabelleClient.Result do
  @moduledoc """
  Helpers for extracting common values from Isabelle task results.
  """

  alias IsabelleClient.Session
  alias IsabelleClient.Task

  defmodule Position do
    @moduledoc "Source position attached to an Isabelle message."

    defstruct [:line, :offset, :end_offset, :file, :id]

    def from_map(nil), do: nil

    def from_map(%{} = map) do
      %__MODULE__{
        line: Map.get(map, "line"),
        offset: Map.get(map, "offset"),
        end_offset: Map.get(map, "end_offset"),
        file: Map.get(map, "file"),
        id: Map.get(map, "id")
      }
    end
  end

  defmodule Message do
    @moduledoc "Isabelle prover message."

    defstruct [:kind, :message, :pos, raw: %{}]

    def from_map(%{} = map) do
      %__MODULE__{
        kind: Map.get(map, "kind"),
        message: Map.get(map, "message"),
        pos: IsabelleClient.Result.Position.from_map(Map.get(map, "pos")),
        raw: map
      }
    end
  end

  defmodule Export do
    @moduledoc "Export produced by `use_theories`."

    defstruct [:name, :base64, :body, raw: %{}]

    def from_map(%{} = map) do
      %__MODULE__{
        name: Map.get(map, "name"),
        base64: Map.get(map, "base64"),
        body: Map.get(map, "body"),
        raw: map
      }
    end
  end

  defmodule Node do
    @moduledoc "One theory node in a `use_theories` result."

    defstruct [:node_name, :theory_name, :status, messages: [], exports: [], raw: %{}]

    def from_map(%{} = map) do
      %__MODULE__{
        node_name: Map.get(map, "node_name"),
        theory_name: Map.get(map, "theory_name"),
        status: Map.get(map, "status"),
        messages:
          Enum.map(Map.get(map, "messages", []), &IsabelleClient.Result.Message.from_map/1),
        exports: Enum.map(Map.get(map, "exports", []), &IsabelleClient.Result.Export.from_map/1),
        raw: map
      }
    end
  end

  defmodule UseTheoriesResult do
    @moduledoc "Structured `use_theories` result."

    defstruct [:ok, errors: [], nodes: [], raw: %{}]

    def from_map(%{"nodes" => nodes} = map) when is_list(nodes) do
      %__MODULE__{
        ok: Map.get(map, "ok"),
        errors: Enum.map(Map.get(map, "errors", []), &IsabelleClient.Result.Message.from_map/1),
        nodes: Enum.map(nodes, &IsabelleClient.Result.Node.from_map/1),
        raw: map
      }
    end
  end

  @doc "Extracts the `session_id` from a session-start task or result map."
  def extract_session(%Task{result: result}), do: extract_session(result)
  def extract_session(%Session{id: session_id}), do: session_id
  def extract_session(%{"session_id" => session_id}) when is_binary(session_id), do: session_id
  def extract_session(_), do: nil

  @doc "Returns a typed representation of common Isabelle server results."
  def decode(%Task{result: result}), do: decode(result)
  def decode(%{"session_id" => _} = result), do: Session.from_result(result)

  def decode(%{"nodes" => nodes} = result) when is_list(nodes),
    do: UseTheoriesResult.from_map(result)

  def decode(result), do: result

  @doc "Returns a structured `use_theories` result, or `nil` for another result shape."
  def use_theories_result(%UseTheoriesResult{} = result), do: result
  def use_theories_result(%Task{result: result}), do: use_theories_result(result)

  def use_theories_result(%{"nodes" => nodes} = result) when is_list(nodes),
    do: UseTheoriesResult.from_map(result)

  def use_theories_result(_), do: nil

  @doc "Returns typed theory nodes from a `use_theories` result."
  def nodes(result) do
    case use_theories_result(result) do
      %UseTheoriesResult{nodes: nodes} -> nodes
      nil -> []
    end
  end

  @doc "Finds a typed theory node by `node_name` or `theory_name`."
  def node(result, name) when is_binary(name) do
    Enum.find(nodes(result), &(&1.node_name == name or &1.theory_name == name))
  end

  @doc "Returns typed exports from all theory nodes in a `use_theories` result."
  def exports(result) do
    result
    |> nodes()
    |> Enum.flat_map(& &1.exports)
  end

  @doc "Returns typed top-level error messages from a `use_theories` result."
  def top_level_errors(result, opts \\ [])

  def top_level_errors(result, opts) do
    case use_theories_result(result) do
      %UseTheoriesResult{errors: errors} -> filter_diagnostics(errors, opts)
      nil -> []
    end
  end

  @doc """
  Returns diagnostic messages from a `use_theories` task or result.

  Pass `line: n`, `line: first..last`, or `line: [n, ...]` to keep only
  diagnostics whose position has that source line. Pass `offset: n` to keep
  only diagnostics whose `pos.offset..pos.end_offset` range contains `n`.

  Raw result maps return raw diagnostic maps; structured results return typed
  `%IsabelleClient.Result.Message{}` values.
  """
  def diagnostics(result, opts \\ [])

  def diagnostics(%Task{result: result}, opts), do: diagnostics(result, opts)
  def diagnostics(%UseTheoriesResult{nodes: nodes}, opts), do: diagnostics_from_nodes(nodes, opts)

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

  @doc """
  Returns error messages from a `use_theories` task or result map.

  This includes Isabelle's cumulative top-level `"errors"` list and node-level
  diagnostics whose kind is `"error"`.
  """
  def errors(result, opts \\ [])

  def errors(%Task{result: result}, opts), do: errors(result, opts)

  def errors(%UseTheoriesResult{} = result, opts) do
    result.errors
    |> Kernel.++(diagnostics(result) |> Enum.filter(&(message_kind(&1) == "error")))
    |> filter_diagnostics(opts)
    |> message_texts()
  end

  def errors(%{} = result, opts) do
    (Map.get(result, "errors", []) || [])
    |> Kernel.++(diagnostics(result) |> Enum.filter(&(message_kind(&1) == "error")))
    |> filter_diagnostics(opts)
    |> message_texts()
  end

  def errors(_result, _opts), do: []

  @doc "Returns warning messages from a `use_theories` task or result map."
  def warnings(result, opts \\ []), do: messages_by_kind(result, "warning", opts)

  defp messages_by_kind(result, kind, opts) do
    result
    |> diagnostics(opts)
    |> Enum.filter(&(message_kind(&1) == kind))
    |> message_texts()
  end

  defp diagnostics_from_nodes(nodes, opts) do
    nodes
    |> Enum.flat_map(& &1.messages)
    |> filter_diagnostics(opts)
  end

  defp filter_diagnostics(diagnostics, opts),
    do: Enum.filter(diagnostics, &diagnostic_matches?(&1, opts))

  defp diagnostic_matches?(diagnostic, opts) do
    line_matches?(line_number(diagnostic), Keyword.get(opts, :line)) and
      offset_matches?(message_pos(diagnostic), Keyword.get(opts, :offset))
  end

  defp line_number(%Message{pos: %Position{line: line}}), do: line
  defp line_number(%{"pos" => %{"line" => line}}), do: line
  defp line_number(_), do: nil

  defp line_matches?(_line, nil), do: true
  defp line_matches?(nil, _wanted), do: false
  defp line_matches?(line, wanted) when is_integer(wanted), do: line == wanted
  defp line_matches?(line, %Range{} = wanted), do: line in wanted
  defp line_matches?(line, wanted) when is_list(wanted), do: line in wanted
  defp line_matches?(_line, _wanted), do: false

  defp offset_matches?(_pos, nil), do: true

  defp offset_matches?(%Position{offset: first, end_offset: last}, offset)
       when is_integer(first) and is_integer(last) and is_integer(offset),
       do: offset >= first and offset <= last

  defp offset_matches?(%{"offset" => first, "end_offset" => last}, offset)
       when is_integer(first) and is_integer(last) and is_integer(offset),
       do: offset >= first and offset <= last

  defp offset_matches?(_pos, _offset), do: false

  defp message_pos(%Message{pos: pos}), do: pos
  defp message_pos(%{} = diagnostic), do: Map.get(diagnostic, "pos")
  defp message_pos(_), do: nil

  defp message_kind(%Message{kind: kind}), do: kind
  defp message_kind(%{} = diagnostic), do: Map.get(diagnostic, "kind")
  defp message_kind(_), do: nil

  defp message_texts(diagnostics) do
    diagnostics
    |> Enum.map(&message_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp message_text(%Message{message: message}), do: message
  defp message_text(%{} = diagnostic), do: Map.get(diagnostic, "message")
  defp message_text(_), do: nil
end
