defmodule IsabelleClient.Task do
  @moduledoc """
  Result of an Isabelle asynchronous server task.
  """

  defstruct [:id, :status, :result, notes: []]

  @type t :: %__MODULE__{
          id: String.t(),
          status: :running | :finished | :failed,
          result: map() | nil,
          notes: [map()]
        }

  @doc "Creates a running task struct from an Isabelle task id."
  def new(id), do: %__MODULE__{id: id, status: :running}
end
