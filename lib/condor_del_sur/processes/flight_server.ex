defmodule CondorDelSur.Processes.FlightServer do
  alias CondorDelSur.Domain.{Flight, Passenger}
  alias CondorDelSur.Workers.ReservationExpirer

  @default_expiration_ms 120_000

  def start(
        flight_code,
        seat_codes,
        name \\ :flight_server,
        expiration_ms \\ @default_expiration_ms
      ) do
    if Process.whereis(name),
      do: raise("Ya existe un proceso registrado con el nombre #{inspect(name)}")

    state = initial_state(flight_code, seat_codes, name, expiration_ms)
    pid = spawn(__MODULE__, :loop, [state])

    true = Process.register(pid, name)

    {:ok, pid}
  end

  def stop(server \\ :flight_server) do
    send(server, :stop)
    :ok
  end

  def register_passenger(%Passenger{} = passenger, server \\ :flight_server) do
    call(server, {:register_passenger, passenger})
  end

  def available_seats(server \\ :flight_server) do
    call(server, :available_seats)
  end

  def reserve_seat(passenger_id, seat_code, server \\ :flight_server) do
    call(server, {:reserve_seat, passenger_id, seat_code})
  end

  def confirm_reservation(reservation_id, server \\ :flight_server) do
    call(server, {:confirm_reservation, reservation_id})
  end

  def cancel_reservation(reservation_id, server \\ :flight_server) do
    call(server, {:cancel_reservation, reservation_id})
  end

  def get_state(server \\ :flight_server) do
    call(server, :get_state)
  end

  # simula una llamada sin GenServer.call: se manda un mensaje con
  # el pid del proceso que espera respuesta y una referencia única.

  defp call(server, request, timeout \\ 5_000) do
    ref = make_ref()
    send(server, {request, {self(), ref}})

    receive do
      {^ref, response} -> response
    after
      timeout -> {:error, :timeout}
    end
  end

  defp reply({client_pid, ref}, response) do
    send(client_pid, {ref, response})
  end

  defp initial_state(flight_code, seat_codes, name, expiration_ms) do
    %{
      server_name: name,
      flight: Flight.new(flight_code, seat_codes),
      expiration_ms: expiration_ms,
      expiration_workers: %{}
    }
  end

  def loop(state) do
    receive do
      {{:register_passenger, %Passenger{} = passenger}, from} ->
        {_saved, updated_flight} = Flight.register_passenger(state.flight, passenger)
        new_state = %{state | flight: updated_flight}
        reply(from, {:ok, passenger})
        loop(new_state)

      {:available_seats, from} ->
        available = Flight.available_seats(state.flight)
        reply(from, {:ok, available})
        loop(state)

      {{:reserve_seat, passenger_id, seat_code}, from} ->
        {response, updated_flight} = Flight.reserve_seat(state.flight, passenger_id, seat_code)
        new_state = %{state | flight: updated_flight}

        new_state =
          case response do
            {:ok, reservation} ->
              worker_pid =
                ReservationExpirer.start(state.server_name, reservation.id, state.expiration_ms)

              ref = Process.monitor(worker_pid)
              new_workers = Map.put(new_state.expiration_workers, ref, worker_pid)
              %{new_state | expiration_workers: new_workers}

            _ ->
              new_state
          end

        reply(from, response)
        loop(new_state)

      {{:confirm_reservation, reservation_id}, from} ->
        {response, updated_flight} = Flight.confirm_reservation(state.flight, reservation_id)
        new_state = %{state | flight: updated_flight}
        reply(from, response)
        loop(new_state)

      {{:cancel_reservation, reservation_id}, from} ->
        {response, updated_flight} = Flight.cancel_reservation(state.flight, reservation_id)
        new_state = %{state | flight: updated_flight}
        reply(from, response)
        loop(new_state)

      {:expire_reservation, reservation_id} ->
        {_response, updated_flight} = Flight.expire_reservation(state.flight, reservation_id)
        new_state = %{state | flight: updated_flight}
        loop(new_state)

      {:get_state, from} ->
        reply(from, {:ok, public_state(state)})
        loop(state)

      {:DOWN, ref, :process, pid, reason} ->
        IO.puts("[flight monitor] Worker finalizó. pid=#{inspect(pid)} reason=#{inspect(reason)}")
        new_workers = Map.delete(state.expiration_workers, ref)
        loop(%{state | expiration_workers: new_workers})

      :stop ->
        :ok

      unknown ->
        IO.puts("[flight_server] Mensaje desconocido: #{inspect(unknown)}")
        loop(state)
    end
  end

  defp public_state(state) do
    %{
      server_name: state.server_name,
      flight_code: state.flight.code,
      seats: state.flight.seats,
      passengers: state.flight.passengers,
      reservations: state.flight.reservations,
      reservation_sequence: state.flight.reservation_sequence,
      expiration_ms: state.expiration_ms
    }
  end
end
