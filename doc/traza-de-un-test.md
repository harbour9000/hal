# HIX HAL — Qué pasa, línea a línea, cuando corre un test

> Elijo **el camino B del test `invoice_simple`** (factura completa de
> 2400 €) porque toca todas las piezas del motor:
> validación de entrada, reglas de nivel 2, creación de instancia,
> cascada de rombos encadenados, acción manual que aparca la instancia,
> segundo `Run` con control de rol, handler que escribe en los datos,
> historial. Si entiendes este, entiendes el resto.
>
> Cada paso cita el **fichero y la línea** del código que se ejecuta,
> para que puedas leerlo en paralelo.

---

## 0. Antes de que llegue la petición: el *bootstrap*

Al arrancar `hix.exe`:

1. HIX lee `hix.json` (puerto 4322, pools, logs...).
2. Entra en `www/loaders/` y **compila todo lo que encuentra una sola
   vez**, en memoria global. Aquí vive `00_bpm_core.prg`
   (`www/loaders/00_bpm_core.prg`), que no tiene lógica propia: solo
   hace `#INCLUDE` de tres ficheros, con lo que las clases
   `ProcessDefinition` y `BpmEngine` y la función
   `SimpleInvoiceProcess()` quedan disponibles para cualquier
   controlador.
3. Levanta el servidor HTTP y queda esperando conexiones.

**Importante**: `www/loaders/` se compila una vez. `www/controllers/`
se recompila **en cada petición** (HRB fresco). Esto marca el resto.

---

## 1. Llega la petición: `GET /test?name=all`

- El JS de `views/main.html:149` hace `fetch('/test?name=all')` al
  pulsar el botón.
- HIX mira `www/routes/web.json` y encuentra:
  `{ "name": "test", "url": "/test", "action": "controllers/test.prg" }`.
- Compila `test.prg` en un HRB fresco, lo carga, y **ejecuta el primer
  símbolo público**: `FUNCTION Main` (`test.prg:35`).
- `UGet('name', 'invoice_simple')` lee el query-param `?name=all`.
- Entra en `CASE cName == 'all'` (`test.prg:55-59`) y mete en `aSuites`
  las tres funciones:

```harbour
AAdd( aSuites, TestBpm_Definition() )
AAdd( aSuites, TestBpm_Engine() )
AAdd( aSuites, TestBpm_InvoiceSimple() )   ← la que trazamos
```

Nos quedamos con la última. Hacemos **zoom al camino B** dentro de
`TestBpm_InvoiceSimple` (`test.prg:165-276`).

---

## 2. Preparar el usuario y el motor

```harbour
oProc := SimpleInvoiceProcess()                            // test.prg:175
oEng  := BpmEngine():New()                                 // test.prg:176
uIn   := BpmTestUser():New( 'recepcion',   { 'clerk'    } )
uAp   := BpmTestUser():New( 'supervisora', { 'approver' } ) // test.prg:177-178
```

**Qué es un "usuario" para el motor** (`BpmEngine.prg:68-74`):

> Cualquier objeto que exponga `cName` (string) y `aRoles` (array).
> **Ni más ni menos**. El motor no sabe nada de autenticación.

`BpmTestUser` (`test.prg:94-108`) es un objeto *mínimo* con esos dos
atributos. En producción, el "usuario" podría ser una fila de BBDD,
un objeto de sesión, un stub de IA. El motor no se entera.

**Qué es el motor** (`BpmEngine.prg:21`):

```harbour
VAR hInstances AS HASH INIT { => }   // clave 'proceso|id' → instancia
```

Un `BpmEngine` recién creado solo tiene un hash vacío de instancias.
No tiene estado propio. Dos motores distintos no comparten instancias.

---

## 3. Construir el proceso (la "fábrica")

`SimpleInvoiceProcess()` vive en `www/controllers/invoice_simple.prg`.
Es una función de un solo retorno que ensambla el `ProcessDefinition`:

| línea | llamada                                            | efecto                                                 |
|-------|----------------------------------------------------|--------------------------------------------------------|
| 24    | `ProcessDefinition():New('invoice_simple')`        | nombre canónico, hashes vacíos                         |
| 28-30 | `AddState('received'/'approved'/'returned')`       | tres "fins"                                            |
| 34    | `AddTransition('receive','received')`              | acción inicial                                         |
| 38-44 | `AddDecision('complete',...) / 'check_amount'`     | los dos rombos                                         |
| 49-51 | `AddAction(...)` (auto y manual)                   | tres acciones; `manual_approve` con `.T.`              |
| 55    | `SetDecision('received','complete')`               | al caer en `received`, evalúa `complete`               |
| 59-75 | `SetHandler(...)`                                  | 2 handlers de rombo + 3 handlers de acción             |
| 80-81 | `AddRule('receive','fields',...)` + `roles`        | reglas de nivel 2                                      |

Cada método modifica un hash de `oProc`. **Canonicalización**
(`ProcessDefinition.prg:54`): `Canon()` baja a minúsculas y hace
`AllTrim`. Por eso `'Receive'`, `'RECEIVE'` y `' receive '` acaban
siendo la misma clave en los hashes.

**Pro de este diseño**: la fábrica es *declarativa*. El dibujo se lee
de arriba abajo como el diagrama. No hay orden obligatorio entre
`AddState` y `AddTransition`: `Validate()` se encarga después.

**Contra**: el *cableado* (`SetDecision`) es implícito. Si olvidas
`SetDecision('received','complete')`, el proceso valida sin errores
pero la cascada nunca arranca. `Validate()` no detecta "estados sin
rombo cableado" (porque no todos los estados tienen por qué tenerlo).

---

## 4. **Primer `Run`**: `receive` con FAC-B, 2400 €

```harbour
hRes := oEng:Run( oProc, uIn, 'receive',
   { 'id' => 'FAC-B', 'supplier' => 'Papelera Sur', 'amount' => 2400 } )
```

Entramos en `BpmEngine:Run` (`BpmEngine.prg:40`). Paso a paso:

### 4.1 Canonicalizar el nombre de la acción

```harbour
cName := Lower( AllTrim( hb_defaultValue( cAction, '' ) ) )   // :42
```

`'receive'` → `'receive'`. Si el usuario mandara `'Receive '`
también acabaría aquí. **Pro**: tolerante al case. **Contra**: no es
una canonicalización *simétrica* con la de `ProcessDefinition:Canon`,
son dos funciones distintas con el mismo comportamiento — podría
caerse si una se cambia y la otra no.

### 4.2 Preparar el resultado

```harbour
hRes := { 'ok' => .T., 'error' => '', 'id' => '', 'state' => '',
          'pending' => '', 'executed' => {}, 'history' => {} }  // :43
```

El motor **siempre devuelve un hash con la misma forma**. Nunca lanza
excepciones hacia arriba. Esto es muy agradable para un consumidor
(incluido un LLM).

### 4.3 Validar que `oProcess` es un `ProcessDefinition`

```harbour
IF ValType( oProcess ) != 'O' .OR. ! __ObjHasMsg( oProcess, 'VALIDATE' )
   // :48-55
```

**Duck typing**: no se exige la clase concreta, solo que tenga el
método `Validate`. **Pro**: deja la puerta abierta a un `MockProcess`
en tests. **Contra**: un objeto con `Validate` pero semántica distinta
rompería más adelante.

### 4.4 `Validate()` del proceso

```harbour
hValid := oProcess:Validate()    // :57  → ProcessDefinition.prg:157
```

`Validate()` recorre `hTransitions`, `hActions`, `hDecisions`,
`hStateDecision` y `hRules` comprobando que **todo apunte a algo
definido**. Es la integridad referencial. Devuelve
`{ ok, errors[] }`. Para `invoice_simple` sale `ok=.T.`.

> **Pro clave**: el motor valida *en cada `Run`*. Jamás ejecuta un
> proceso roto. El coste es pequeño (es un recorrido de hashes).
>
> **Contra**: si un día el proceso se construye muchísimas veces por
> segundo, es trabajo redundante. Fácil de cachear (`oProc:lValidated`),
> pero hoy no está hecho.

### 4.5 Validar el usuario

```harbour
IF ValType( oUser ) != 'O' .OR. ! __ObjHasMsg( oUser, 'CNAME' )
                            .OR. ! __ObjHasMsg( oUser, 'AROLES' )
   // :68-75
```

Mismo duck typing. `uIn` cumple → sigue.

### 4.6 Comprobar que `hData` trae `id`

```harbour
cId := hb_HGetDef( hData, 'id', '' )   // :79
IF Empty( cId )                        // :81
```

`'FAC-B'` → sigue. `cKey := 'invoice_simple|FAC-B'` (`:90`).

### 4.7 ¿Transición, acción manual, o desconocido?

```harbour
DO CASE
CASE oProcess:IsTransition( cName )   // :95 → ProcessDefinition.prg:256
```

`'receive'` **es** una transición → entramos a la rama "crear".

### 4.8 Comprobar que la instancia no existe aún

```harbour
IF hb_HHasKey( ::hInstances, cKey )   // :99
```

No existe → sigue. (Si existiera: `instance already exists`).

### 4.9 Aplicar las **reglas de nivel 2** sobre `receive`

```harbour
hRule := ::CheckRules( oProcess, cName, oUser, hData )   // :108
                      → BpmEngine.prg:281
```

Dentro de `CheckRules`:

- `oProcess:hRules['receive']` existe (`fields: { supplier, amount }`).
- No hay regla `roles` para `receive` → se salta ese bloque.
- Entra en el bloque `fields` (`:327-342`) y pide que
  `hb_HGetDef(hData, 'supplier')` y `hb_HGetDef(hData, 'amount')`
  no sean `Empty`. Las dos existen y tienen valor → **ok**.
- No hay regla `limit` → se salta.

**Pro**: las reglas son 3 tipos muy concretos (`roles`, `fields`,
`limit`) y están bien contenidas. Añadir una cuarta regla ("regex en
un campo", por ejemplo) es trivial.

**Contra**: `fields` solo detecta "vacío", no "tipo correcto" ni
"patrón". Y `limit` solo mira máximo, no mínimo ni rango. Es suelo,
no techo.

### 4.10 Crear la instancia

```harbour
hInst := { 'id' => cId, 'process' => oProcess:cName, 'state' => '',
           'data' => hData, 'pending' => '', 'history' => {} }   // :117
hInst[ 'state' ] := oProcess:hTransitions[ cName ][ 'state' ]
                                                                 // :120 → 'received'
::hInstances[ cKey ] := hInst                                     // :121
::Log( hInst, oUser:cName, cName, '', hInst[ 'state' ] )          // :122
```

El estado inicial es **el destino de la transición** (`'received'`).
`::Log` (`BpmEngine.prg:364`) añade `{ ts, user: 'recepcion',
action: 'receive', from: '', to: 'received' }` al historial.

**Pro**: `hInst['data']` apunta al **mismo hash** que `hData`. El
handler verá — y podrá escribir — los datos vivos. No hay copia.

**Contra**: ese aliasing es útil pero sutil. Si el llamante mantiene
una referencia al `hData` y lo modifica fuera del motor, también
cambia la instancia. En este proyecto no pasa, pero es una trampa
latente.

### 4.11 Entra la cascada: `::Cascade(oProcess, hInst, hRes)`

Línea `:181`. Vamos a `BpmEngine.prg:191`.

```harbour
DO WHILE hb_HHasKey( oProcess:hStateDecision, hInst[ 'state' ] )  // :198
```

El estado actual es `'received'` y **sí** tiene un rombo cableado
(`complete`). Entra. Incremento de `nSteps` (anti-bucles, `:200`).

```harbour
cDecision := oProcess:hStateDecision[ hInst[ 'state' ] ]   // :209 → 'complete'
```

Ahora el bucle interno (`:213`), que **resuelve la cadena de rombos**
hasta aterrizar en una acción:

**Iteración 1**: `cDecision = 'complete'`.
- `hBranch := oProcess:hDecisions['complete']`  → `{ no: notify_supplier, yes: check_amount }`
- Ejecuta el **handler del rombo** (`:228`):
  ```harbour
  cLabel := Eval( oProcess:hHandlers['complete'], hInst['data'] )
  ```
  El handler es (`invoice_simple.prg:59-61`):
  ```harbour
  {| hData | IIf( ! Empty(supplier) .AND. ! Empty(amount), 'yes', 'no' ) }
  ```
  → `'yes'`.
- `cTarget := hBranch['yes']` → `'check_amount'`.
- `oProcess:IsDecision('check_amount')` → **sí**: encadena otro rombo,
  `cDecision := 'check_amount'` y `LOOP`.

**Iteración 2**: `cDecision = 'check_amount'`.
- Handler (`invoice_simple.prg:63-64`): `amount=2400 < 1000` → **falso**
  → devuelve `'no'`.
- `cTarget := hBranch['no']` → `'manual_approve'`.
- `IsDecision('manual_approve')` → **no**, es acción → `EXIT`.

Salimos del bucle interno. Fuera (`:252`):

```harbour
hDef := oProcess:hActions[ 'manual_approve' ]   // { state: 'approved', manual: .T. }
```

### 4.12 La acción es **manual** → aparcamos la instancia

```harbour
IF hDef[ 'manual' ]                                      // :256
   hInst[ 'pending' ] := cTarget                         // 'manual_approve'
   ::Log( hInst, 'system', 'route', hInst['state'], 'wait manual_approve' )
   AAdd( hRes[ 'executed' ], cTarget + ' (pending)' )
   RETURN hRes                                           // :262
ENDIF
```

**Clave de todo el motor**: cuando aterriza en una acción manual, no
la ejecuta. **Aparca** y devuelve. El estado de la instancia **sigue
siendo `'received'`** (no se mueve) pero ahora lleva una `pending`.
El historial anota el enrutado (`route → wait manual_approve`).

Volvemos a `Run` (`:181`), que ya solo rellena las claves de salida:

```harbour
hRes[ 'id' ]      := 'FAC-B'
hRes[ 'state' ]   := 'received'
hRes[ 'pending' ] := 'manual_approve'
hRes[ 'history' ] := hInst[ 'history' ]
```

El test lo verifica (`test.prg:213-216`):

```harbour
TCheck( hRes['state']   == 'received'       , 'B: waits in received' )
TCheck( hRes['pending'] == 'manual_approve' , 'B: manual approval pending' )
```

**Pro**: la "espera" no cuesta nada. No hay timers, no hay colas.
La instancia simplemente queda con un `pending` y nadie la toca
hasta la próxima llamada.

**Contra**: en memoria. Reinicia el servidor y la factura FAC-B
desaparece. Para producción haría falta serializar `hInstances`.

---

## 5. **Segundo `Run`**: `manual_approve` con el usuario equivocado

Esto no está en el test de `invoice_simple`, pero sí en
`TestBpm_Engine` (`test.prg:323-329`). Lo trazamos porque enseña
`CheckRules` con `roles`.

```harbour
hRes := oEng:Run( oProc, uAna, 'manual_approve', { 'id' => 'F-2' } )
```

(`uAna` es `clerk`, no `approver`).

Entramos en `Run` (`BpmEngine.prg:40`). Validaciones de proceso y
usuario OK. `cKey = 'invoice_simple|F-2'`. `IsTransition('manual_approve')`
→ **no**. `IsAction('manual_approve')` → **sí** (`:124`).

```harbour
IF ! hb_HHasKey( ::hInstances, cKey )   // :128 → instancia existe, sigue
hInst := ::hInstances[ cKey ]            // :137
IF hInst[ 'pending' ] != cName           // :139 → sí es la pendiente, sigue
```

Y entra en `CheckRules` (`:148`). Esta vez sí hay `hRules['manual_approve']`:

```harbour
hRules['roles'] := { 'approver' }                      // regla cargada
```

El bucle de roles (`BpmEngine.prg:300-312`) compara **cada rol del
usuario con cada rol permitido**:

- `uAna:aRoles = { 'clerk' }` vs `{ 'approver' }` → ningún match.
- `lAllowed` queda `.F.` → `hRes[ 'error' ] := 'role not allowed for manual_approve'`.
- `RETURN hRule`.

El motor **no toca la instancia**. Perfecto: puedes reintentar.

**Pro**: `roles` como *lista blanca* es simple y suficiente.

**Contra**:
- Es doble `FOR` (`O(n·m)`). Da igual con 3 roles, pero conviene saberlo.
- No hay negativos (`"cualquiera menos admin"`), no hay AND
  (`"approver AND finance"`). Si lo necesitas, hay que extender
  `CheckRules`.

---

## 6. **Tercer `Run`**: `manual_approve` con `uAp` (`approver`)

```harbour
hRes := oEng:Run( oProc, uAp, 'manual_approve', { 'id' => 'FAC-B' } )
```

Pasa los filtros (es una acción, instancia existe, pending coincide,
roles OK). Entra en el bloque de acciones (`BpmEngine.prg:155-168`):

```harbour
hb_HMerge( hInst[ 'data' ], hData )   // :159
```

**Fusión de datos**. `hData` solo trae `{id: FAC-B}`, así que no
añade nada nuevo. Pero si el consumidor hubiera mandado
`{id: FAC-B, comment: 'OK con reservas'}`, ese `comment` se quedaría
pegado a la instancia **para siempre**.

```harbour
hDef := oProcess:hActions[ 'manual_approve' ]   // { state: 'approved', manual: .T. }
hCtx := { 'id' => 'FAC-B', 'data' => hInst['data'], 'user' => uAp, 'state' => 'received' }
Eval( oProcess:hHandlers[ 'manual_approve' ], hCtx )   // :164
```

El handler es (`invoice_simple.prg:74-75`):

```harbour
{| hCtx | hCtx['data']['approved_by'] := hCtx['user']:cName }
```

Escribe `approved_by = 'supervisora'` en los datos vivos de la
instancia. Devuelve `NIL` (no importa).

```harbour
hInst[ 'pending' ] := ''                                    // :166
::Log( hInst, 'supervisora', 'manual_approve',
       'received', 'approved' )                             // :167
hInst[ 'state' ] := 'approved'                              // :168
```

Fin del bloque. Vuelve a la cascada (`:181`), pero ahora el estado es
`'approved'` y no tiene rombo cableado (`hStateDecision` no lo tiene).
Sale del `DO WHILE` inmediatamente. Devuelve `hRes` con `state:
approved`, `pending: ''`, `history: [...]` de 3 líneas.

**Pro de la secuencia**: el handler no sabe nada del motor. Recibe
un contexto, hace su trabajo (anotar quién firmó). Testear un handler
suelto es trivial: `Eval( bHandler, { data: {...}, user: ... } )`.

**Contra**: el handler no puede *fallar*. Si lanza una excepción,
sube hasta el `TRY/CATCH` de la suite y se contabiliza como `FAIL`,
pero el motor **no** rebobina el cambio de estado si el handler
peta a mitad. Hoy no es un problema (los handlers son triviales).
En cuanto hagan I/O (BBDD, HTTP) habrá que decidir qué pasa con el
estado si el handler explota.

---

## 7. Lo que ve la UI

El controlador de `/test` acaba haciendo:

```harbour
RETURN USendJson( hRes )                               // test.prg:90
```

Donde `hRes` lleva `lines[]`, cada una con un `kind` (`sys`, `user`,
`ok`, `err`, `how`, `suite`) y un `text`. El JS de `main.html:152-157`
simplemente itera y pinta cada línea con la clase CSS
correspondiente (`<style>` en `main.html:28-46`). El veredicto final
es una banda verde (`TEST PASS`) o roja (`TEST FAIL`).

**Pro**: la narrativa está **dentro del test**, no en el JS. El JS
es pintor tonto. Cambiar el texto de un `PASS` solo requiere tocar
el `TCheck(..., cWhy)` correspondiente en `test.prg`.

**Contra**: no hay streaming. Si una suite tarda 10 s, no verás nada
hasta que acabe. Para 60 checks rápidos no importa; para una suite
que haga I/O real sí.

---

## 8. Diseño general: pros y contras

### Lo bueno

1. **Separación "qué" / "cómo".** `ProcessDefinition` solo describe;
   `BpmEngine` solo ejecuta. Son testeables por separado.
2. **Un único punto de entrada** (`Run`). Hace el motor fácil de
   razonar y de exponer (vía HTTP, MCP, lo que sea).
3. **Fail-closed**: todas las entradas pasan por `Validate` y
   `CheckRules`. Un proceso roto no se ejecuta jamás.
4. **Errores legibles**. `'role not allowed for manual_approve'`,
   `'limit exceeded on amount'`, `'unknown branch maybe'`. Perfecto
   para un consumidor humano o IA.
5. **Freno anti-bucles** (`MAX_STEPS = 100`). Dos rombos que se
   apuntan no cuelgan el servidor.
6. **Historial dentro de la instancia**. Cada movimiento deja huella
   sin que el handler tenga que preocuparse.
7. **`THREAD STATIC`** en los acumuladores del test. Prevención
   proactiva de un bug de concurrencia que *todavía no existe*
   (porque HIX recompila el HRB), pero que aparecería si algún día
   cachea.
8. **Narrativa didáctica embebida** (`cWhy` de `TCheck`). El propio
   test es tutorial.

### Lo discutible

1. **Instancias solo en memoria**. Reinicio del servidor = pérdida
   total. Para producción necesita persistencia (DBF, SQLite, lo
   que sea). No está pensado todavía.
2. **No hay concurrencia por instancia**. Dos `Run` en paralelo
   sobre la misma `FAC-B` podrían pisarse (fusionar `data` no es
   atómico, cambiar `state` tampoco). Haría falta un mutex por
   `cKey` o aceptar que el motor es *single-writer*.
3. **Handlers sin transacciones**. Si un handler peta a mitad de un
   `Eval`, el estado puede quedar inconsistente. Habría que decidir
   semántica (abortar, revertir, idempotencia).
4. **`CheckRules` muy básica**: `roles` sin AND, `fields` sin tipos,
   `limit` sin mínimo. Suelo correcto, no techo.
5. **Dos funciones de canonicalización** (`Lower+AllTrim` en `Run`
   y `Canon()` en `ProcessDefinition`). Hacen lo mismo pero son
   independientes. Un pequeño riesgo de deriva.
6. **No hay introspección**. No puedes preguntarle al motor "¿qué
   procesos conoces?" ni al proceso "dame tu grafo serializado".
   Vendrá bien para MCP.
7. **No hay eventos**. Si quisieras notificar "cada vez que un
   `receive` cree una instancia, dispara X", hoy tienes que meterlo
   dentro del handler. No hay hooks genéricos.
8. **Serialización ausente**. Un `ProcessDefinition` no se puede
   volcar a JSON y recuperar (los handlers son code blocks). Para
   un diseñador visual (BPMN) habría que inventar una capa de
   handlers por nombre.
9. **`Validate` en cada `Run`**. Barato hoy, redundante en caliente.
   Fácil de cachear con un flag.

### Veredicto

Como **primer ladrillo** de un BPM-para-llamarse-desde-IA está muy
bien dimensionado: pequeño, legible, sin dependencias, con tests
narrativos que **enseñan** mientras verifican. Las limitaciones (3,
4, 5 y 9 de la lista anterior) son fáciles de abordar cuando toque.
Las dos grandes (1 persistencia, 2 concurrencia) marcan la siguiente
etapa, y es lógico no haberlas resuelto todavía: hasta no tener un
cliente real (humano o IA) empujando `Run`, cualquier decisión sería
prematura.

---

## 9. Mapa rápido de funciones mencionadas

| Función / método                    | Fichero                                        | Papel en la traza                  |
|-------------------------------------|------------------------------------------------|------------------------------------|
| `Main`                              | `www/controllers/test.prg:35`                  | Entrada HTTP `/test`               |
| `TestBpm_InvoiceSimple`             | `www/controllers/test.prg:165`                 | Suite del camino B                 |
| `BpmTestUser:New`                   | `www/controllers/test.prg:103`                 | Objeto usuario mínimo              |
| `SimpleInvoiceProcess`              | `www/controllers/invoice_simple.prg:20`        | Fábrica del proceso                |
| `ProcessDefinition:New`             | `www/controllers/core/ProcessDefinition.prg:66`| Nombre canónico, hashes vacíos     |
| `ProcessDefinition:AddState/...`    | `.../ProcessDefinition.prg:73-154`             | Pintar el diagrama                 |
| `ProcessDefinition:Validate`        | `.../ProcessDefinition.prg:157`                | Integridad referencial             |
| `BpmEngine:New`                     | `www/controllers/core/BpmEngine.prg:35`        | Hash de instancias vacío           |
| `BpmEngine:Run`                     | `.../BpmEngine.prg:40`                         | Único punto de entrada             |
| `BpmEngine:CheckRules`              | `.../BpmEngine.prg:281`                        | Roles / fields / limit             |
| `BpmEngine:Cascade`                 | `.../BpmEngine.prg:191`                        | Rombos encadenados + manual pending|
| `BpmEngine:Log`                     | `.../BpmEngine.prg:364`                        | Añade línea al historial           |
| `BpmEngine:Get` / `BpmEngine:History`| `.../BpmEngine.prg:372 / :377`                | Lectura de estado                  |
| `USendJson`                         | runtime HIX                                    | Serializa `hRes` para el JS        |

Con este cuadro y la secuencia de 1 a 7, un lector puede abrir el
código y seguir el camino B de principio a fin sin saltos de fe.
