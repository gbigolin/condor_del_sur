defmodule CondorDelSur.Domain.Reservation do
  @doc """
  Estados posibles de la reserva:
    * `:pending` - creada, esperando confirmación de pago.
    * `:confirmed` - pagada y confirmada.
    * `:cancelled` - cancelada por el usuario antes de confirmarse.
    * `:expired` - venció por falta de confirmación.
  """

  @enforce_keys [:id, :passenger_id, :seat_code]
  defstruct id: nil, passenger_id: nil, seat_code: nil, status: :pending

  @type status :: :pending | :confirmed | :cancelled | :expired

  @type t :: %__MODULE__{
          id: String.t(),
          passenger_id: String.t(),
          seat_code: String.t(),
          status: status()
        }

  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(id, passenger_id, seat_code) do
    %__MODULE__{
      id: id,
      passenger_id: passenger_id,
      seat_code: seat_code
    }
  end
end
