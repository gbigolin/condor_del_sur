defmodule CondorDelSur.Processes.FlightServerTest do
  use ExUnit.Case, async: false

  alias CondorDelSur.Domain.Passenger
  alias CondorDelSur.Processes.FlightServer

  setup do
    server_name = String.to_atom("flight_server_test_#{System.unique_integer([:positive])}")
    seat_primary = seat_code(1, "A")
    seat_secondary = seat_code(1, "B")
    {:ok, pid} = FlightServer.start("CDS-TEST", [seat_primary, seat_secondary], server_name, 200)

    passenger = %Passenger{id: "P1", name: "Ana"}
    passenger2 = %Passenger{id: "P2", name: "Bruno"}

    {:ok, _} = FlightServer.register_passenger(passenger, server_name)
    {:ok, _} = FlightServer.register_passenger(passenger2, server_name)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    %{server: server_name, seat_primary: seat_primary, seat_secondary: seat_secondary}
  end

  test "reservar asiento disponible", %{server: server, seat_primary: seat_primary} do
    assert {:ok, reservation} = FlightServer.reserve_seat("P1", seat_primary, server)
    assert reservation.status == :pending
    assert reservation.seat_code == seat_primary

    {:ok, state} = FlightServer.get_state(server)
    assert state.seats[seat_primary].status == :reserved
  end

  test "inicializar vuelo con asientos en estado available", %{
    server: server,
    seat_primary: seat_primary,
    seat_secondary: seat_secondary
  } do
    {:ok, state} = FlightServer.get_state(server)
    expected_seats = [seat_primary, seat_secondary]

    assert Enum.sort(Map.keys(state.seats)) == Enum.sort(expected_seats)
    assert_all_seats_available_without_reservation(state.seats, expected_seats)
  end

  test "registrar pasajero nuevo lo guarda en el estado", %{server: server} do
    passenger = %Passenger{id: "P3", name: "Carla"}
    assert {:ok, %Passenger{id: "P3"}} = FlightServer.register_passenger(passenger, server)

    {:ok, state} = FlightServer.get_state(server)
    assert state.passengers["P3"] == passenger
  end

  test "registrar pasajero con id repetido sobrescribe datos", %{server: server} do
    assert {:ok, %Passenger{id: "P1", name: "Ana Actualizada"}} =
             FlightServer.register_passenger(
               %Passenger{id: "P1", name: "Ana Actualizada"},
               server
             )

    {:ok, state} = FlightServer.get_state(server)
    assert state.passengers["P1"].name == "Ana Actualizada"
  end

  test "rechazar iniciar vuelo con nombre de proceso ya registrado" do
    server_name = String.to_atom("flight_server_dup_#{System.unique_integer([:positive])}")
    {:ok, pid} = FlightServer.start("CDS-DUP", [seat_code(1, "A")], server_name, 200)

    assert_raise RuntimeError, ~r/Ya existe un proceso registrado/, fn ->
      FlightServer.start("CDS-DUP-2", ["2A"], server_name, 200)
    end

    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  test "rechazar registrar pasajero con tipo invalido", %{server: server} do
    assert_raise FunctionClauseError, fn ->
      apply(FlightServer, :register_passenger, [%{id: "PX", name: "No struct"}, server])
    end
  end

  test "reservar asiento ocupado", %{server: server, seat_primary: seat_primary} do
    assert {:ok, _reservation} = FlightServer.reserve_seat("P1", seat_primary, server)
    assert {:error, :seat_not_available} = FlightServer.reserve_seat("P2", seat_primary, server)
  end

  test "rechazar reserva con pasajero inexistente", %{server: server, seat_primary: seat_primary} do
    assert {:error, :passenger_not_found} =
             FlightServer.reserve_seat("P999", seat_primary, server)
  end

  test "rechazar reserva con asiento inexistente", %{server: server} do
    assert {:error, :seat_not_found} = FlightServer.reserve_seat("P1", "9Z", server)
  end

  test "confirmar reserva pendiente", %{server: server, seat_primary: seat_primary} do
    {:ok, reservation} = FlightServer.reserve_seat("P1", seat_primary, server)

    assert {:ok, confirmed} = FlightServer.confirm_reservation(reservation.id, server)
    assert confirmed.status == :confirmed

    {:ok, state} = FlightServer.get_state(server)
    assert state.seats[seat_primary].status == :confirmed
  end

  test "cancelar reserva pendiente", %{server: server, seat_primary: seat_primary} do
    {:ok, reservation} = FlightServer.reserve_seat("P1", seat_primary, server)

    assert {:ok, cancelled} = FlightServer.cancel_reservation(reservation.id, server)
    assert cancelled.status == :cancelled

    {:ok, state} = FlightServer.get_state(server)
    assert state.seats[seat_primary].status == :available
    assert state.seats[seat_primary].reservation_id == nil
  end

  test "confirmar reserva inexistente", %{server: server} do
    assert {:error, :reservation_not_found} = FlightServer.confirm_reservation("RES-404", server)
  end

  test "cancelar reserva inexistente", %{server: server} do
    assert {:error, :reservation_not_found} = FlightServer.cancel_reservation("RES-404", server)
  end

  test "impedir cancelar reserva confirmada", %{server: server, seat_primary: seat_primary} do
    {:ok, reservation} = FlightServer.reserve_seat("P1", seat_primary, server)
    {:ok, _confirmed} = FlightServer.confirm_reservation(reservation.id, server)

    assert {:error, :confirmed_reservation_cannot_be_cancelled} =
             FlightServer.cancel_reservation(reservation.id, server)

    {:ok, state} = FlightServer.get_state(server)
    assert state.seats[seat_primary].status == :confirmed
  end

  test "confirmar reserva ya cancelada devuelve error de estado", %{
    server: server,
    seat_primary: seat_primary
  } do
    {:ok, reservation} = FlightServer.reserve_seat("P1", seat_primary, server)
    {:ok, _cancelled} = FlightServer.cancel_reservation(reservation.id, server)

    assert {:error, {:reservation_not_pending, :cancelled}} =
             FlightServer.confirm_reservation(reservation.id, server)
  end

  test "devolver asientos disponibles ordenados", %{
    server: server,
    seat_primary: seat_primary,
    seat_secondary: seat_secondary
  } do
    assert {:ok, [^seat_primary, ^seat_secondary]} = FlightServer.available_seats(server)

    {:ok, _reservation} = FlightServer.reserve_seat("P1", seat_primary, server)
    assert {:ok, [^seat_secondary]} = FlightServer.available_seats(server)
  end

  test "liberar asiento por expiración", %{server: server, seat_primary: seat_primary} do
    {:ok, reservation} = FlightServer.reserve_seat("P1", seat_primary, server)

    # El expiration_ms del setup es 200 ms, se espera un poco más para que llegue el mensaje.
    Process.sleep(300)

    {:ok, state} = FlightServer.get_state(server)
    assert state.reservations[reservation.id].status == :expired
    assert state.seats[seat_primary].status == :available
    assert state.seats[seat_primary].reservation_id == nil
  end

  test "no expirar reserva ya confirmada", %{server: server, seat_primary: seat_primary} do
    {:ok, reservation} = FlightServer.reserve_seat("P1", seat_primary, server)
    {:ok, _confirmed} = FlightServer.confirm_reservation(reservation.id, server)

    Process.sleep(300)

    {:ok, state} = FlightServer.get_state(server)
    assert state.reservations[reservation.id].status == :confirmed
    assert state.seats[seat_primary].status == :confirmed
  end

  test "competencia concurrente por el mismo asiento: solo uno reserva", %{
    server: server,
    seat_primary: seat_primary
  } do
    parent = self()

    spawn(fn ->
      send(parent, {:attempt, FlightServer.reserve_seat("P1", seat_primary, server)})
    end)

    spawn(fn ->
      send(parent, {:attempt, FlightServer.reserve_seat("P2", seat_primary, server)})
    end)

    result_1 =
      receive do
        {:attempt, result} -> result
      after
        2_000 -> flunk("no llegó primer intento de reserva concurrente")
      end

    result_2 =
      receive do
        {:attempt, result} -> result
      after
        2_000 -> flunk("no llegó segundo intento de reserva concurrente")
      end

    results = [result_1, result_2]
    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &(&1 == {:error, :seat_not_available}))

    assert ok_count == 1
    assert error_count == 1

    {:ok, state} = FlightServer.get_state(server)
    assert state.seats[seat_primary].status == :reserved
  end

  test "stress concurrente mixto: 50 pasajeros, mayoría compite por 1 asiento y algunos ocupan otros" do
    server = String.to_atom("flight_server_stress_#{System.unique_integer([:positive])}")
    seat_codes = for row <- 1..2, col <- ["A", "B", "C", "D", "E"], do: "#{row}#{col}"
    target_seat = "1A"

    {:ok, pid} = FlightServer.start("CDS-STRESS", seat_codes, server, 5_000)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    passenger_ids =
      Enum.map(1..50, fn n ->
        id = "PX#{n}"

        {:ok, _} =
          FlightServer.register_passenger(%Passenger{id: id, name: "Pasajero #{n}"}, server)

        id
      end)

    target_by_passenger =
      passenger_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {passenger_id, idx} ->
        seat =
          case idx do
            n when n <= 42 -> "1A"
            43 -> "1B"
            44 -> "1C"
            45 -> "1D"
            46 -> "1E"
            47 -> "2A"
            48 -> "2B"
            49 -> "2C"
            _ -> "2D"
          end

        {passenger_id, seat}
      end)

    parent = self()

    Enum.each(target_by_passenger, fn {passenger_id, seat_code} ->
      spawn(fn ->
        result = FlightServer.reserve_seat(passenger_id, seat_code, server)
        send(parent, {:stress_attempt, passenger_id, seat_code, result})
      end)
    end)

    results =
      Enum.map(1..50, fn _ ->
        receive do
          {:stress_attempt, passenger_id, seat_code, result} -> {passenger_id, seat_code, result}
        after
          3_000 -> flunk("timeout recolectando resultados concurrentes del stress test")
        end
      end)

    seat_1a_results = Enum.filter(results, fn {_pid, seat, _result} -> seat == target_seat end)
    other_seat_results = Enum.filter(results, fn {_pid, seat, _result} -> seat != target_seat end)

    seat_1a_success =
      Enum.filter(seat_1a_results, fn {_passenger_id, _seat, result} ->
        match?({:ok, _}, result)
      end)

    seat_1a_errors =
      Enum.filter(seat_1a_results, fn {_passenger_id, _seat, result} ->
        result == {:error, :seat_not_available}
      end)

    other_seat_success =
      Enum.filter(other_seat_results, fn {_passenger_id, _seat, result} ->
        match?({:ok, _}, result)
      end)

    assert length(seat_1a_results) == 42
    assert length(other_seat_results) == 8
    assert length(seat_1a_success) == 1
    assert length(seat_1a_errors) == 41
    assert length(other_seat_success) == 8

    {_winner_id, _seat, {:ok, reservation}} = hd(seat_1a_success)
    assert reservation.seat_code == target_seat
    assert reservation.status == :pending

    {:ok, state} = FlightServer.get_state(server)
    assert state.seats[target_seat].status == :reserved
    assert state.seats[target_seat].reservation_id == reservation.id
    assert map_size(state.reservations) == 9
    assert map_size(state.passengers) == 50
  end

  defp seat_code(row, column), do: "#{row}#{column}"

  defp assert_all_seats_available_without_reservation(seats, seat_codes) do
    Enum.each(seat_codes, fn seat_code ->
      assert %{status: :available, reservation_id: nil} = seats[seat_code]
    end)
  end
end
