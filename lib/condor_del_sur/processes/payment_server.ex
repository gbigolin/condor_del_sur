defmodule CondorDelSur.Processes.PaymentServer do
  alias CondorDelSur.Processes.FlightServer

  def start(name \\ :payment_server, flight_server \\ :flight_server) do
    if Process.whereis(name),
      do: raise("Ya existe un proceso registrado con el nombre #{inspect(name)}")

    pid = spawn(__MODULE__, :loop, [%{name: name, flight_server: flight_server}])

    true = Process.register(pid, name)

    {:ok, pid}
  end

  def stop(server \\ :payment_server) do
    send(server, :stop)
    :ok
  end

  def pay(reservation_id, server \\ :payment_server) do
    send(server, {:pay, reservation_id, self()})
    :ok
  end

  def loop(state) do
    receive do
      {:pay, reservation_id, client_pid} ->
        worker_pid =
          spawn(fn ->
            IO.puts("[pago] Procesando pago de #{reservation_id}...")
            Process.sleep(800)
            result = FlightServer.confirm_reservation(reservation_id, state.flight_server)
            send(client_pid, {:payment_result, reservation_id, result})
          end)

        Process.monitor(worker_pid)

        send(client_pid, {:payment_started, reservation_id})
        loop(state)

      {:DOWN, _ref, :process, pid, reason} ->
        IO.puts(
          "[payment monitor] Worker de pago terminó. pid=#{inspect(pid)} reason=#{inspect(reason)}"
        )

        loop(state)

      :stop ->
        :ok

      unknown ->
        IO.puts("[payment_server] Mensaje desconocido: #{inspect(unknown)}")
        loop(state)
    end
  end
end
