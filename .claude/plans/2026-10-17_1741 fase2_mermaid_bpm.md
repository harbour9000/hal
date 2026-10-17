# Plan — Fase 2: Mermaid ↔ BPM (ToMermaid + FromMermaid)

**Fecha**: 2026-10-17 17:41
**Proyecto**: `C:\hix.hal`
**Alcance**: permitir que un diseñador exprese un proceso BPM escribiendo un `flowchart` de Mermaid, y que HIX HAL lo cargue como `ProcessDefinition` ejecutable. Incluye el camino inverso (`ToMermaid`) como paso previo para fijar las convenciones y validarlas con round-trip.
**Depende de**: Plan rev2 (`2026-10-17_1121 serializacion_del_grafo.md`) — `bpm/v1` JSON, `AddHandler`, `FromHash` deben estar cerrados.

> **Objetivo final del proyecto**: Mermaid → BPM ejecutable. Este plan es el puente que convierte un diagrama Mermaid que un diseñador dibuja (o le pide a una IA) en un proceso que corre en el motor.

---

## 1. Hipótesis

Mermaid `flowchart` es un subset pequeño, regular, y **sintácticamente obliga a elegir shape** por nodo (`([x])`, `{x}`, `[x]`, `((x))`). Eso significa que el **tipo de nodo BPM** (estado / decisión / acción / inicio) **se deduce del shape** sin anotaciones extra. Es el mejor bang/buck para evitar un DSL propio o un editor visual.

El JSON canónico `bpm/v1` ya existe (fase 1). Mermaid es solo **otra representación** del mismo grafo. Por tanto:

1. **ToMermaid**: proyectar `ProcessDefinition:ToHash()` → texto Mermaid. Determinista.
2. **FromMermaid**: parsear Mermaid → hash `bpm/v1` → `ProcessDefinition:FromHash()`. Reusa toda la fase 1.
3. **Round-trip**: `mermaid → hash → mermaid'` debe producir **el mismo grafo** (comparación semántica, no textual, porque orden de líneas puede variar).

Hacer `ToMermaid` **primero** garantiza que las convenciones son coherentes antes de escribir el parser inverso. Si tu propio exportador no puede expresar X, el diseñador tampoco lo podrá.

---

## 2. Convenciones Mermaid ↔ `bpm/v1`

### 2.1 Nodos (shape → tipo)

| Mermaid | Tipo BPM | Dónde cae en `bpm/v1` |
|---|---|---|
| `Inicio((Inicio))` | start event | No se persiste. Marca el **origen** de la primera `transition`. |
| `nuevo([nuevo])` | estado | `states` |
| `con_pina{con_pina}` | decisión | `decisions` (nombre = id del nodo) |
| `rechazar[rechazar]` | acción | `actions` |

Convenciones:

- **ID del nodo = clave canónica** en `bpm/v1` (`snake_case`, lo que Mermaid ya favorece).
- La **label** entre delimitadores puede diferir del id (`cocinar_rapido[Cocinar rápido]`). Si difiere, se almacena como `label` en el futuro `description`-slot (fuera de alcance de este plan — por ahora se descarta y warn).
- Si falta el `((Inicio))`: se asume que la primera arista `A -->|t| B` donde `A` **no está declarado como nodo** marca la transición. Es más laxo pero funciona.
- `classDef` + `class X estado` se usa **solo como fallback** si un nodo no tiene shape canónica (ej. alguien escribe `nuevo` suelto sin delimitadores). Shape siempre gana sobre class.

### 2.2 Aristas (edge → relación)

| Mermaid | Significado |
|---|---|
| `Inicio -->\|order\| nuevo` | `transitions.order = { state: 'nuevo' }` |
| `nuevo -.->\|con_pina\| con_pina` | `state_decisions.nuevo = 'con_pina'` — **arista punteada** desde estado a decisión |
| `con_pina -->\|si\| rechazar` | `decisions.con_pina.yes = 'rechazar'` |
| `con_pina -->\|no\| por_vip` | `decisions.con_pina.no = 'por_vip'` |
| `rechazar --> rechazado` | `actions.rechazar.state = 'rechazado'` — arista sin label desde acción a estado |

Reglas de parsing:

1. **Arista sólida con label desde `Inicio`** → `transition`. Label = nombre de la transición.
2. **Arista punteada** (`-.->`): siempre `state_decisions`. El label (`SetDecision: ...`) es decorativo, el parser lo ignora — solo mira `from` (estado) y `to` (decisión).
3. **Arista sólida desde decisión** → `decisions[from][label] = to`. Labels esperadas: `yes` / `no` (o `si` / `sí` → se normalizan a `yes`).
4. **Arista sólida desde acción** → `actions[from].state = to`.
5. **Arista sólida desde estado a decisión** (sin punteada) → interpretar como `state_decisions`. Warning: mejor usar punteada para claridad.

Normalización de labels:
- `si`, `sí`, `yes`, `y`, `true` → `yes`
- `no`, `n`, `false` → `no`
- Cualquier otro label en arista de decisión → warning, se almacena literal (futuro: decisiones multi-rama).

### 2.3 Anotaciones embebidas (metadatos no-topológicos)

Lo que **no** está en el grafo puro va en comentarios Mermaid `%%` con prefijo `@`:

```mermaid
%% @name pizzeria
%% @rule order fields=cliente,direccion
%% @rule aprobar roles=supervisor
%% @handler rechazar Approve@PizzaService
%% @manual cocinar_normal
```

| Comentario | Efecto en `bpm/v1` |
|---|---|
| `%% @name <id>` | `name` del proceso. Si falta → nombre del fichero sin extensión. |
| `%% @rule <nodo> fields=a,b,c` | `rules.<nodo>.fields = ['a','b','c']` |
| `%% @rule <nodo> roles=a,b` | `rules.<nodo>.roles = ['a','b']` |
| `%% @rule <nodo> limit=1000` | `rules.<nodo>.limit = 1000` |
| `%% @handler <nodo> <executor>` | `handlers.<nodo>.executor = '<executor>'` (sobrescribe la convención PascalCase) |
| `%% @container <nodo> <path>` | `handlers.<nodo>.container = '<path>'` (sobrescribe el default `<name>/handlers`) |
| `%% @manual <accion>` | `actions.<accion>.manual = true` |

Convenciones por defecto (sin anotaciones):
- `container` de todos los handlers = `<name>/handlers`.
- `executor` = PascalCase del id del nodo.
- `actions.*.manual` = `false`.

### 2.4 Reglas embebidas en labels de aristas (compat con `pizza.mermaid`)

El ejemplo existente usa:

```
Inicio -->|order<br/>regla: fields=cliente| nuevo
```

El label tiene dos líneas (`<br/>` separador). La primera es el nombre de la transición; las siguientes con prefijo `regla:` se parsean como `rules.<transition>.fields`. Es sugar sintáctico — equivalente a `%% @rule order fields=cliente`. Soportarlo es **opcional** en v1; si cuesta, exigir `%% @rule`.

**Decisión por tomar**: ¿aceptamos la variante `<br/>regla:` o forzamos siempre `%% @rule`? La segunda opción simplifica el parser; la primera respeta lo que ya existe en `pizza.mermaid`. Mi recomendación: **aceptar ambas en v1**, documentar la de `%% @rule` como canónica.

---

## 3. ToMermaid (fase 2.1)

### 3.1 Firma

```harbour
METHOD ToMermaid( hOpts ) CLASS ProcessDefinition  → STRING
```

`hOpts` opcional con flags cosméticos:
- `pretty` (default `.T.`) → añade `classDef` y `class X Y` para colorear.
- `include_meta` (default `.T.`) → emite comentarios `%% @...` para rules, handler overrides, manual.

### 3.2 Algoritmo (determinista)

Orden fijo de salida — crítico para que el round-trip textual sea estable (aunque los tests comparan semánticamente):

1. Header: `flowchart TD`.
2. Comentarios de metadatos (`%% @name`, luego `%% @rule`, `%% @handler`, `%% @manual`) ordenados por nodo alfabéticamente.
3. Inicio + primera transición: `Inicio((Inicio)) -->|<transition_name>| <first_state>`.
4. Para cada estado con `state_decision`: `<state> -.->|SetDecision: <state> → <decision>| <decision>`.
5. Para cada decisión: dos aristas `yes` / `no` ordenadas.
6. Para cada acción: una arista hacia su `state`.
7. Nodos terminales (estados que no aparecen como origen de ninguna arista) se declaran al final con su shape, por si Mermaid no los infiere.
8. `classDef` + `class` (si `pretty=.T.`).

### 3.3 Esqueleto

```harbour
METHOD ToMermaid( hOpts ) CLASS ProcessDefinition
   LOCAL cOut := 'flowchart TD' + hb_eol()
   LOCAL hGraph := ::ToHash()

   cOut += EmitMetaComments( hGraph )
   cOut += EmitStartEdge( hGraph )
   cOut += EmitStateDecisions( hGraph )
   cOut += EmitDecisions( hGraph )
   cOut += EmitActions( hGraph )
   cOut += EmitTerminals( hGraph )

   IF hb_HGetDef( hOpts, 'pretty', .T. )
      cOut += EmitClassDefs()
      cOut += EmitClassAssignments( hGraph )
   ENDIF

RETURN cOut
```

Cada `Emit*` es una función privada de ~15-25 líneas. Total ~150 líneas.

---

## 4. FromMermaid (fase 2.2)

### 4.1 Firma

```harbour
CLASS METHOD FromMermaid( cText, hOpts ) CLASS ProcessDefinition  → ProcessDefinition
```

`hOpts`:
- `name` → fuerza el nombre del proceso (prioridad sobre `%% @name`).
- `strict` (default `.F.`) → si `.T.`, cualquier warning se convierte en error (devuelve `NIL`).

### 4.2 Pipeline (3 pasadas)

```
Mermaid text
  ↓ (1) Tokenizer: línea → { type, payload }
  ↓ (2) Builder: tokens → GraphIR
  ↓ (3) Projector: GraphIR → hash bpm/v1
  ↓
FromHash() de fase 1
```

**GraphIR** es un hash intermedio:

```harbour
{
   'name'      => 'pizzeria',
   'start'     => { 'label' => 'order', 'target' => 'nuevo' },
   'nodes'     => { 'nuevo' => { 'shape' => 'stadium',  'label' => 'nuevo' },
                    'con_pina' => { 'shape' => 'rhombus', 'label' => 'con_pina' },
                    ... },
   'edges'     => { { 'from' => 'con_pina', 'to' => 'rechazar',
                      'label' => 'si', 'style' => 'solid' }, ... },
   'meta_rules'    => { 'order' => { 'fields' => ['cliente'] } },
   'meta_handlers' => { 'rechazar' => { 'executor' => 'Approve@PizzaService' } },
   'meta_manual'   => { 'cocinar_normal' => .T. },
   'warnings'  => {}
}
```

### 4.3 Tokenizer (pasada 1)

Reconoce 5 tipos de línea con regex:

| Pattern | Token |
|---|---|
| `^\s*%%\s*@(\w+)\s+(.*)$` | `meta` |
| `^flowchart\s+(TD\|LR\|BT\|RL)` | `header` (se ignora, solo valida) |
| `^classDef\s+(\w+)\s+(.+)$` | `classdef` (se ignora en v1) |
| `^class\s+([\w,]+)\s+(\w+)$` | `class_assign` (solo para fallback de tipo) |
| `^(\w+)([\(\[\{].*?[\)\]\}])\s*(-\.?->\|?\s*(.*?)\s*\|?)\s*(\w+)([\(\[\{].*?[\)\]\}])?` | `edge_with_nodes` |
| `^(\w+)\s*(-\.?->)\|?(.*?)\|?\s*(\w+)` | `edge_bare` |

El regex de edges parece bestia pero cubre los 4 casos: con/sin shape en origen, con/sin shape en destino, con/sin label, sólida/punteada.

**Decisión práctica**: usar `hb_regex` con flags case-insensitive. Si el parser se complica, dividir en dos pasadas de regex (nodos primero, aristas después) sobre las mismas líneas.

### 4.4 Builder (pasada 2)

Recorre tokens y construye el GraphIR:

- Cada vez que ve un nodo con shape nueva → actualiza `nodes[id].shape`.
- Cada arista → push a `edges`.
- Cada `meta` → despacha a `meta_rules` / `meta_handlers` / `meta_manual`.
- Al final, para cada id de nodo sin shape detectada → mira `class_assign` como fallback. Sin fallback → warning.

### 4.5 Projector (pasada 3)

Convierte GraphIR a hash `bpm/v1`:

```harbour
STATIC FUNCTION ProjectToV1( hIR )
   LOCAL hOut := { 'schema' => 'bpm/v1', 'name' => hIR['name'] }

   // states = todos los nodos con shape 'stadium' o 'round' (excepto Inicio)
   hOut['states'] := CollectByShape( hIR, { 'stadium', 'round' } )

   // decisions
   hOut['decisions'] := { => }
   FOR EACH hEdge IN hIR['edges']
      IF ShapeOf( hIR, hEdge['from'] ) == 'rhombus'
         AddDecisionBranch( hOut['decisions'], hEdge )
      ENDIF
   NEXT

   // actions
   hOut['actions'] := { => }
   FOR EACH hEdge IN hIR['edges']
      IF ShapeOf( hIR, hEdge['from'] ) == 'rectangle'
         hOut['actions'][ hEdge['from'] ] := { ;
            'state'  => hEdge['to'], ;
            'manual' => hb_HGetDef( hIR['meta_manual'], hEdge['from'], .F. ) }
      ENDIF
   NEXT

   // transitions: la que sale de 'Inicio'
   hOut['transitions'] := { hIR['start']['label'] => { 'state' => hIR['start']['target'] } }

   // state_decisions: aristas punteadas
   hOut['state_decisions'] := { => }
   FOR EACH hEdge IN hIR['edges']
      IF hEdge['style'] == 'dotted'
         hOut['state_decisions'][ hEdge['from'] ] := hEdge['to']
      ENDIF
   NEXT

   // rules (de meta)
   hOut['rules'] := hb_HClone( hIR['meta_rules'] )

   // handlers: convención PascalCase para todos los nodos ejecutables
   hOut['handlers'] := BuildHandlers( hIR, hOut )

RETURN hOut
```

`BuildHandlers` recorre `decisions` + `actions` (los nodos "ejecutables") y para cada uno aplica:
- `container` = `meta_handlers.<nodo>.container` ?? `<name>/handlers`
- `executor` = `meta_handlers.<nodo>.executor` ?? PascalCase(nodo)

### 4.6 Validaciones (strict mode)

Warnings/errores que debe emitir el parser:

- Nodo declarado con shape pero sin aristas de salida (acción huérfana).
- Decisión sin `yes` o sin `no`.
- Label de arista desde decisión que no sea `yes/no/si/sí/no` → warning (futuro: multi-rama).
- Arista punteada desde algo que no es estado → error.
- `transition` que apunta a un nodo que no es estado → error.
- `@handler` o `@rule` sobre un nodo que no existe → warning.

En `strict=.F.` se devuelve el proceso con `oProc:aWarnings` poblado; en `strict=.T.` devuelve `NIL`.

---

## 5. Ruta HTTP y controller

### 5.1 `POST /process/from-mermaid`

```json
{ "name": "pizzeria", "mermaid": "flowchart TD\n..." }
```

Respuesta:

```json
{
  "ok": true,
  "name": "pizzeria",
  "warnings": [],
  "describe": { ... ToHash() ... }
}
```

### 5.2 `GET /process/to-mermaid?name=invoice_simple`

Devuelve `text/plain` con el Mermaid generado por `ToMermaid()`. Útil para que una IA pida "dame el diagrama de este proceso" vía MCP.

### 5.3 Rutas

```json
{ "name": "to_mermaid",   "url": "/process/to-mermaid",   "action": "controllers/to_mermaid.prg",   "method": "GET"  }
{ "name": "from_mermaid", "url": "/process/from-mermaid", "action": "controllers/from_mermaid.prg", "method": "POST" }
```

---

## 6. Tests (suite nueva `mermaid` en `test.prg`)

| # | Nombre | Qué comprueba |
|---|--------|---------------|
| 1 | `ToMermaid header is flowchart TD` | primera línea = `flowchart TD` |
| 2 | `ToMermaid emits Inicio start` | contiene `Inicio((Inicio))` + arista |
| 3 | `ToMermaid emits states with stadium shape` | `received([received])` presente |
| 4 | `ToMermaid emits decisions with rhombus` | `complete{complete}` presente |
| 5 | `ToMermaid emits actions with rectangle` | `notify_supplier[notify_supplier]` presente |
| 6 | `ToMermaid emits state_decision as dotted` | `received -.->` presente |
| 7 | `ToMermaid emits @rule meta` | `%% @rule order fields=cliente` presente |
| 8 | `ToMermaid emits @handler meta for overrides` | `%% @handler manual_approve Approve@InvoiceService` |
| 9 | `FromMermaid parses basic pizza` | el `pizza.mermaid` existente → `oProc` válido con 3 estados, 2 decisiones, 3 acciones |
| 10 | `FromMermaid detects shapes correctly` | `con_pina{...}` → decisión, `rechazar[...]` → acción |
| 11 | `FromMermaid normalizes si/sí/yes` | las tres variantes caen en `yes` |
| 12 | `FromMermaid applies @rule meta` | `rules.order.fields` presente tras parse |
| 13 | `FromMermaid applies @handler override` | `handlers.rechazar.executor == 'Approve@PizzaService'` |
| 14 | `FromMermaid defaults container to <name>/handlers` | sin `@container` → `pizzeria/handlers` |
| 15 | `FromMermaid defaults executor to PascalCase` | nodo `cocinar_rapido` → executor `CocinarRapido` |
| 16 | `FromMermaid applies @manual` | `actions.cocinar_normal.manual == .T.` solo si hay `%% @manual` |
| 17 | `FromMermaid strict rejects orphan action` | acción sin arista de salida + strict=.T. → NIL |
| 18 | `FromMermaid non-strict collects warnings` | mismo caso + strict=.F. → oProc:aWarnings tiene 1 entrada |
| 19 | `FromMermaid rejects dotted edge from non-state` | arista `-.->` desde acción → NIL (strict) |
| 20 | `Round-trip ToMermaid → FromMermaid preserves graph` | `invoice_simple:ToMermaid():FromMermaid()` → `ToHash()` igual al original |
| 21 | `Round-trip pizza.mermaid stays stable` | `cText → FromMermaid → ToMermaid → FromMermaid` produce mismo `ToHash` |
| 22 | `End-to-end: parse pizza, run instance` | `FromMermaid(pizza) → Run('order', {cliente: 'Juan', con_pina: 'no', por_vip: 'si'}) → state == 'listo'` |

---

## 7. Orden de ejecución

**Prerequisito**: fase 1 cerrada y verde en `/test?name=all`.

1. **ToMermaid primero** (fase 2.1):
   1. `ToMermaid` + funciones `Emit*` en `ProcessDefinition.prg`.
   2. Checks 1-8 verdes.
   3. Controller `to_mermaid.prg` + ruta.
   4. Smoke manual: `curl /process/to-mermaid?name=invoice_simple` → copiar output a un fichero `.mermaid`, abrir en VS Code Mermaid preview para validación visual.
2. **Handlers de pizzería** (prereq de los tests end-to-end):
   1. Crear `www/controllers/pizzeria/handlers.prg` con `ConPina`, `PorVip`, `Rechazar`, `CocinarRapido`, `CocinarNormal`.
3. **FromMermaid** (fase 2.2):
   1. Tokenizer + builder + projector como 3 funciones privadas en un fichero nuevo `www/controllers/core/MermaidParser.prg`.
   2. Checks 9-19 verdes (sin round-trip aún).
   3. Round-trip (checks 20-21).
   4. End-to-end (check 22).
4. **Controller + ruta** `from_mermaid.prg`.
5. Correr `/test?name=all` final.

---

## 8. Riesgos y mitigación

- **Regex de aristas frágil** con labels que contienen pipes o paréntesis: en v1, documentar restricción (labels sin `|`, `[`, `]`, `{`, `}`, `(`, `)`). Si surge, cambiar a parser line-by-line por carácter.
- **Variantes de `-.-`, `==>`, `-->`**: en v1 solo soportamos `-->` (sólida) y `-.->` (punteada). Resto → warning "sintaxis no soportada".
- **Mermaid "válido" pero inejecutable** (ej. nodo sin shape, dos aristas con mismo label desde decisión): se resuelve en `strict` o se emite warning. Cubierto por checks 17-18.
- **Case sensitivity**: Mermaid distingue `nuevo` de `Nuevo`. En `bpm/v1` ya hay `Canon()` que normaliza a `lower+alltrim`. El parser debe aplicar `Canon()` a los ids antes de pegar en el hash. Riesgo: perder nodos "A" y "a" como entidades distintas, pero eso es consistente con el resto del motor.
- **Pérdida de información en round-trip**: labels decorativos de aristas punteadas (`SetDecision: ...`) se descartan. Es correcto — el label de punteada no aporta semántica. Documentar en el comentario de `ToMermaid`.
- **Reglas con sintaxis `<br/>regla:` embebida en edge**: parser debe partir label por `<br/>`, inspeccionar sufijos. Fragiliza el regex. **Decisión**: en v1 soportar **solo** `%% @rule`; marcar `<br/>regla:` como deprecado y migrar `pizza.mermaid` al estilo canónico antes de los tests.

---

## 9. Fuera de alcance (plan futuro)

- Shapes extendidos: hexágono (`{{x}}`), paralelogramo (`[/x/]`), subrutina (`[[x]]`) — útiles para subprocesos y eventos de borde (requieren extender `bpm/v1`).
- Gateways paralelos (`AND-split` / `AND-join`): necesita diamond con sintaxis especial (`{{par}}` o anotación `@parallel`).
- Edición bidireccional en editor Mermaid live (watcher que recarga el proceso al guardar).
- Export a BPMN XML (vía intermedio `bpm/v1`).
- Labels como descripciones humanas (`nuevo([Nueva orden])` → `states[nuevo].label = 'Nueva orden'`). Requiere extender el schema.
- Soporte Mermaid LR/RL/BT (ahora solo TD).

---

## 10. Diff estimado

| Fichero | Líneas |
|---|---|
| `ProcessDefinition.prg` (ToMermaid + helpers) | +150 |
| `MermaidParser.prg` (nuevo, tokenizer+builder+projector) | ~250 |
| `pizzeria/handlers.prg` (nuevo) | ~40 |
| `to_mermaid.prg` + `from_mermaid.prg` (controllers nuevos) | ~40 |
| `web.json` | +2 entradas |
| `test.prg` (suite mermaid) | +180 |
| Migración de `pizza.mermaid` a estilo canónico (`%% @rule`) | -2/+3 |

Total: ~660 líneas nuevas, ~5 modificadas.

---

## 11. Decisión por confirmar antes de implementar

1. **¿Aceptar `<br/>regla:` embebido en labels de aristas?** Recomendación: no — forzar `%% @rule` y migrar `pizza.mermaid`.
2. **¿`strict` por defecto?** Recomendación: no — el parser debe ser indulgente por defecto para que un diseñador itere; el consumidor del API puede pedir `strict=true` cuando quiera cerrar.
3. **¿Rechazar labels de arista fuera de `yes/no` en decisiones?** Recomendación: warning en v1, error en v2 cuando se añadan decisiones multi-rama.
4. **¿Nombre del parser (`MermaidParser` vs. `FromMermaid` como class method puro)?** Recomendación: fichero separado `MermaidParser.prg` para no inflar `ProcessDefinition.prg`; expone una única función pública `MermaidToHash(cText, hOpts) → hash bpm/v1`, y `ProcessDefinition:FromMermaid()` es un wrapper de 3 líneas.
