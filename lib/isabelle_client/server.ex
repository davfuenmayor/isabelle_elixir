defmodule IsabelleClient.Server do
  @moduledoc """
  Local Isabelle server lifecycle helpers.
  """

  @default_name "elixir"
  @default_port 9999
  @isabelle_tool_env "ISABELLE_TOOL"
  @timeout 7_000

  defmodule Info do
    @moduledoc """
    Connection details for a resident Isabelle server.
    """

    defstruct [:name, :host, :port, :password]

    @type t :: %__MODULE__{
            name: String.t(),
            host: String.t(),
            port: non_neg_integer(),
            password: String.t()
          }

    @doc false
    def fetch(%__MODULE__{name: name}, key) when key in [:name, "name"], do: {:ok, name}
    def fetch(%__MODULE__{host: host}, key) when key in [:host, "host"], do: {:ok, host}
    def fetch(%__MODULE__{port: port}, key) when key in [:port, "port"], do: {:ok, port}

    def fetch(%__MODULE__{password: password}, key) when key in [:password, "password"],
      do: {:ok, password}

    def fetch(%__MODULE__{}, _key), do: :error
  end

  @doc "Starts a local resident Isabelle server."
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

  @doc "Lists local resident Isabelle servers."
  def list do
    with {:ok, exe} <- executable(),
         {data, 0} <- System.cmd(exe, ["server", "-l"], stderr_to_stdout: true) do
      {:ok, parse_info(data)}
    else
      {:error, _} = error -> error
      {data, status} -> {:error, %{status: status, output: data}}
    end
  end

  @doc "Force-kills a local resident Isabelle server by name."
  def kill(name) do
    with {:ok, exe} <- executable() do
      System.cmd(exe, ["server", "-n", name, "-x"], stderr_to_stdout: true)
    end
  end

  @doc "Parses `isabelle server` output into server info structs."
  def parse_info(data) when is_binary(data) do
    regex =
      ~r/server\s+["'](?<name>[^"']+)["']\s*=\s*(?<host>\d{1,3}(?:\.\d{1,3}){3}):(?<port>\d+)\s+\(password\s+["'](?<password>[^"']+)["']\)/

    data
    |> String.split("\n", trim: true)
    |> Enum.map(&Regex.named_captures(regex, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn info ->
      %Info{
        name: info["name"],
        host: info["host"],
        port: String.to_integer(info["port"]),
        password: info["password"]
      }
    end)
  end

  @doc """
  Returns the Isabelle tool executable path.

  The path is read from `ISABELLE_TOOL` when set. Otherwise `isabelle` is
  resolved from `PATH` and the resolved full path is stored in `ISABELLE_TOOL`.
  """
  def executable do
    case System.get_env(@isabelle_tool_env) do
      nil -> find_and_store_executable()
      "" -> find_and_store_executable()
      exe -> {:ok, exe}
    end
  end

  defp find_and_store_executable do
    case System.find_executable("isabelle") do
      nil ->
        {:error, :isabelle_not_found}

      exe ->
        System.put_env(@isabelle_tool_env, exe)
        {:ok, exe}
    end
  end
end
