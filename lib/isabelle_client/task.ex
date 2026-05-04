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

  def new(id), do: %__MODULE__{id: id, status: :running}
end
