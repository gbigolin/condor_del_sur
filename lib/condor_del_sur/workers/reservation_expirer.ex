defmodule CondorDelSur.Workers.ReservationExpirer do
  def start(server_name, reservation_id, expiration_ms) do
    spawn(fn ->
      Process.sleep(expiration_ms)

      case Process.whereis(server_name) do
        pid when is_pid(pid) -> send(pid, {:expire_reservation, reservation_id})
        _ -> :ok
      end
    end)
  end
end
