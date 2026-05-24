defmodule IsabelleClient.Theory do
  @moduledoc false

  alias IsabelleClient.Arguments

  def file_args(path, args) do
    args
    |> Arguments.normalize()
    |> Map.put_new("master_dir", Path.dirname(path))
    |> Map.put_new("theories", [path |> Path.basename() |> Path.rootname()])
  end

  def write_args(theory, text, args, master_dir) do
    args = Arguments.normalize(args)
    master_dir = Map.get(args, "master_dir") || master_dir
    File.mkdir_p!(master_dir)

    File.write!(
      Path.join(master_dir, file(theory)),
      source(theory, text, Map.get(args, "imports", "Main"))
    )

    args
    |> Map.delete("imports")
    |> Map.put_new("master_dir", master_dir)
    |> Map.put_new("theories", [theory])
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
