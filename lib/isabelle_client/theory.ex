defmodule IsabelleClient.Theory do
  @moduledoc false

  alias IsabelleClient.Arguments

  def file_args(path, args) do
    args
    |> Arguments.normalize()
    |> Map.put_new("master_dir", Path.dirname(path))
    |> Map.put_new("theories", [path |> Path.basename() |> Path.rootname()])
  end

  def source(theory, text, imports \\ "Main") do
    if Regex.match?(~r/\A\s*theory\s+/u, text) do
      text
    else
      """
      theory #{theory} imports #{imports}
      begin

      #{text}

      end
      """
    end
  end

  def file(theory) do
    theory
    |> String.split(".")
    |> List.last()
    |> Kernel.<>(".thy")
  end
end
