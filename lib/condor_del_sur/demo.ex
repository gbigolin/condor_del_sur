defmodule CondorDelSur.Demo do
  alias CondorDelSur.Domain.Passenger
  alias CondorDelSur.Processes.{FlightServer, PaymentServer}
  alias CondorDelSur.Workers.AuxiliaryWorker

  def run, do: run(120_000)

  def run(expiration_ms) do
    cleanup_registered_processes()

    IO.puts("\n=== Cóndor del Sur ===\n")

    seat_codes = generate_seat_codes(2, ["A", "B", "C", "D", "E"])
    competition_seat = "1A"
    cancel_seat = "2E"
    expiring_seat = "2D"
    {:ok, _flight_pid} = FlightServer.start("CDS-123", seat_codes, :flight_server, expiration_ms)
    {:ok, _payment_pid} = PaymentServer.start(:payment_server, :flight_server)

    IO.puts("Vuelo creado: CDS-123")
    IO.puts("Asientos: #{Enum.join(seat_codes, ", ")}\n")

    passengers = [
      %Passenger{id: "P1", name: "Ana"},
      %Passenger{id: "P2", name: "Bruno"},
      %Passenger{id: "P3", name: "Carla"},
      %Passenger{id: "P4", name: "Diego"},
      %Passenger{id: "P5", name: "Eva"},
      %Passenger{id: "P6", name: "Fede"},
      %Passenger{id: "P7", name: "Gina"},
      %Passenger{id: "P8", name: "Hugo"},
      %Passenger{id: "P9", name: "Ines"},
      %Passenger{id: "P10", name: "Juan"},
      %Passenger{id: "P11", name: "Katia"},
      %Passenger{id: "P12", name: "Leo"},
      %Passenger{id: "P13", name: "Mora"},
      %Passenger{id: "P14", name: "Nico"},
      %Passenger{id: "P15", name: "Olga"},
      %Passenger{id: "P16", name: "Pablo"},
      %Passenger{id: "P17", name: "Quimey"},
      %Passenger{id: "P18", name: "Rocio"},
      %Passenger{id: "P19", name: "Santi"},
      %Passenger{id: "P20", name: "Tomas"}
    ]

    IO.puts("Registrando pasajeros...")

    Enum.each(passengers, fn passenger ->
      {:ok, _} = FlightServer.register_passenger(passenger)
    end)

    IO.puts("Pasajeros registrados: 20\n")

    winning_reservation = concurrent_competition_demo(competition_seat)
    payment_demo(winning_reservation, [{"P18", "1B"}, {"P19", "1C"}])
    cancellation_demo(cancel_seat)
    cancel_and_rebook_demo()
    tracked_reservations = cancellation_rebooking_demo("2A")
    expiration_demo(expiring_seat, tracked_reservations, expiration_ms)
    post_expiration_rebooking_demo(expiring_seat)
    auxiliary_task_demo()
    final_state_demo()

    PaymentServer.stop()
    FlightServer.stop()

    IO.puts("\n=== Fin de la demo ===")
  end

  defp concurrent_competition_demo(target_seat) do
    IO.puts("=== Competencia concurrente mixta (cuello de botella en #{target_seat}) ===")

    parent = self()

    clients = [
      {"Ana", "P1", "1A"},
      {"Bruno", "P2", "1A"},
      {"Carla", "P3", "1A"},
      {"Fede", "P6", "1A"},
      {"Gina", "P7", "1A"},
      {"Hugo", "P8", "1B"},
      {"Ines", "P9", "1C"},
      {"Juan", "P10", "1D"}
    ]

    client_pids =
      Enum.map(clients, fn {name, passenger_id, desired_seat} ->
        pid =
          spawn(fn ->
            # Pequeño sleep para que los clientes lleguen casi al mismo tiempo.
            Process.sleep(100)
            IO.puts("#{name} intenta reservar #{desired_seat}")
            result = FlightServer.reserve_seat(passenger_id, desired_seat)
            send(parent, {:competition_result, name, desired_seat, result})
          end)

        # La demo monitorea procesos cliente para mostrar Process.monitor/1.
        Process.monitor(pid)
        pid
      end)

    results = collect_competition_results(length(client_pids), [])

    IO.puts("\nResultado:")

    Enum.each(results, fn
      {name, desired_seat, {:ok, reservation}} ->
        IO.puts("#{name} obtuvo #{desired_seat} -> reserva #{reservation.id}")

      {name, desired_seat, {:error, reason}} ->
        IO.puts("#{name} no pudo obtener #{desired_seat}: #{inspect(reason)}")
    end)

    {_name, _desired_seat, {:ok, reservation}} =
      Enum.find(results, fn {_name, desired_seat, result} ->
        desired_seat == target_seat and match?({:ok, _}, result)
      end)

    successful_competitors =
      Enum.count(results, fn {_name, desired_seat, result} ->
        desired_seat == target_seat and match?({:ok, _}, result)
      end)

    IO.puts("Ganadores sobre #{target_seat}: #{successful_competitors} (debe ser 1)")
    IO.puts("")
    reservation
  end

  defp collect_competition_results(0, acc), do: Enum.reverse(acc)

  defp collect_competition_results(pending, acc) do
    receive do
      {:competition_result, name, desired_seat, result} ->
        collect_competition_results(pending - 1, [{name, desired_seat, result} | acc])

      {:DOWN, _ref, :process, pid, reason} ->
        IO.puts("[demo monitor] Cliente terminó. pid=#{inspect(pid)} reason=#{inspect(reason)}")
        collect_competition_results(pending, acc)
    after
      5_000 ->
        IO.puts("No llegaron todos los resultados de competencia")
        Enum.reverse(acc)
    end
  end

  defp payment_demo(reservation, extra_attempts) do
    IO.puts("=== Confirmación por pago ===")
    :ok = PaymentServer.pay(reservation.id)

    receive do
      {:payment_started, reservation_id} -> IO.puts("Pago iniciado para #{reservation_id}")
    after
      1_000 -> IO.puts("No se pudo iniciar el pago")
    end

    receive do
      {:payment_result, reservation_id, {:ok, confirmed}} ->
        IO.puts("Pago aprobado. Reserva #{reservation_id} quedó #{confirmed.status}.\n")

      {:payment_result, reservation_id, error} ->
        IO.puts("Pago para #{reservation_id} falló: #{inspect(error)}\n")
    after
      3_000 -> IO.puts("No llegó respuesta del pago\n")
    end

    confirm_pending_seat_if_any("1D")

    Enum.each(extra_attempts, fn {passenger_id, seat_code} ->
      case FlightServer.reserve_seat(passenger_id, seat_code) do
        {:ok, reservation} ->
          IO.puts("Reserva creada para #{passenger_id} en #{seat_code}: #{reservation.id}")
          :ok = PaymentServer.pay(reservation.id)
          await_payment_result(reservation.id)

        {:error, reason} ->
          IO.puts(
            "No se pudo reservar #{seat_code} para #{passenger_id}: #{inspect(reason)} (no se inicia pago)"
          )
      end
    end)

    IO.puts("")
  end

  defp confirm_pending_seat_if_any(seat_code) do
    {:ok, state} = FlightServer.get_state()

    reservation =
      state.reservations
      |> Map.values()
      |> Enum.find(fn reservation ->
        reservation.seat_code == seat_code and reservation.status == :pending
      end)

    case reservation do
      nil ->
        IO.puts("No había reserva pendiente para #{seat_code} para confirmar por pago.")

      reservation ->
        IO.puts("Se confirma también la reserva pendiente de #{seat_code}: #{reservation.id}")
        :ok = PaymentServer.pay(reservation.id)
        await_payment_result(reservation.id)
    end
  end

  defp cancellation_demo(target_seat) do
    IO.puts("=== Cancelación ===")
    {:ok, reservation} = FlightServer.reserve_seat("P4", target_seat)
    IO.puts("Reserva #{reservation.id} creada sobre asiento #{reservation.seat_code}.")

    {:ok, cancelled} = FlightServer.cancel_reservation(reservation.id)
    IO.puts("Reserva #{cancelled.id} cancelada. Asiento #{target_seat} liberado.\n")
  end

  defp cancel_and_rebook_demo do
    IO.puts("=== Pasajero se arrepiente: cancela, reserva otro y confirma ===")

    {:ok, first_reservation} = FlightServer.reserve_seat("P18", "2A")
    IO.puts("Rocio reservó 2A (#{first_reservation.id})")

    {:ok, _cancelled} = FlightServer.cancel_reservation(first_reservation.id)
    IO.puts("Rocio canceló 2A")

    {:ok, second_reservation} = FlightServer.reserve_seat("P18", "2E")
    IO.puts("Rocio reservó 2E (#{second_reservation.id})")

    :ok = PaymentServer.pay(second_reservation.id)
    await_payment_result(second_reservation.id)
    IO.puts("")
  end

  defp cancellation_rebooking_demo(target_seat) do
    {:ok, state} = FlightServer.get_state()
    seat_status = state.seats[target_seat].status
    expected_winners = if seat_status == :available, do: 1, else: 0

    IO.puts("=== Competencia sobre asiento #{target_seat} (estado actual: #{seat_status}) ===")
    parent = self()

    clients = [
      {"Katia", "P11", target_seat},
      {"Leo", "P12", target_seat},
      {"Mora", "P13", target_seat},
      {"Nico", "P14", "2A"},
      {"Olga", "P15", "2B"},
      {"Pablo", "P16", "2C"}
    ]

    Enum.each(clients, fn {name, passenger_id, desired_seat} ->
      spawn(fn ->
        Process.sleep(50)
        result = FlightServer.reserve_seat(passenger_id, desired_seat)
        send(parent, {:rebooking_result, name, desired_seat, result})
      end)
    end)

    results =
      Enum.map(1..length(clients), fn _ ->
        receive do
          {:rebooking_result, name, seat, result} -> {name, seat, result}
        after
          5_000 -> {"timeout", target_seat, {:error, :timeout}}
        end
      end)

    Enum.each(results, fn
      {name, seat, {:ok, reservation}} ->
        IO.puts("#{name} obtuvo #{seat} -> reserva #{reservation.id}")

      {name, seat, {:error, reason}} ->
        IO.puts("#{name} no pudo obtener #{seat}: #{inspect(reason)}")
    end)

    winners_on_target =
      Enum.count(results, fn {_name, seat, result} ->
        seat == target_seat and match?({:ok, _}, result)
      end)

    IO.puts(
      "Ganadores sobre #{target_seat}: #{winners_on_target} (debe ser #{expected_winners})\n"
    )

    Enum.flat_map(results, fn
      {_name, _seat, {:ok, reservation}} -> [reservation]
      _ -> []
    end)
  end

  defp expiration_demo(target_seat, tracked_reservations, expiration_ms) do
    IO.puts("=== Expiración ===")
    {:ok, reservation} = FlightServer.reserve_seat("P5", target_seat)
    IO.puts("Reserva #{reservation.id} creada sobre asiento #{reservation.seat_code}.")
    observed_reservations = tracked_reservations ++ [reservation]

    IO.puts("Estas reservas quedan pending porque no se pagan y deberían expirar en #{div(expiration_ms, 1_000)} segundos:")
    print_reservations_snapshot(observed_reservations)
    IO.puts("Esperando vencimiento...")

    # La expiración real la dispara un worker. Este sleep solo permite verla en la demo.
    Process.sleep(expiration_ms + 500)

    IO.puts("Estado después del timeout de #{div(expiration_ms, 1_000)} segundos:")
    print_reservations_snapshot(observed_reservations)
    IO.puts("")
  end

  defp post_expiration_rebooking_demo(target_seat) do
    IO.puts("=== Reuso de asiento tras expiración (#{target_seat}) ===")

    case FlightServer.reserve_seat("P17", target_seat) do
      {:ok, reservation} ->
        {:ok, state} = FlightServer.get_state()
        current_reservation = state.reservations[reservation.id]
        seat = state.seats[target_seat]

        IO.puts("Quimey reservó #{target_seat} después de la expiración -> #{reservation.id}")

        IO.puts(
          "Sin pago, queda en reserva=#{current_reservation.status} y asiento_estado=#{seat.status}\n"
        )

      {:error, reason} ->
        IO.puts("No se pudo reutilizar #{target_seat}: #{inspect(reason)}\n")
    end
  end

  defp await_payment_result(reservation_id) do
    receive do
      {:payment_started, ^reservation_id} ->
        IO.puts("Pago iniciado para #{reservation_id}")
        await_payment_result(reservation_id)

      {:payment_result, ^reservation_id, {:ok, confirmed}} ->
        IO.puts("Pago aprobado. Reserva #{reservation_id} quedó #{confirmed.status}.")

      {:payment_result, ^reservation_id, error} ->
        IO.puts("Pago para #{reservation_id} falló: #{inspect(error)}")
    after
      4_000 -> IO.puts("No llegó respuesta del pago para #{reservation_id}")
    end
  end

  defp print_reservations_snapshot(reservations) do
    {:ok, state} = FlightServer.get_state()

    reservations
    |> Enum.sort_by(& &1.seat_code)
    |> Enum.each(fn reservation ->
      current_reservation = state.reservations[reservation.id]
      seat = state.seats[reservation.seat_code]

      IO.puts(
        "- #{reservation.id} asiento=#{reservation.seat_code} reserva=#{current_reservation.status} asiento_estado=#{seat.status}"
      )
    end)
  end

  defp auxiliary_task_demo do
    IO.puts("=== Tarea auxiliar ===")
    AuxiliaryWorker.notify_async("enviar notificación al pasajero", 700)
    IO.puts("La tarea auxiliar fue lanzada y la demo sigue sin bloquearse.")
    Process.sleep(900)
    IO.puts("")
  end

  defp final_state_demo do
    IO.puts("=== Estado final del vuelo ===")
    {:ok, state} = FlightServer.get_state()

    IO.puts("Vuelo: #{state.flight_code}\n")

    IO.puts("Asientos:")

    state.seats
    |> Enum.sort_by(fn {code, _seat} -> code end)
    |> Enum.each(fn {code, seat} ->
      IO.puts("- #{code}: #{seat.status} reserva=#{inspect(seat.reservation_id)}")
    end)

    IO.puts("\nReservas:")

    state.reservations
    |> Enum.sort_by(fn {id, reservation} -> {reservation.seat_code, id} end)
    |> Enum.each(fn {id, reservation} ->
      IO.puts(
        "- #{id}: pasajero=#{reservation.passenger_id} asiento=#{reservation.seat_code} estado=#{reservation.status}"
      )
    end)
  end

  defp cleanup_registered_processes do
    Enum.each([:payment_server, :flight_server], fn name ->
      case Process.whereis(name) do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end
    end)

    Process.sleep(50)
  end

  defp generate_seat_codes(rows, columns) do
    for row <- 1..rows, col <- columns, do: "#{row}#{col}"
  end
end
