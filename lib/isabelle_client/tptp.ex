defmodule IsabelleClient.TPTP do
  @moduledoc """
  Helpers for loading the bundled TPTP/THF notation theory.

  This is a lightweight syntax bridge, not a parser for full TPTP files.
  """

  alias IsabelleClient.Session

  @theory "TPTP"

  @doc """
  Loads the bundled `TPTP.thy` support theory into the active client session.

  The support theory is copied into the active session's temporary directory and
  checked there, so later calls such as `IsabelleClient.check_text/5` can import
  plain `"TPTP"` without starting a special Isabelle session.
  """
  def load(%IsabelleClient{} = client, timeout \\ :infinity) do
    with %Session{tmp_dir: tmp_dir} when is_binary(tmp_dir) <-
           IsabelleClient.active_session(client) do
      File.mkdir_p!(tmp_dir)
      File.cp!(source_path(), Path.join(tmp_dir, "#{@theory}.thy"))
      IsabelleClient.use_theories(client, [theories: [@theory], master_dir: tmp_dir], timeout)
    else
      _ -> {:error, :no_session}
    end
  end

  @doc false
  def source_path do
    Application.app_dir(:isabelle_elixir, "priv/isabelle/tptp/#{@theory}.thy")
  end

  @doc """
  Checks a small Isabelle theory body and returns only relevant Isabelle output.

  This wraps `IsabelleClient.check_text/5` with Unicode output enabled and a
  small amount of routine progress-message filtering. The `:from`, `:to`, and
  `:show_thf_app` options activate the bundled TPTP/THF notation around the
  supplied body and restore it afterwards. Use `:timeout` to override the
  default 60 second timeout.
  """
  def check(%IsabelleClient{} = client, import_name, theory_name, body, opts \\ []) do
    body = Enum.join([enable(opts), body, disable(opts)], "\n\n")
    timeout = Keyword.get(opts, :timeout, 60_000)

    {:ok, task} =
      IsabelleClient.check_text(
        client,
        theory_name,
        body,
        [imports: import_name, unicode_symbols: true],
        timeout
      )

    messages = task |> IsabelleClient.messages() |> Enum.filter(&output?/1)
    errors = IsabelleClient.errors(task)

    if errors == [] do
      Enum.join(messages, "\n\n")
    else
      %{ok?: task.result["ok"], messages: messages, errors: errors}
    end
  end

  @doc """
  Converts a small THF/TPTP theory into Isabelle/HOL theory commands.

  Supported annotated formulae are `thf(name,type,...)`,
  `thf(name,axiom,...)`, and `thf(name,theorem/conjecture,...)`. Simple
  `include('path/file.ext').` directives become `imports "path/file"`. Formulas
  are preserved as THF text and quoted for Isabelle; check the result in a
  theory that imports `"TPTP"` and has `unbundle from_TPTP` active. Metadata
  after the formula may be any comma-separated TPTP terms. Bracketed metadata
  lists are copied verbatim into the generated Isabelle attribute brackets;
  non-list metadata, such as `file(...)` or `inference(...)`, is ignored because
  it is not already in Isabelle attribute shape.
  """
  def isabellize_theory(text) when is_binary(text) do
    text
    |> items()
    |> Enum.map(&isabellize_item/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp items(text), do: items(text, [])

  defp enable(opts) do
    [
      opts[:from] && "unbundle from_TPTP",
      opts[:to] && "unbundle to_TPTP",
      Keyword.has_key?(opts, :show_thf_app) && "declare [[show_thf_app = #{opts[:show_thf_app]}]]"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp disable(opts) do
    [
      Keyword.has_key?(opts, :show_thf_app) && "declare [[show_thf_app = false]]",
      opts[:to] && "unbundle no to_TPTP",
      opts[:from] && "unbundle no from_TPTP"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  defp output?(message) do
    not (String.starts_with?(message, "theory ") or
           String.starts_with?(message, "Loading ") or
           String.starts_with?(message, "consts\n  thf_app") or
           String.starts_with?(message, "val protected =") or
           message in ["bundle from_TPTP", "bundle to_TPTP"])
  end

  defp items("", acc), do: Enum.reverse(acc)

  defp items("%" <> rest, acc) do
    {comment, rest} = take_line(rest)
    items(rest, [{:comment, comment} | acc])
  end

  defp items("/*" <> rest, acc) do
    case :binary.match(rest, "*/") do
      {stop, _} ->
        comment = binary_part(rest, 0, stop)
        rest = binary_part(rest, stop + 2, byte_size(rest) - stop - 2)
        items(rest, [{:comment, comment} | acc])

      :nomatch ->
        items("", [{:comment, rest} | acc])
    end
  end

  defp items("thf(" <> rest, acc) do
    case take_balanced(rest) do
      {formula, rest} -> items(rest, [{:annotated_formula, formula} | acc])
      :error -> Enum.reverse(acc)
    end
  end

  defp items("include(" <> rest, acc) do
    case take_balanced(rest) do
      {include, rest} -> items(rest, [{:include, include} | acc])
      :error -> Enum.reverse(acc)
    end
  end

  defp items(<<_char, rest::binary>>, acc), do: items(rest, acc)

  defp isabellize_item({:annotated_formula, formula}), do: isabellize_annotated_formula(formula)

  defp isabellize_item({:include, include}), do: isabellize_include(include)

  defp isabellize_item({:comment, comment}) do
    comment = comment |> String.trim() |> String.replace("*)", "* )")
    "(* #{comment} *)"
  end

  defp take_line(text) do
    case :binary.match(text, "\n") do
      {stop, _} ->
        {
          binary_part(text, 0, stop),
          binary_part(text, stop + 1, byte_size(text) - stop - 1)
        }

      :nomatch ->
        {text, ""}
    end
  end

  defp isabellize_include(include) do
    include
    |> split_top()
    |> List.first()
    |> case do
      nil -> nil
      path -> ~s(imports #{quoted(path |> unquote_tptp() |> Path.rootname())})
    end
  end

  defp isabellize_annotated_formula(formula) do
    case split_top(formula) do
      [name, role, formula | metadata] ->
        role = role |> String.trim() |> String.downcase()
        name = isabelle_name(name)
        attrs = metadata_attrs(metadata)
        formula = String.trim(formula)

        isabellize_annotated_formula(name, role, formula, attrs)

      _ ->
        nil
    end
  end

  defp isabellize_annotated_formula(_name, "type", formula, _attrs),
    do: isabellize_type(unwrap(formula))

  defp isabellize_annotated_formula(name, "axiom", formula, attrs),
    do: ~s(axiomatization where #{name}#{attrs}: #{quoted(formula)})

  defp isabellize_annotated_formula(name, role, formula, attrs)
       when role in ["theorem", "conjecture"],
       do: ~s(lemma #{name}#{attrs}: #{quoted(formula)})

  defp isabellize_annotated_formula(_name, _role, _formula, _attrs), do: nil

  defp isabellize_type(formula) do
    with [name, type] <- split_top(formula, ?:, parts: 2),
         name = isabelle_name(name),
         type = String.trim(type) do
      case split_top(type, ?=, parts: 2) do
        [_left, right] ->
          "type_synonym #{name} = #{quoted(unwrap(right))}"

        _ ->
          if type == "$tType" do
            "typedecl #{name}"
          else
            "consts #{name} :: #{quoted(type)}"
          end
      end
    else
      _ -> nil
    end
  end

  defp metadata_attrs(metadata) do
    metadata
    |> Enum.flat_map(&attribute_list/1)
    |> case do
      [] -> ""
      attrs -> "[#{Enum.join(attrs, ", ")}]"
    end
  end

  defp attribute_list(text) do
    text = String.trim(text)

    with "[" <> rest <- text,
         true <- String.ends_with?(rest, "]") do
      rest
      |> binary_part(0, byte_size(rest) - 1)
      |> split_top()
      |> Enum.reject(&(&1 == ""))
    else
      _ -> []
    end
  end

  defp quoted(text) do
    escaped =
      text
      |> String.trim()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp isabelle_name(name) do
    name =
      name
      |> String.trim()
      |> String.trim("'")
      |> String.replace(~r/[^A-Za-z0-9_'.]/, "_")

    if String.match?(name, ~r/^[A-Za-z_]/), do: name, else: "tptp_#{name}"
  end

  defp unquote_tptp(text) do
    text
    |> String.trim()
    |> String.trim("'")
    |> String.trim("\"")
  end

  defp unwrap(text) do
    text = String.trim(text)

    with "(" <> rest <- text,
         true <- String.ends_with?(rest, ")"),
         {inner, ""} <- take_balanced(rest) do
      String.trim(inner)
    else
      _ -> text
    end
  end

  defp split_top(text, separator \\ ?,, opts \\ [])

  defp split_top(text, separator, opts) do
    parts = Keyword.get(opts, :parts, :all)
    do_split_top(String.trim(text), separator, parts, "", [], 0, false)
  end

  defp do_split_top("", _separator, _parts, current, acc, _depth, _quote?) do
    [current | acc]
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
  end

  defp do_split_top(rest, _separator, 1, current, acc, _depth, _quote?) do
    [current <> rest | acc]
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
  end

  defp do_split_top(<<char, rest::binary>>, separator, parts, current, acc, depth, quote?) do
    next_quote? = if char == ?', do: not quote?, else: quote?

    cond do
      quote? or char == ?' ->
        do_split_top(rest, separator, parts, current <> <<char>>, acc, depth, next_quote?)

      char in [?(, ?[] ->
        do_split_top(rest, separator, parts, current <> <<char>>, acc, depth + 1, quote?)

      char in [?), ?]] ->
        do_split_top(rest, separator, parts, current <> <<char>>, acc, depth - 1, quote?)

      char == separator and depth == 0 ->
        do_split_top(rest, separator, dec(parts), "", [current | acc], depth, quote?)

      true ->
        do_split_top(rest, separator, parts, current <> <<char>>, acc, depth, quote?)
    end
  end

  defp dec(:all), do: :all
  defp dec(parts), do: parts - 1

  defp take_balanced(text), do: take_balanced(text, "", 1, false)

  defp take_balanced("", _acc, _depth, _quote?), do: :error

  defp take_balanced(<<char, rest::binary>>, acc, depth, quote?) do
    next_quote? = if char == ?', do: not quote?, else: quote?

    cond do
      quote? or char == ?' ->
        take_balanced(rest, acc <> <<char>>, depth, next_quote?)

      char in [?(, ?[] ->
        take_balanced(rest, acc <> <<char>>, depth + 1, quote?)

      char == ?) and depth == 1 ->
        {String.trim(acc), String.trim_leading(rest)}

      char in [?), ?]] ->
        take_balanced(rest, acc <> <<char>>, depth - 1, quote?)

      true ->
        take_balanced(rest, acc <> <<char>>, depth, quote?)
    end
  end
end
