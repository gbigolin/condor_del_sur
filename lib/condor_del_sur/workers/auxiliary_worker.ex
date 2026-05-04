defmodule CondorDelSur.Workers.AuxiliaryWorker do
  @spec notify_async(any(), any()) :: pid()
  def notify_async(text, delay_ms \\ 500) do
    spawn(fn ->
      IO.puts("[auxiliar] Iniciando tarea auxiliar: #{text}")
      # Simula una tarea lenta externa al dominio principal.
      Process.sleep(delay_ms)
      IO.puts("[auxiliar] Tarea auxiliar finalizada: #{text}")
    end)
  end
end
