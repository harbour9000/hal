# Plan — Serialización del grafo de `ProcessDefinition`

**Fecha**: 2026-10-17 11:21 (rev 2)
**Proyecto**: `C:\hix.hal`
**Alcance**: añadir volcado/carga JSON del grafo (nivel 1 + reglas + referencias a handlers) de un `ProcessDefinition`, con resolución de handlers por **container + executor** usando el patrón que el dispatcher de HIX ya aplica a las rutas.

> **Cambio respecto a rev 1**: en lugar de un *registro global* poblado por un *loader* al arrancar, los handlers se referencian **declarativamente** en el JSON (`{ container, executor }`) y se resuelven **al invocarlos** reusando `_HixRunHrbClass` / `hb_hrbGetFunSym`. Esto elimina state global y alinea el BPM con el mecanismo que HIX ya domina para rutas.

---

## 1. Hipótesis

El `ProcessDefinition` ya es un grafo cerrado en memoria (7 campos: `cName`, `aStates`, `hTransitions`, `hDecisions`, `hActions`, `hStateDecision`, `hRules`) más un diccionario de code blocks (`hHandlers`). Los 7 primeros son **texto puro** — serializables directamente.

El `hHandlers` es el único no-serializable: son code blocks anónimos. Pero **no necesitan viajar**. Lo que viaja es la **referencia** al código que los implementa: `{ container, executor }`. El código real sigue viviendo en Harbour (`www/controllers/invoice/handlers.prg`) y HIX lo compila/invoca bajo demanda — el mismo truco que ya usa para rutas.

Por tanto:

1. **Serializar** = volcar los 7 campos + un hash `handlers` con las referencias. Zero cambios en `BpmEngine`.
2. **Deserializar** = reconstruir el `ProcessDefinition` desde el JSON. Los handlers se enganchan como code blocks que, al ejecutarse, delegan en un helper que resuelve `container+executor` a tiempo real.
3. **Ejecutar** = el motor llama al code block como siempre. Internamente, el block llama a `HAL_InvokeHandler(cContainer, cExecutor, xArgs)` que compila el HRB y despacha a la función o al método de clase.

---

## 2. Qué cambia / qué NO cambia

### Cambia (ficheros tocados o nuevos)

**Core**

- `www/controllers/core/ProcessDefinition.prg` — añadir 5 métodos (`ToHash`, `ToJson`, `FromHash`, `FromJson`, `Describe`) y nuevos campos para almacenar las referencias (ver §4).

**Resolución de handlers (nuevo)**

- `www/loaders/01_bpm_invoke.prg` — nuevo loader. Contiene **una sola función pública** `HAL_InvokeHandler( cContainer, cExecutor, xArgs )` que encapsula compilar HRB + ejecutar función plana o método de clase.

**Handlers del proceso de ejemplo (nuevo)**

- `www/controllers/invoice/handlers.prg` — nuevo. Funciones públicas `Complete`, `CheckAmount`, `NotifySupplier`, `AutoApprove` + clase `InvoiceService` con método `Approve` (demo de la variante `metodo@clase`).

**Proceso de ejemplo (migrado)**

- `www/controllers/invoice_simple.prg` — la fábrica `SimpleInvoiceProcess()` deja de declarar code blocks inline. Para cada handler, llama a un nuevo método `oProc:AddHandler( cName, cContainer, cExecutor )` que registra la referencia **y** engancha un code block puente.

**Rutas e introspección**

- `www/routes/web.json` — añadir `GET /describe`.
- `www/controllers/describe.prg` — nuevo. Devuelve el `ToHash()` de un proceso conocido.

**Tests**

- `www/controllers/test.prg` — añadir suite `serialization` + registro en `aSuites`.

### NO cambia

- `www/controllers/core/BpmEngine.prg` — no se toca. Sigue viendo code blocks como siempre.
- Ningún test existente.
- La API pública de `oProc:SetHandler(cName, bBlock)` sigue existiendo para quien quiera usarla directamente con un code block (compatibilidad hacia atrás).

---

## 3. Diseño del formato JSON (schema `bpm/v1`)

Para `SimpleInvoiceProcess()`, el volcado será:

```json
{
  "schema":  "bpm/v1",
  "name":    "invoice_simple",
  "states":  ["received", "approved", "returned"],
  "transitions": {
    "receive": { "state": "received" }
  },
  "decisions": {
    "complete":     { "no": "notify_supplier", "yes": "check_amount" },
    "check_amount": { "yes": "auto_approve",   "no":  "manual_approve" }
  },
  "actions": {
    "notify_supplier": { "state": "returned", "manual": false },
    "auto_approve":    { "state": "approved", "manual": false },
    "manual_approve":  { "state": "approved", "manual": true  }
  },
  "state_decisions": { "received": "complete" },
  "rules": {
    "receive":        { "fields": ["supplier", "amount"] },
    "manual_approve": { "roles":  ["approver"] }
  },
  "handlers": {
    "complete":        { "container": "invoice/handlers" },
    "check_amount":    { "container": "invoice/handlers" },
    "notify_supplier": { "container": "invoice/handlers" },
    "auto_approve":    { "container": "invoice/handlers" },
    "manual_approve":  { "container": "invoice/handlers", "executor": "Approve@InvoiceService" }
  }
}
```

**Convenciones (confirmadas por el usuario, a/b/c)**:

- `schema` fijo = `"bpm/v1"`. Primera cosa que verifica `FromJson`.
- `container` **relativo a `www/controllers/`**, **sin extensión** (`.prg` lo añade el invoker). Soporta subcarpetas (`invoice/handlers`).
- `executor` opcional. Si no viene → convención: **el ejecutor es el propio nombre del nodo en PascalCase** (`complete` → `Complete`, `check_amount` → `CheckAmount`). Casi nunca necesitas escribirlo.
- `executor` sin `@` → función pública en el `.prg`.
- `executor` con `@` → método de clase: `metodo@Clase`. Se resuelve con el mismo patrón que `_HixRunHrbClass` del dispatcher (ver §5.2).
- Snake_case en claves JSON (`state_decisions`), consistente con convenciones de APIs.

---

## 4. Cambios en `ProcessDefinition.prg`

### 4.1 Campo nuevo

```harbour
VAR hHandlerRefs AS HASH INIT { => }   // cName → { 'container', 'executor' }
```

Convive con `hHandlers` (code blocks). Un handler puede existir **solo** como code block (compat), **solo** como ref (deserializado puro, no ejecutable aún) o **ambos** (deserializado y rehidratado — el block puente llama al invoker).

### 4.2 Método nuevo `AddHandler`

Reemplaza en la práctica a `SetHandler` para flujos declarativos:

```harbour
METHOD AddHandler( cName, cContainer, cExecutor ) CLASS ProcessDefinition
   LOCAL cKey := Canon( cName )
   LOCAL cExe := iif( Empty( cExecutor ), PascalCase( cKey ), cExecutor )

   // Guardar la referencia (lo que serializa)
   ::hHandlerRefs[ cKey ] := { 'container' => cContainer, 'executor' => cExe }

   // Enganchar code block puente que delega en el invoker.
   // El motor sigue viendo "un code block" como siempre.
   ::hHandlers[ cKey ] := {| xArgs | HAL_InvokeHandler( cContainer, cExe, xArgs ) }

RETURN Self
```

`PascalCase()` es una función utilitaria pequeña: `"check_amount"` → `"CheckAmount"`.

### 4.3 API nueva (los 5 métodos de serialización)

```harbour
METHOD ToHash()                        → HASH
METHOD ToJson( lPretty )               → STRING
METHOD Describe()                      → HASH   // ToHash + stats + diagnostics
CLASS METHOD FromHash( hGraph )        → ProcessDefinition
CLASS METHOD FromJson( cJson )         → ProcessDefinition
```

### 4.4 Esqueleto de `ToHash()`

```harbour
METHOD ToHash() CLASS ProcessDefinition
   LOCAL hOut
   hOut := { ;
      'schema'          => 'bpm/v1',                      ;
      'name'            => ::cName,                       ;
      'states'          => AClone( ::aStates ),           ;
      'transitions'     => hb_HClone( ::hTransitions ),   ;
      'decisions'       => hb_HClone( ::hDecisions ),     ;
      'actions'         => hb_HClone( ::hActions ),       ;
      'state_decisions' => hb_HClone( ::hStateDecision ), ;
      'rules'           => hb_HClone( ::hRules ),         ;
      'handlers'        => hb_HClone( ::hHandlerRefs )    ;
   }
RETURN hOut
```

Nota: handlers que se registraron con el viejo `SetHandler(cName, bBlock)` (code block anónimo, sin ref) **no aparecerán** en el `handlers` del JSON — porque no tienen `container+executor`. Eso es correcto: no son serializables.

### 4.5 Esqueleto de `FromHash( hGraph )`

```harbour
METHOD FromHash( hGraph ) CLASS ProcessDefinition
   LOCAL oProc, cName, hRef, hAct, hRuleSet, cRuleType

   IF ! hb_HHasKey( hGraph, 'schema' ) .OR. hGraph[ 'schema' ] != 'bpm/v1'
      RETURN NIL
   ENDIF

   oProc := ::New( hb_HGetDef( hGraph, 'name', '' ) )

   // States, transitions, decisions, actions, state_decisions, rules
   // (idéntico al rev 1 — ver código fuente)

   // Handlers: reconstruir desde refs usando AddHandler, que a su vez
   // engancha el code block puente al invoker.
   FOR EACH cName IN hb_HKeys( hb_HGetDef( hGraph, 'handlers', { => } ) )
      hRef := hGraph[ 'handlers' ][ cName ]
      oProc:AddHandler( cName, ;
                        hRef[ 'container' ], ;
                        hb_HGetDef( hRef, 'executor', NIL ) )
   NEXT

RETURN oProc
```

### 4.6 `FromJson( cJson )`

Trivial: `hb_jsonDecode( cJson, @hGraph )` + delegar en `FromHash`. Si decode falla → `NIL`.

### 4.7 `Describe()`

Sobre `ToHash()` añade bloques de diagnóstico útiles para la IA/MCP:

```json
{
  ...todo lo de ToHash()...,
  "stats": {
    "states_count":    3,
    "actions_count":   3,
    "decisions_count": 2,
    "rules_count":     2,
    "handlers_count":  5
  },
  "diagnostics": {
    "missing_refs":    [],
    "validation":      { "ok": true, "errors": [] }
  }
}
```

---

## 5. `HAL_InvokeHandler` — resolución container+executor

Nuevo fichero `www/loaders/01_bpm_invoke.prg`. Única función pública:

```harbour
FUNCTION HAL_InvokeHandler( cContainer, cExecutor, xArgs )
   LOCAL cPath, nAt, cClass, cMethod, pHRB, pSym, oObj, xRet

   // 1) Resolver path físico
   cPath := 'www/controllers/' + cContainer + '.prg'
   IF ! hb_FileExists( cPath )
      RETURN NIL      // en producción: lanzar error estructurado
   ENDIF

   // 2) Compilar HRB (HIX cachea por md5 del .prg → coste casi cero)
   pHRB := hb_compileFromBuf( hb_memoRead( cPath ), '-n', '-q0', '-w0' )
   IF pHRB == NIL
      RETURN NIL
   ENDIF

   // 3) Despacho: función plana o metodo@clase
   nAt := At( '@', cExecutor )
   IF nAt == 0
      // Función plana
      pSym := hb_hrbGetFunSym( pHRB, cExecutor )
      IF pSym == NIL
         RETURN NIL
      ENDIF
      xRet := hb_hrbDo( pSym, xArgs )
   ELSE
      // Método de clase: Main(cClase) devuelve la clase (convención HIX)
      cMethod := Lower( Left( cExecutor, nAt - 1 ) )
      cClass  := SubStr( cExecutor, nAt + 1 )
      oObj    := hb_hrbDo( pHRB, cClass )    // Main(cClass) → class
      IF ValType( oObj ) != 'O'
         RETURN NIL
      ENDIF
      IF __objHasMethod( oObj, 'NEW' )
         oObj := __objSendMsg( oObj, 'NEW' )
      ENDIF
      IF __objHasMethod( oObj, cMethod )
         xRet := __objSendMsg( oObj, cMethod, xArgs )
      ENDIF
      // Opcional: cleanup END/DESTROY si existen
      IF __objHasMethod( oObj, 'DESTROY' )
         __objSendMsg( oObj, 'DESTROY' )
      ENDIF
   ENDIF

RETURN xRet
```

Notas:

- Se puede delegar directamente en `_HixRunHrbClass` del dispatcher cuando el executor es `metodo@clase`, pero esa función interna no está exportada. Replicar su lógica es ~20 líneas y evita acoplar el BPM al dispatcher como caja negra.
- Para evitar recompilar HRB en cada handler, en una **iteración posterior** se puede añadir un cache `md5(contenido) → pHRB`. En la primera versión, confiamos en que `hb_compileFromBuf` sobre un fichero que no cambia es barato.
- Errores: por ahora `RETURN NIL`. En rev 3 se definirá `{ ok, code, message }` estructurado (parte de "errores estructurados" del roadmap de `pendientes.md`).

---

## 6. Handlers del ejemplo — `www/controllers/invoice/handlers.prg`

```harbour
/*-----------------------------------------------------------
  File ......: handlers.prg
  Project....: HIX HAL — BPM invoice_simple handlers
  Description: Funciones referenciadas desde invoice_simple.json
 -----------------------------------------------------------*/

FUNCTION Complete( hData )
RETURN IIf( ! Empty( hb_HGetDef( hData, 'supplier', '' ) ) .AND. ;
             ! Empty( hb_HGetDef( hData, 'amount',   0  ) ), 'yes', 'no' )

FUNCTION CheckAmount( hData )
RETURN IIf( hb_HGetDef( hData, 'amount', 0 ) < 1000, 'yes', 'no' )

FUNCTION NotifySupplier( hCtx )
   hCtx[ 'data' ][ 'notified' ] := .T.
RETURN NIL

FUNCTION AutoApprove( hCtx )
   hCtx[ 'data' ][ 'approved_by' ] := 'system'
RETURN NIL

// Convención HIX: Main(cClass) devuelve la clase
FUNCTION Main( cClass )
RETURN &( cClass + '()' )

CLASS InvoiceService
   METHOD New()
   METHOD Approve( hCtx )
ENDCLASS

METHOD New() CLASS InvoiceService
RETURN Self

METHOD Approve( hCtx ) CLASS InvoiceService
   hCtx[ 'data' ][ 'approved_by' ] := hCtx[ 'user' ]:cName
RETURN NIL
```

`manual_approve` se declara con `"executor": "Approve@InvoiceService"` **solo para demostrar que la variante clase funciona**. Los otros 4 handlers son funciones planas, que es el caso 90%.

---

## 7. Migración de `invoice_simple.prg`

Dentro de `SimpleInvoiceProcess()`, cada `SetHandler` con code block inline pasa a ser:

```harbour
// Antes
oProc:SetHandler( 'complete', {| hData | ;
   IIf( ! Empty( hb_HGetDef( hData, 'supplier', '' ) ) .AND. ;
        ! Empty( hb_HGetDef( hData, 'amount',   0  ) ), 'yes', 'no' ) } )

// Después
oProc:AddHandler( 'complete', 'invoice/handlers' )     // executor = 'Complete' por convención
```

Y para `manual_approve` con la variante método-clase:

```harbour
oProc:AddHandler( 'manual_approve', 'invoice/handlers', 'Approve@InvoiceService' )
```

Resultado: `invoice_simple.prg` se queda **más corto** y **100% serializable** por `ToJson()`.

---

## 8. Suite nueva en `test.prg` — `serialization`

| # | Nombre | Qué comprueba |
|---|--------|---------------|
| 1 | `ToHash contains schema v1` | `hGraph['schema'] == 'bpm/v1'` |
| 2 | `ToHash preserves states` | `aStates` idéntico |
| 3 | `ToHash preserves transitions` | key `receive` apunta a `received` |
| 4 | `ToHash preserves decisions` | `complete.yes == check_amount` |
| 5 | `ToHash preserves actions` | `manual_approve.manual == .T.` |
| 6 | `ToHash preserves rules` | `receive.fields` tiene `supplier` y `amount` |
| 7 | `ToHash preserves handler refs` | `complete` → `{container: invoice/handlers}` |
| 8 | `ToHash preserves executor override` | `manual_approve.executor == 'Approve@InvoiceService'` |
| 9 | `ToJson is valid JSON` | `hb_jsonDecode` acepta el output |
| 10 | `Round-trip ToJson → FromJson` | mismo `ToHash()` tras round-trip |
| 11 | `FromJson rejects wrong schema` | `"schema": "bpm/v99"` → NIL |
| 12 | `FromJson rejects malformed JSON` | `"{{{"` → NIL |
| 13 | `HAL_InvokeHandler function plain` | `HAL_InvokeHandler('invoice/handlers', 'CheckAmount', {'amount'=>500}) == 'yes'` |
| 14 | `HAL_InvokeHandler function with underscore name` | `CheckAmount` resuelve bien desde `check_amount` |
| 15 | `HAL_InvokeHandler method@class` | `HAL_InvokeHandler('invoice/handlers', 'Approve@InvoiceService', hCtx)` escribe `approved_by` |
| 16 | `HAL_InvokeHandler unknown container` | path inexistente → NIL (no explota) |
| 17 | `HAL_InvokeHandler unknown executor` | función inexistente → NIL (no explota) |
| 18 | `Reconstructed proc runs end-to-end` | ToJson → FromJson → `Run()` ejecuta `receive` con amount<1000 y aterriza en `approved` |

---

## 9. Ruta `/describe` para introspección MCP

Añadir en `www/routes/web.json`:

```json
{ "name": "describe", "url": "/describe", "action": "controllers/describe.prg", "method": "GET" }
```

Controller `www/controllers/describe.prg`:

```harbour
FUNCTION Main()
   LOCAL cName := UGet( 'name', '' )
   LOCAL oProc

   DO CASE
   CASE cName == 'invoice_simple'
      oProc := SimpleInvoiceProcess()
      USendJson( oProc:Describe() )
   OTHERWISE
      USendError( 404, 'unknown process: ' + cName )
   ENDCASE

RETURN NIL
```

El `DO CASE` desaparecerá cuando exista un registro de procesos (fuera de alcance de este plan).

---

## 10. Orden de ejecución (cuando empiece la implementación)

1. Crear `www/controllers/invoice/handlers.prg` con las 5 funciones + clase.
2. Crear `www/loaders/01_bpm_invoke.prg` con `HAL_InvokeHandler`.
3. Escribir y pasar checks 13-17 (invoker aislado, sin tocar aún `ProcessDefinition`).
4. En `ProcessDefinition.prg`: añadir `VAR hHandlerRefs`, método `AddHandler`, método `ToHash`. Checks 1-8 verdes.
5. Añadir `ToJson()`. Check 9 verde.
6. Añadir `FromHash` / `FromJson`. Checks 10-12 verdes.
7. Migrar `invoice_simple.prg` a `AddHandler`. Verificar que `/test?name=all` sigue verde (las suites existentes **no** deben romper).
8. Añadir check 18 (end-to-end round-trip + Run).
9. Añadir `Describe()`, controller `describe.prg`, ruta `/describe`. Verificar `curl http://localhost:4322/describe?name=invoice_simple`.
10. Correr `/test?name=all` final.

---

## 11. Riesgos y mitigación

- **Recompilar HRB en cada handler**: en frío puede ser ~5-20 ms por `.prg`. Para procesos cortos (3-5 handlers) es asumible. Si pesa en benchmarks, cachear `pHRB` por path (md5 del contenido como key).
- **Orden no determinista de claves en hashes**: el check 10 (round-trip) debe comparar **hashes decodificados**, no cadenas JSON textuales.
- **`PascalCase()` ambiguo con nombres raros**: `__weird__` → `WEIRD`. Para evitar sorpresas, cuando el nombre tiene caracteres raros, el usuario debe especificar `executor` explícito. Documentar en el comentario de `AddHandler`.
- **Un handler con solo code block (`SetHandler`) no se serializa**: comportamiento correcto, pero conviene reflejarlo en `Describe().diagnostics` (`handlers_without_refs: [...]`) para que la IA sepa que ese proceso **no es exportable al 100%**.
- **Seguridad**: `HAL_InvokeHandler` compila cualquier `.prg` que exista bajo `www/controllers/`. Hoy es el mismo riesgo que las rutas HIX. No añade superficie nueva.

---

## 12. Fuera de alcance (siguiente plan)

- Cache de HRB compilado por md5.
- Registro de procesos (`BpmRegistry`) para que `describe.prg` no tenga `DO CASE`.
- Carga de procesos desde ficheros `.json` en disco (`www/processes/*.json`), sin pasar por `SimpleInvoiceProcess()`.
- Export a Mermaid/Graphviz/BPMN.
- Errores estructurados en `HAL_InvokeHandler` (`{ ok, code, message, context }`).
- Serialización de **instancias vivas** del motor (persistencia).

---

## 13. Diff estimado

| Fichero | Líneas |
|---|---|
| `ProcessDefinition.prg` | +130 (5 métodos + AddHandler + VAR + PascalCase) |
| `01_bpm_invoke.prg` (nuevo) | ~70 |
| `invoice/handlers.prg` (nuevo) | ~50 |
| `invoice_simple.prg` (migración) | -20 / +5 (más corto) |
| `test.prg` | +120 (suite de 18 checks) |
| `describe.prg` (nuevo) | ~15 |
| `web.json` | +1 entrada |

Total: ~370 líneas nuevas, ~20 modificadas en código existente.
