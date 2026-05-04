defmodule IsabelleClient.Server do
  @moduledoc """
  Local Isabelle server lifecycle helpers.
  """

  @default_name "elixir"
  @default_port 9999
  @isabelle_exec "isabelle"
  @timeout 7_000

  def start(name \\ @default_name, port \\ @default_port) do
    with {:ok, exe} <- executable() do
      port =
        Port.open({:spawn_executable, exe}, [
          :binary,
          args: ["server", "-n", name, "-p", to_string(port)]
        ])

      result =
        receive do
          {^port, {:data, data}} -> {:ok, parse_info(data)}
        after
          @timeout -> {:error, :timeout}
        end

      Port.close(port)
      result
    end
  end

  def list do
    with {:ok, exe} <- executable(),
         {data, 0} <- System.cmd(exe, ["server", "-l"], stderr_to_stdout: true) do
      {:ok, parse_info(data)}
    else
      {:error, _} = error -> error
      {data, status} -> {:error, %{status: status, output: data}}
    end
  end

  def kill(name) do
    with {:ok, exe} <- executable() do
      System.cmd(exe, ["server", "-n", name, "-x"], stderr_to_stdout: true)
    end
  end

  def parse_info(data) when is_binary(data) do
    regex =
      ~r/server\s+["'](?<name>[^"']+)["']\s*=\s*(?<host>\d{1,3}(?:\.\d{1,3}){3}):(?<port>\d+)\s+\(password\s+["'](?<password>[^"']+)["']\)/

    data
    |> String.split("\n", trim: true)
    |> Enum.map(&Regex.named_captures(regex, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn info -> %{info | "port" => String.to_integer(info["port"])} end)
  end

  defp executable do
    case System.find_executable(@isabelle_exec) do
      nil -> {:error, :isabelle_not_found}
      exe -> {:ok, exe}
    end
  end
end
