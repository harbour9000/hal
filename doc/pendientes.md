# Lo que falta — límites funcionales de las dos clases

> No son bugs: son **decisiones conscientes** del diseño mínimo
> actual. Este documento inventaría qué no sabe hacer el BPM hoy y
> propone un orden de prioridad para añadirlo.

---

## 1. `ProcessDefinition` — qué no modela

### Topología que no sabe dibujar

- **Gateways paralelos (AND-split / AND-join).** Solo hay rombos
  exclusivos (XOR). No puedes "notificar al proveedor **y** registrar
  en libro mayor en paralelo, y continuar cuando ambas acaben".
- **Subprocesos.** No puedes meter un proceso dentro de otro
  (una "aprobación compleja" reutilizable como caja negra).
- **Eventos de borde**: cancelar, escalar, timeout. Si una factura
  lleva 7 días en `manual_approve`, el proceso no lo sabe.
- **Hooks por estado** (`on_enter` / `on_exit`). Solo hay
  `SetDecision`. Si quieres hacer algo "cuando entras a `approved`",
  hay que meterlo dentro de la acción anterior.
- **Múltiples entradas semánticas.** Solo una transición. Si
  quisieras `receive_email` y `receive_edi` cayendo ambos en
  `received`, hay que declararlos como dos transiciones distintas.

### Metadatos que no guarda

- **Descripciones / etiquetas.** Estados y acciones son solo nombres.
  No hay `description`, `label`, `color`.
- **Estados "terminales" explícitos.** `approved` y `received` son
  indistinguibles para el proceso; eres tú quien sabe que uno es fin.
- **Versión del proceso.** Si modificas la fábrica con instancias
  vivas, mezclas versiones y nadie se entera.
- **Owner / dominio.** No hay forma de agrupar procesos.

### Reglas (nivel 2) limitadas

- `roles` solo **OR** (al menos uno). No hay AND
  (`approver AND finance`), no hay negación.
- `fields` solo "no vacío". Sin tipo, patrón, longitud.
- `limit` solo **máximo**. Sin mínimo, sin rango.
- No hay forma de registrar reglas **custom** (no hay plugin).
- Las reglas solo se aplican a lo que pide el **usuario**; las
  acciones automáticas no tienen filtro.

### Interoperabilidad

- **No es serializable.** Los handlers son code blocks → imposible
  exportar a JSON/BPMN/graphviz. Sin esto, no hay editor visual ni
  introspección para una IA/MCP ("descríbeme el proceso").
- **`Validate()` es solo estructural.** No detecta: estados
  huérfanos (nadie llega a ellos), bucles de cascada en tiempo de
  definición, acciones inalcanzables.

---

## 2. `BpmEngine` — qué no sabe hacer

### Las dos grandes (bloquean producción)

1. **Persistencia.** `hInstances` es memoria. Reinicio = pérdida
   total. Sin snapshot/restore ni backend DBF/SQLite.
2. **Concurrencia por instancia.** Dos `Run` paralelos sobre el
   mismo `cKey` pueden pisarse (`hb_HMerge`, cambio de `state`,
   limpieza de `pending`). Falta mutex por clave.

### Semántica de ejecución incompleta

- **Sin transacciones.** Si un handler explota a mitad, la instancia
  queda a medias (datos modificados, estado no, log incompleto).
  No hay rollback.
- **Sin timeouts de handler.** Un handler que haga HTTP y se cuelgue
  cuelga la petición completa.
- **Sin cancelar / abortar.** No hay `Cancel(oProc, cId)`. Una
  instancia pendiente lo está para siempre.
- **Sin reintentos.** Si una acción automática falla porque un
  servicio externo está caído, no hay retry.
- **Sin SLAs / timers.** "Si lleva 48 h en pending, escala" no
  existe.
- **Sin compensación.** Si el paso 4 falla, no puedes deshacer los
  pasos 1–3.

### Observabilidad y lectura escasas

- **No hay `List()`.** No puedes preguntar "dame todas las
  instancias en `pending`" ni filtrar por proceso, estado, usuario,
  fecha. Solo `Get(id)`.
- **No hay métricas.** Tiempo medio en cada estado, tasa de
  aprobación automática, cuellos de botella… nada.
- **Intentos fallidos no se auditan.** Si Ana (sin rol) prueba
  `manual_approve` tres veces, no queda rastro. El historial solo
  guarda pasos exitosos.
- **Errores sin estructura.** `error` es un string. No `error_code`,
  no `rule_name`, no `field`. Un consumidor (humano o IA) tiene que
  parsear texto.
- **Diffs no explícitos.** Sabes qué acción corrió, pero no "qué
  cambió en `data`".

### Capacidades que faltan para un MCP / IA

- **Introspección.** No puedes preguntarle al motor: "¿qué acciones
  puede ejecutar ahora el usuario X sobre la instancia Y?". Habría
  que calcularlo (ver `pending` + evaluar `CheckRules` sin aplicar).
- **Dry-run / simulate.** "Si llamo con estos datos, ¿qué pasaría?"
  → para que una IA proponga sin ejecutar.
- **Eventos / suscripciones.** "Avísame cuando una instancia cambie
  de estado." Hoy solo puedes meterlo dentro del handler.
- **Trigger externo.** Reanudar una instancia pendiente desde fuera
  (webhook, cron) requiere montar HTTP manualmente.

### Higiene

- **`Validate()` en cada `Run`.** Barato pero redundante. Un flag
  `::lValidated` lo cachea trivialmente.
- **Dos canonicalizaciones separadas** (`Lower+AllTrim` en el motor
  vs. `Canon()` en la definición). Hacen lo mismo pero pueden
  derivar si una cambia y la otra no.
- **Instancias no se pueden borrar.** Si rechazas una factura, se
  queda en `hInstances` para siempre.

---

## 3. El camino crítico — por orden de impacto

Si tuvieras que elegir qué añadir **primero** para que esto fuera
usable más allá de un demo, este es el orden razonable:

1. **Persistencia de `hInstances`** (DBF/SQLite + snapshot al final
   de cada `Run`). Sin esto, cualquier uso serio es imposible.
2. **Mutex por `cKey`** (lock HIX o similar) → concurrencia segura.
3. **`List()` / consulta** sobre instancias → sin esto, operar
   varias facturas es ciego.
4. **Errores estructurados** (`{ code, message, context }`) →
   prerrequisito para que una IA razone sobre fallos.
5. **Introspección** del proceso (serializar el grafo, sin
   handlers) → prerrequisito para el servidor MCP.
6. **Timeouts / SLA** sobre `pending` → primera necesidad real
   cuando el proceso tiene humanos esperando.
7. **Transacciones de handler** (try/revert) → crítico el día que
   los handlers hagan I/O real (BBDD, HTTP).

Lo demás (gateways paralelos, subprocesos, versioning, métricas
finas, hooks por estado) es BPMN "serio" y puede esperar hasta
tener casos reales que lo exijan.

---

## 4. Lo que **sí** merece quedarse como está

Para no confundir "falta" con "está mal":

- **Un único punto de entrada (`Run`)**: no complicar.
- **Devolver siempre un hash homogéneo**: lo convierte en MCP-friendly.
- **Separación definición/motor**: el pilar; no tocar.
- **Freno anti-bucles con `MAX_STEPS=100`**: suficiente, no se
  necesita más.
- **Historial embebido en la instancia**: simple y eficaz.
- **Duck typing en `oProcess` y `oUser`**: deja la puerta abierta
  a mocks y a objetos externos (sesiones HIX, usuarios de BBDD) sin
  acoplamiento.

Estos siete puntos son los que hay que **no romper** cuando se
añadan las piezas pendientes.
