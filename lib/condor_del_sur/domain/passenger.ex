defmodule CondorDelSur.Domain.Passenger do
  @enforce_keys [:id, :name]
  defstruct id: nil, name: nil

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t()
        }
end
