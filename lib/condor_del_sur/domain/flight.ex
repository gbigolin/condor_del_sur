defmodule CondorDelSur.Domain.Flight do
  alias CondorDelSur.Domain.{Passenger, Reservation, Seat}

  @enforce_keys [:code]
  defstruct code: nil, seats: %{}, passengers: %{}, reservations: %{}, reservation_sequence: 0

  @type t :: %__MODULE__{
          code: String.t(),
          seats: %{String.t() => Seat.t()},
          passengers: %{String.t() => Passenger.t()},
          reservations: %{String.t() => Reservation.t()},
          reservation_sequence: non_neg_integer()
        }

  @spec new(String.t(), [String.t()]) :: t()
  def new(code, seat_codes) do
    seats =
      seat_codes
      |> Enum.map(fn seat_code -> {seat_code, %Seat{code: seat_code}} end)
      |> Map.new()

    %__MODULE__{code: code, seats: seats}
  end

  @spec register_passenger(t(), Passenger.t()) :: {Passenger.t(), t()}
  def register_passenger(%__MODULE__{} = flight, %Passenger{} = passenger) do
    new_flight = %{flight | passengers: Map.put(flight.passengers, passenger.id, passenger)}
    {passenger, new_flight}
  end

  @spec get_seat(t(), String.t()) :: Seat.t() | nil
  def get_seat(%__MODULE__{} = flight, seat_code), do: Map.get(flight.seats, seat_code)

  @spec available_seats(t()) :: [String.t()]
  def available_seats(%__MODULE__{} = flight) do
    flight.seats
    |> Map.values()
    |> Enum.filter(&(&1.status == :available))
    |> Enum.map(& &1.code)
    |> Enum.sort()
  end

  @spec reserve_seat(t(), String.t(), String.t()) ::
          {{:ok, Reservation.t()} | {:error, atom()}, t()}
  def reserve_seat(%__MODULE__{} = flight, passenger_id, seat_code) do
    cond do
      not Map.has_key?(flight.passengers, passenger_id) ->
        {{:error, :passenger_not_found}, flight}

      not Map.has_key?(flight.seats, seat_code) ->
        {{:error, :seat_not_found}, flight}

      flight.seats[seat_code].status != :available ->
        {{:error, :seat_not_available}, flight}

      true ->
        reservation_id = "RES-#{flight.reservation_sequence + 1}"
        reservation = Reservation.new(reservation_id, passenger_id, seat_code)
        %Seat{} = current_seat = flight.seats[seat_code]
        seat = %{current_seat | status: :reserved, reservation_id: reservation_id}

        new_flight = %{
          flight
          | reservation_sequence: flight.reservation_sequence + 1,
            reservations: Map.put(flight.reservations, reservation_id, reservation),
            seats: Map.put(flight.seats, seat_code, seat)
        }

        {{:ok, reservation}, new_flight}
    end
  end

  @spec confirm_reservation(t(), String.t()) ::
          {{:ok, Reservation.t()}
           | {:error, :reservation_not_found | {:reservation_not_pending, atom()}}, t()}
  def confirm_reservation(%__MODULE__{} = flight, reservation_id) do
    case Map.get(flight.reservations, reservation_id) do
      nil ->
        {{:error, :reservation_not_found}, flight}

      %Reservation{status: :pending} = reservation ->
        confirmed_reservation = %Reservation{reservation | status: :confirmed}
        %Seat{} = current_seat = flight.seats[reservation.seat_code]
        seat = %{current_seat | status: :confirmed, reservation_id: reservation_id}

        new_flight = %{
          flight
          | reservations: Map.put(flight.reservations, reservation_id, confirmed_reservation),
            seats: Map.put(flight.seats, reservation.seat_code, seat)
        }

        {{:ok, confirmed_reservation}, new_flight}

      %Reservation{status: other_status} ->
        {{:error, {:reservation_not_pending, other_status}}, flight}
    end
  end

  @spec cancel_reservation(t(), String.t()) ::
          {{:ok, Reservation.t()} | {:error, atom() | {:reservation_not_pending, atom()}}, t()}
  def cancel_reservation(%__MODULE__{} = flight, reservation_id) do
    case Map.get(flight.reservations, reservation_id) do
      nil ->
        {{:error, :reservation_not_found}, flight}

      %Reservation{status: :pending} = reservation ->
        cancelled_reservation = %Reservation{reservation | status: :cancelled}
        %Seat{} = current_seat = flight.seats[reservation.seat_code]
        seat = %{current_seat | status: :available, reservation_id: nil}

        new_flight = %{
          flight
          | reservations: Map.put(flight.reservations, reservation_id, cancelled_reservation),
            seats: Map.put(flight.seats, reservation.seat_code, seat)
        }

        {{:ok, cancelled_reservation}, new_flight}

      %Reservation{status: :confirmed} ->
        {{:error, :confirmed_reservation_cannot_be_cancelled}, flight}

      %Reservation{status: other_status} ->
        {{:error, {:reservation_not_pending, other_status}}, flight}
    end
  end

  @spec expire_reservation(t(), String.t()) ::
          {{:ok, Reservation.t()} | {:ignored, String.t()}, t()}
  def expire_reservation(%__MODULE__{} = flight, reservation_id) do
    case Map.get(flight.reservations, reservation_id) do
      %Reservation{status: :pending} = reservation ->
        expired_reservation = %Reservation{reservation | status: :expired}
        %Seat{} = current_seat = flight.seats[reservation.seat_code]
        seat = %{current_seat | status: :available, reservation_id: nil}

        new_flight = %{
          flight
          | reservations: Map.put(flight.reservations, reservation_id, expired_reservation),
            seats: Map.put(flight.seats, reservation.seat_code, seat)
        }

        {{:ok, expired_reservation}, new_flight}

      _ ->
        {{:ignored, reservation_id}, flight}
    end
  end

  @spec get_reservation(t(), String.t()) :: Reservation.t() | nil
  def get_reservation(%__MODULE__{} = flight, reservation_id),
    do: Map.get(flight.reservations, reservation_id)

  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = flight) do
    seats = Map.values(flight.seats)

    %{
      flight_code: flight.code,
      total_seats: length(seats),
      available: Enum.count(seats, &(&1.status == :available)),
      reserved: Enum.count(seats, &(&1.status == :reserved)),
      confirmed: Enum.count(seats, &(&1.status == :confirmed)),
      passengers: map_size(flight.passengers),
      reservations: map_size(flight.reservations)
    }
  end
end
