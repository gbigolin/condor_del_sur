# Cóndor del Sur - TP1 Taller de Programación

Sistema simplificado de reservas de asientos para una aerolínea regional.

El objetivo del TP es mostrar concurrencia sobre recursos limitados usando procesos manuales en Elixir, sin `GenServer`, `Supervisor`, `Task`, `Agent`, `Registry` ni behaviours de OTP.

## Creación del proyecto

El proyecto se creó con:

```bash
mix new condor_del_sur --no-sup
```

No utiliza árbol de supervisión ni módulo `Application` propio.

## Organización del código

La separación busca dejar claro qué parte cumple cada responsabilidad:

- `domain`: modelo de dominio con structs
- `processes`: procesos centrales del sistema con estado y loop recursivo
- `workers`: procesos puntuales para tareas cortas o auxiliares
- `demo.ex`: escenario reproducible por consola

## Compilación y Ejecución

Desde la carpeta del proyecto:

```bash
mix compile
```

Para validar todo el proyecto (resumen final):

```bash
mix test
```

Para ver cada test mientras se ejecuta (detalle en pantalla):

```bash
mix test --trace
```

Para correr la demo con expiración de 2 minutos :

```bash
iex -S mix
CondorDelSur.Demo.run()
```

Demo rápida para corrección visual:

```bash
iex -S mix
CondorDelSur.Demo.run(2_000)
```

## Demo 

La demo muestra:

- creación de vuelo con asientos
- registro de pasajeros
- competencia concurrente por el mismo asiento
- resolución correcta del conflicto
- confirmación mediante pago simulado
- cancelación de una reserva pendiente;
- expiración de una reserva pendiente;
- tarea auxiliar que no bloquea el sistema;
- estado final claro del vuelo;
- expiración configurada en 2 minutos (120_000 ms) según el enunciado.
- competencia sobre asientos ya ocupados/confirmados, donde el resultado esperado es 0 ganadores para ese asiento.

## Procesos principales

### `CondorDelSur.Processes.FlightServer`

Es el proceso central del sistema, mantiene el estado completo del vuelo:
* pasajeros
* asientos
* reservas
* contador de reservas
* referencias a workers de expiración monitoreados

Usa `send`, `receive` y loop recursivo. Todos los cambios de estado pasan por este proceso, por eso dos pasajeros no pueden quedarse con el mismo asiento al mismo tiempo.


### `CondorDelSur.Processes.PaymentServer`

Proceso para pagos simulados, cuando recibe una solicitud de pago, crea un proceso que espera un tiempo y luego pide al `FlightServer` confirmar la reserva.

Esto permite mostrar que una tarea lenta no bloquea al sistema principal.


### `CondorDelSur.Workers.ReservationExpirer`

Proceso para el vencimiento de las reservas.
Cuando se crea una reserva tiene estado pendiente, se lanza un worker de expiración. El worker tiene un tiempo de espera de 2 minutos 

```elixir
case Process.whereis(server_name) do
  pid when is_pid(pid) -> send(pid, {:expire_reservation, reservation_id})
  _ -> :ok
end
```

El `FlightServer` decide si la reserva debe expirar. Si ya fue confirmada o cancelada, ignora el mensaje para evitar estados inconsistentes.

### `CondorDelSur.Workers.AuxiliaryWorker`

Representa tareas auxiliares puntuales, por ejemplo enviar una notificación.
Se ejecuta con `spawn` para no bloquear la operatoria.


## Uso de `monitor`

El proyecto usa `Process.monitor/1` en tres lugares:
1. En el `FlightServer`, para monitorear procesos de expiración de reservas.
2. En el `PaymentServer`, para monitorear workers de pago.
3. En la demo, para monitorear procesos cliente que compiten concurrentemente.

Cuando un proceso monitoreado termina, llega un mensaje:
```Elixir
{:DOWN, ref, :process, pid, reason}
```

## Estados

### Reserva

- `pending`
- `confirmed`
- `cancelled`
- `expired`

### Asiento

- `available`
- `reserved`
- `confirmed`

## Reglas de negocio implementadas

- Al iniciar una reserva: reserva `:pending`, asiento `:reserved`.
- Al confirmar: reserva `:confirmed`, asiento `:confirmed`.
- Al cancelar antes de confirmar: reserva `:cancelled`, asiento `:available`.
- Al vencer sin confirmar: reserva `:expired`, asiento `:available`.
- Una reserva confirmada no puede cancelarse como pendiente.
- Un asiento no puede quedar asignado a dos pasajeros al mismo tiempo.
- Si varios pasajeros compiten por el mismo asiento, solo uno gana.
- El estado del vuelo se modifica en un solo proceso central para evitar inconsistencias.

## Patrones usados

- `Single Writer` para estado crítico: el `FlightServer` es el único proceso que modifica asientos y reservas.
- `Message Passing` para coordinación: todos los cambios se realizan con `send`/`receive`, sin memoria compartida.
- `Request/Reply` manual: se implementa un call propio con `make_ref` para pedir respuestas al `FlightServer`.
- `Fire-and-forget workers`: tareas puntuales (`ReservationExpirer`, worker de pago, `AuxiliaryWorker`) se ejecutan en procesos cortos que terminan.
- `Monitor para observabilidad`: procesos principales monitorean workers para registrar finalización y detectar fallos.

## Manejo de cuellos de botella

El cuello de botella principal está en `FlightServer`.

Donde muchos clientes pueden intentar reservar al mismo tiempo y el `FlightServer` procesa esos intentos de a uno.
El primer intento exitoso sobre un asiento lo bloquea, los siguientes intentos sobre ese mismo asiento fallan con `:seat_not_available`.

## Estrategia de concurrencia y procesos

- Concurrencia externa: múltiples procesos cliente compiten simultáneamente
- Serialización interna: el estado se actualiza en un loop recursivo único
- Trabajo lento fuera del proceso central: pagos simulados y expiraciones corren en workers separados para no bloquear la operatoria principal
- Coordinación temporal: una reserva secrea `:pending`, luego se cierra por confirmación (`:confirmed`), cancelación (`:cancelled`) o timeout (`:expired`)

## Tests incluidos

Casos cubiertos:
- reservar asiento disponible
- reservar asiento ocupado
- confirmar reserva pendiente
- cancelar reserva pendiente
- impedir cancelar reserva confirmada
- liberar asiento por expiración
- inicializar vuelo con asientos disponibles
- registrar pasajeros
- validar errores de pasajero/asiento/reserva inexistente
- verificar que una reserva confirmada no expira

## Nota sobre concurrencia

Aunque varios procesos cliente hagan solicitudes al mismo tiempo, los mensajes llegan al mailbox del `FlightServer` y se procesan de a uno por vez. Eso hace que la verificación y modificación del asiento sea atómica desde el punto de vista del sistema.

Por ejemplo, si tres pasajeros intentan reservar `1A`, el primer mensaje que procese el servidor cambia el asiento a `:reserved`. Los demás mensajes encuentran el asiento ocupado y reciben `{:error, :seat_not_available}`.
