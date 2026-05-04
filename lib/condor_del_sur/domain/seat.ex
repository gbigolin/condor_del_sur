defmodule CondorDelSur.Domain.Seat do
  @doc """
  Estados posibles del asiento en un vuelo:
    * `:available`  - asiento libre.
    * `:reserved`   - asiento tomado por una reserva pendiente.
    * `:confirmed`  - asiento confirmado por pago.
  """
  @enforce_keys [:code]
  defstruct code: nil, status: :available, reservation_id: nil

  @type status :: :available | :reserved | :confirmed
  @type t :: %__MODULE__{
          code: String.t(),
          status: status(),
          reservation_id: String.t() | nil
        }
end
