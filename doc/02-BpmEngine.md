# BpmEngine — El motor que ejecuta el plano

> Fichero: `www/controllers/core/BpmEngine.prg`
>
> Prerrequisito: leer antes `01-ProcessDefinition.md`. Si todavía no
> tienes claro qué es un *estado*, una *transición*, un *rombo* y una
> *acción*, vuelve atrás. Aquí damos por hecho ese vocabulario.

---

## 1. La analogía: el músico que lee la partitura

En el documento 1 vimos que `ProcessDefinition` es como el **plano**
de un mueble: solo describe. `BpmEngine` es el **montador**.

Otra analogía igual de válida: un **músico leyendo una partitura**.

- La *partitura* (ProcessDefinition) no suena: solo dice qué nota va
  después de qué.
- El *músico* (BpmEngine) la lee y la **toca**.

Un motor **no sabe nada del dominio**. No sabe qué es una factura,
una pizza o un pedido. Solo sabe:

1. Validar lo que le pides.
2. Crear o reanudar una **instancia** (= un "expediente" vivo).
3. Pasar por los **rombos** evaluando sus handlers.
4. Ejecutar las **acciones** llamando a sus handlers.
5. Parar en las acciones **manuales** y esperar.
6. Dejar **rastro** (historial).

Y poco más. La magia es que, siendo tan tonto, sirve para cualquier
proceso que puedas dibujar.

---

## 2. Lo único que guarda el motor

```harbour
CLASS BpmEngine
   VAR hInstances AS HASH INIT { => }
   ...
```

**Un solo hash**. Clave: `'nombreProceso|idInstancia'`. Valor: el
expediente. Si creas dos facturas:

```
hInstances := {
   'invoice_simple|FAC-1' => { ... expediente de FAC-1 ... },
   'invoice_simple|FAC-2' => { ... expediente de FAC-2 ... }
}
```

> Consecuencias importantes:
> - Dos procesos distintos pueden tener ids iguales sin pisarse,
>   porque la clave incluye el nombre del proceso.
> - Todo vive **en memoria**. Reiniciar `hix.exe` las borra. Para
>   persistir habría que serializar este hash.
> - Dos motores (`BpmEngine():New()` dos veces) no comparten nada.
>   Suele instanciarse uno global y punto, pero no es obligatorio.

---

## 3. ¿Qué es una instancia?

Una **instancia** es un hash con 6 claves. Es el "expediente" vivo
de **un** caso concreto (una factura, un pedido, lo que sea).

```
hInst := {
   'id'      => 'FAC-7',         // la identidad del caso
   'process' => 'invoice_simple',// a qué proceso pertenece
   'state'   => 'received',      // dónde está ahora mismo
   'data'    => { ... },         // los datos de negocio del caso
   'pending' => 'manual_approve',// acción manual que espera (o '')
   'history' => { ... }          // lista de pasos ya dados
}
```

El `data` es el campo más rico: ahí viven **todos los datos de
negocio**. El motor lo trata como una caja opaca. Los handlers son
los que entienden qué hay dentro (que si `supplier`, que si `amount`...).

El `history` es una **lista de dicts**, uno por paso:

```
{ 'ts' => '20261015123045', 'user' => 'ana',
  'action' => 'receive', 'from' => '', 'to' => 'received' }
```

---

## 4. El punto de entrada único: `Run`

**Toda interacción con el motor pasa por `Run`**. No hay más puertas.

```harbour
hRes := oEng:Run( oProcess, oUser, cAction, hData )
```

- `oProcess`: una `ProcessDefinition` ya montada.
- `oUser`: cualquier objeto con `cName` (string) y `aRoles` (array).
- `cAction`: nombre de una transición o de una acción manual.
- `hData`: hash con los datos (**debe traer `'id'`**).

Devuelve siempre un hash con la misma forma:

```
hRes := {
   'ok'       => .T./.F.,
   'error'    => '',           // texto legible si ok=.F.
   'id'       => 'FAC-7',      // identidad del caso
   'state'    => 'approved',   // estado tras la llamada
   'pending'  => '',           // acción manual pendiente (o '')
   'executed' => { 'auto_approve' },  // qué corrió la cascada
   'history'  => { ... }       // historial completo
}
```

> Esto es importante: **el motor nunca lanza excepciones hacia
> arriba**. Devuelve siempre `hRes`. Es muy agradable para el
> consumidor (humano o IA).

Vamos a diseccionar `Run` paso a paso.

### 4.1 Canonicaliza el nombre de la acción
```harbour
cName := Lower( AllTrim( hb_defaultValue( cAction, '' ) ) )
```
Si llamas con `'Receive'` o `' RECEIVE '`, queda `'receive'`.

### 4.2 Prepara el hash de respuesta
```harbour
hRes := { 'ok' => .T., 'error' => '', ... }
```
Partimos de "todo bien" y lo vamos emporcando si algo falla.

### 4.3 Valida que `oProcess` sea un `ProcessDefinition`
```harbour
IF ValType(oProcess) != 'O' .OR. ! __ObjHasMsg(oProcess, 'VALIDATE')
   hRes[ 'error' ] := 'process is not a ProcessDefinition'
   RETURN hRes
ENDIF
```
Es *duck typing*: no comprueba la clase, solo que tenga `Validate()`.
Si le pasas un objeto raro sin ese método, lo rechaza.

### 4.4 Llama a `Validate()` del proceso
```harbour
hValid := oProcess:Validate()
IF ! hValid[ 'ok' ]
   hRes[ 'error' ] := 'invalid process definition: ' + hValid['errors'][1]
   RETURN hRes
ENDIF
```
Jamás ejecuta un proceso roto. Esto blinda el motor.

### 4.5 Valida el usuario
```harbour
IF ValType(oUser) != 'O' .OR. ! __ObjHasMsg(oUser, 'CNAME') .OR. ...
   hRes[ 'error' ] := 'user must expose cName and aRoles'
```
Nuevamente *duck typing*. No necesitas usar una clase concreta.

### 4.6 Comprueba que `hData` traiga `'id'`
```harbour
cId := hb_HGetDef( hData, 'id', '' )
IF Empty( cId )
   hRes[ 'error' ] := "missing 'id' in data"
```
Sin `id` no hay forma de identificar el caso. El error nombra `'id'`
literalmente para que el consumidor sepa qué le falta.

### 4.7 Decide: ¿transición, acción, u otra cosa?
```harbour
cKey := oProcess:cName + '|' + cId

DO CASE
CASE oProcess:IsTransition( cName )     // "crear"
   ...
CASE oProcess:IsAction( cName )          // "reanudar"
   ...
OTHERWISE
   hRes[ 'error' ] := 'unknown action ' + cName
ENDCASE
```

Dos ramas: crear una instancia nueva, o seguir una ya existente.

### 4.8 Rama "crear" (transición)
```harbour
IF hb_HHasKey( ::hInstances, cKey )
   hRes[ 'error' ] := 'instance already exists'
```
Un id no puede repetirse para el mismo proceso.

```harbour
hRule := ::CheckRules( oProcess, cName, oUser, hData )
IF ! hRule[ 'ok' ]
   RETURN hRule
```
Las reglas de nivel 2 (ver §6). Si fallan, el motor **no crea** nada.

```harbour
hInst := { 'id' => cId, 'process' => ..., 'state' => '',
           'data' => hData, 'pending' => '', 'history' => {} }
hInst[ 'state' ] := oProcess:hTransitions[ cName ][ 'state' ]
::hInstances[ cKey ] := hInst
::Log( hInst, oUser:cName, cName, '', hInst[ 'state' ] )
```
Monta el expediente, lo pone en el hash y registra la primera línea
de historial.

### 4.9 Rama "reanudar" (acción manual)
```harbour
IF ! hb_HHasKey( ::hInstances, cKey )
   hRes[ 'error' ] := 'unknown instance'
```
No puedes "aprobar" una factura que no existe.

```harbour
hInst := ::hInstances[ cKey ]
IF hInst[ 'pending' ] != cName
   hRes[ 'error' ] := 'action ' + cName + ' not pending ...'
```
Blindaje importante: solo puedes ejecutar la acción manual que **estaba
esperando**. No puedes saltar a cualquier acción desde cualquier
estado.

```harbour
hRule := ::CheckRules( ... )
```
Las reglas también se aplican aquí (típicamente `roles`).

```harbour
hb_HMerge( hInst[ 'data' ], hData )
```
**Fusión de datos**. Si al reanudar mandas datos nuevos, se añaden
al expediente. Útil: el *approver* puede añadir un `comment`, y queda
grabado para siempre.

```harbour
hDef := oProcess:hActions[ cName ]
hCtx := { 'id' => cId, 'data' => hInst['data'],
          'user' => oUser, 'state' => hInst['state'] }
Eval( oProcess:hHandlers[ cName ], hCtx )
```
Llama al handler de la acción con el contexto. El handler puede
modificar `hCtx['data']` y queda reflejado en la instancia (es la
misma referencia).

```harbour
hInst[ 'pending' ] := ''
::Log( ... )
hInst[ 'state' ] := hDef[ 'state' ]
```
Limpia el pending, registra, cambia el estado.

### 4.10 Y después, siempre: cascada

```harbour
hRes := ::Cascade( oProcess, hInst, hRes )
```

Tanto si crearon la instancia como si la reanudaron, el motor
intenta seguir avanzando automáticamente. Veámoslo.

---

## 5. `Cascade` — el autopiloto

La cascada es el **autopilot** del motor. Mientras el estado actual
tenga un rombo cableado, intenta avanzar.

### 5.1 El bucle externo
```harbour
DO WHILE hb_HHasKey( oProcess:hStateDecision, hInst[ 'state' ] )
```
Si hay un rombo colgado del estado actual, entra. Si no, termina.

### 5.2 Freno anti-bucles
```harbour
IF ++nSteps > MAX_STEPS      // MAX_STEPS = 100
   hRes[ 'error' ] := 'max steps exceeded (loop?)'
   RETURN hRes
ENDIF
```
Si por accidente dibujas `d1 → d2 → d1`, el motor se para antes
de colgar el servidor. 100 pasos es generoso: en procesos normales
nunca te vas a acercar.

### 5.3 El bucle interno: cadena de rombos
Un rombo puede apuntar a otro rombo. El bucle interno **resuelve
toda la cadena** hasta aterrizar en una **acción**.

```harbour
DO WHILE .T.
   hBranch := oProcess:hDecisions[ cDecision ]

   cLabel := Lower( AllTrim( hb_defaultValue( ;
                Eval( oProcess:hHandlers[ cDecision ], hInst['data'] ), '' ) ) )

   IF ! hb_HHasKey( hBranch, cLabel )
      hRes[ 'error' ] := 'decision ... returned unknown branch ' + cLabel
      RETURN hRes
   ENDIF

   cTarget := hBranch[ cLabel ]

   IF oProcess:IsDecision( cTarget )
      cDecision := cTarget      ← es otro rombo: seguimos
      LOOP
   ENDIF

   EXIT                         ← aterrizamos en una acción
ENDDO
```

Al salir, `cTarget` es siempre el nombre de una **acción**.

### 5.4 Si la acción es manual → aparcar
```harbour
IF hDef[ 'manual' ]
   hInst[ 'pending' ] := cTarget
   ::Log( hInst, 'system', 'route', hInst[ 'state' ], 'wait ' + cTarget )
   AAdd( hRes[ 'executed' ], cTarget + ' (pending)' )
   RETURN hRes
ENDIF
```

Clave del diseño: el motor **no ejecuta** acciones manuales durante
la cascada. Las deja pendientes. La instancia queda con `pending`
puesto y `state` sin cambiar.

### 5.5 Si la acción es automática → ejecutar
```harbour
hCtx := { 'id' => ..., 'data' => hInst['data'], 'user' => NIL, 'state' => ... }
Eval( oProcess:hHandlers[ cTarget ], hCtx )
::Log( ... )
hInst[ 'state' ] := hDef[ 'state' ]
AAdd( hRes[ 'executed' ], cTarget )
```

Fíjate: `user => NIL`. Las acciones automáticas no tienen usuario,
las ejecuta "el sistema". Si tu handler necesita saber "quién fue",
las acciones automáticas no son la pieza indicada.

Tras ejecutar, se vuelve al principio del bucle externo: si el nuevo
estado también tiene rombo, se encadena. Si no, salimos.

---

## 6. `CheckRules` — el portero

Comprueba las reglas de nivel 2 **antes** de crear la instancia o
antes de ejecutar la acción manual. Es como un portero de discoteca.

### 6.1 Si no hay reglas, pasa
```harbour
IF ! hb_HHasKey( oProcess:hRules, cName )
   RETURN hRes      // ok = .T.
```

### 6.2 Regla `roles` — el usuario debe tener al menos uno
```harbour
IF hb_HHasKey( hRules, 'roles' )
   lAllowed := .F.
   FOR nI := 1 TO Len( hRules[ 'roles' ] )
      FOR nJ := 1 TO Len( oUser:aRoles )
         IF Lower( oUser:aRoles[nJ] ) == Lower( hRules[ 'roles' ][nI] )
            lAllowed := .T.
         ENDIF
      NEXT
   NEXT
   IF ! lAllowed
      hRes[ 'error' ] := 'role not allowed for ' + cName
      RETURN hRes
```

Es un bucle doble (`O(n·m)`). Da igual con 3 roles.
Semántica: **OR**. Basta con que el usuario tenga **uno** de los
roles permitidos.

### 6.3 Regla `fields` — todos los campos deben tener valor
```harbour
IF hb_HHasKey( hRules, 'fields' )
   FOR EACH cField IN hRules[ 'fields' ]
      IF Empty( hb_HGetDef( hData, cField, NIL ) )
         hRes[ 'error' ] := 'missing field ' + cField
         RETURN hRes
```

"Empty" aquí es el `Empty()` de Harbour: `""`, `0`, `.F.`, `NIL`,
array vacío... Cualquiera de esos cuenta como vacío.

### 6.4 Regla `limit` — un número no supera un máximo
```harbour
IF hb_HHasKey( hRules, 'limit' )
   hLimit := hRules[ 'limit' ]
   IF hb_HGetDef( hData, hLimit['field'], 0 ) > hLimit['max']
      hRes[ 'error' ] := 'limit exceeded on ' + hLimit['field']
```

Solo máximo. No hay mínimo ni rango. Si quieres algo más fino, hay
que extender esta función (o moverlo al handler, cuando ya tenga
contexto).

---

## 7. `Log` — la cámara de seguridad

```harbour
METHOD Log( hInst, cUser, cAction, cFrom, cTo )
   AAdd( hInst['history'], { 'ts' => ..., 'user' => cUser,
                             'action' => cAction, 'from' => cFrom,
                             'to' => cTo } )
```

Añade **una línea por cada movimiento**. El motor lo llama solo:
el handler no tiene que preocuparse.

Tipos de línea de historial que verás:

| cuándo                        | ejemplo                                                                 |
|-------------------------------|-------------------------------------------------------------------------|
| transición (crear)            | `{ user:'ana', action:'receive', from:'', to:'received' }`              |
| rombo que lleva a manual      | `{ user:'system', action:'route', from:'received', to:'wait manual_approve' }` |
| acción automática en cascada  | `{ user:'system', action:'auto_approve', from:'received', to:'approved' }` |
| acción manual lanzada         | `{ user:'boss', action:'manual_approve', from:'received', to:'approved' }` |

---

## 8. `Get` e `History` — ventanas de lectura

```harbour
oEng:Get( oProc, 'FAC-1' )
```
Devuelve el expediente completo, o `NIL` si no existe.

```harbour
oEng:History( oProc, 'FAC-1' )
```
Devuelve solo el `history`. Array vacío si no existe la instancia.
No peta cuando la instancia no está: una decisión amable.

---

## 9. Ejemplo guiado: desde cero hasta `approved`

Vamos a correr un caso completo (con las dos clases ya cargadas por
`00_bpm_core.prg`):

```harbour
oProc := SimpleInvoiceProcess()
oEng  := BpmEngine():New()

// Un usuario cualquiera con rol clerk
LOCAL oClerk := BpmTestUser():New( 'ana', { 'clerk' } )

// Factura pequeña y completa — todo automático
hRes := oEng:Run( oProc, oClerk, 'receive',
   { 'id' => 'FAC-1', 'supplier' => 'ACME', 'amount' => 250 } )

?  hRes[ 'ok' ]        //  .T.
?  hRes[ 'state' ]     //  'approved'
?  hRes[ 'pending' ]   //  ''
?  hRes[ 'executed' ]  //  { 'auto_approve' }
```

Reconstruyendo lo que pasó por dentro:

1. `Run` canonicaliza `'receive'`.
2. `Validate(oProc)` → ok.
3. Usuario OK, `id='FAC-1'` OK.
4. `IsTransition('receive')` → rama "crear".
5. `CheckRules('receive')`: regla `fields={supplier,amount}` → ambos
   presentes → ok.
6. Crea `hInst` con `state='received'`. Log: `receive, ''→'received'`.
7. Entra `Cascade`:
   - `hStateDecision['received']='complete'` → entra.
   - Handler de `complete`: supplier="ACME", amount=250 → no vacíos
     → `'yes'`.
   - `complete['yes']='check_amount'` → es otro rombo, `LOOP`.
   - Handler de `check_amount`: `amount=250 < 1000` → `'yes'`.
   - `check_amount['yes']='auto_approve'` → es acción, `EXIT`.
   - `auto_approve.manual=.F.` → ejecuta handler
     (`data['approved_by']='system'`), log, state='approved'.
   - Vuelve al `WHILE`: `hStateDecision['approved']` no existe → sale.
8. Devuelve `hRes` con `state='approved'`.

Una sola llamada. El consumidor no se entera de los rombos.

**Ahora un caso que espera firma humana**:

```harbour
hRes := oEng:Run( oProc, oClerk, 'receive',
   { 'id' => 'FAC-2', 'supplier' => 'ACME', 'amount' => 2500 } )

?  hRes[ 'state' ]     //  'received'
?  hRes[ 'pending' ]   //  'manual_approve'
```

Cascada: `complete`→yes, `check_amount`→no (2500≥1000), aterriza en
`manual_approve`, es `manual=.T.` → **aparca**. Returns.

El supervisor firma:

```harbour
LOCAL oBoss := BpmTestUser():New( 'boss', { 'approver' } )

hRes := oEng:Run( oProc, oBoss, 'manual_approve', { 'id' => 'FAC-2' } )

?  hRes[ 'state' ]  //  'approved'
?  oEng:Get(oProc, 'FAC-2')['data']['approved_by']  //  'boss'
```

Rama "reanudar": existe, `pending='manual_approve'` coincide,
`CheckRules`→roles ok (boss es `approver`), merge de datos, llamada
al handler, pending='', log, state='approved'. Y después `Cascade`:
`approved` no tiene rombo → termina.

**Error típico que verías si Ana intenta firmar**:

```harbour
hRes := oEng:Run( oProc, oClerk, 'manual_approve', { 'id' => 'FAC-2' } )
?  hRes[ 'ok' ]     //  .F.
?  hRes[ 'error' ]  //  'role not allowed for manual_approve'
```

El motor **no toca la instancia**. Puedes reintentar con otro usuario.

---

## 10. Catálogo de errores que devuelve el motor

Todos vienen como `{ ok=.F., error='...' }`:

| error                                     | causa                                           |
|-------------------------------------------|-------------------------------------------------|
| `process is not a ProcessDefinition`      | `oProcess` no tiene método `Validate`           |
| `invalid process definition: ...`         | `Validate()` del proceso falla                  |
| `user must expose cName and aRoles`       | `oUser` no es un objeto con esos atributos      |
| `missing 'id' in data`                    | `hData` sin clave `'id'`                        |
| `instance already exists`                 | Transición con un id que ya está en uso         |
| `unknown instance`                        | Acción manual con un id que no existe           |
| `action X not pending (state Y)`          | La instancia no esperaba esa acción             |
| `unknown action X`                        | `cAction` no es transición ni acción conocida   |
| `role not allowed for X`                  | `CheckRules`: el usuario no tiene ningún rol OK |
| `missing field X`                         | `CheckRules`: campo obligatorio vacío           |
| `limit exceeded on X`                     | `CheckRules`: número por encima del máximo      |
| `decision X returned unknown branch Y`    | Handler de rombo devolvió etiqueta no definida  |
| `max steps exceeded (loop?)`              | Freno anti-bucles: >100 pasos de cascada        |

Todos son textos planos: fáciles de leer para un humano y para una IA.

---

## 11. Pros y contras — para que no te sorprendan

### A favor
- **Un solo punto de entrada**: trivial de testear y de exponer.
- **Siempre devuelve un hash**: no hay excepciones por manejar.
- **Valida antes de ejecutar**: imposible correr procesos rotos.
- **Freno anti-bucles**: imposible colgar el servidor con un rombo mal.
- **Instancias independientes**: dos facturas no se mezclan.
- **Historial automático**: el handler no se preocupa de loguear.
- **Fusión de datos**: cada llamada manual puede ampliar el expediente.

### En contra
- **Instancias en memoria**: reinicio = pérdida. Falta persistencia.
- **Sin concurrencia**: dos `Run` sobre la misma instancia pueden
  pisarse. Haría falta un mutex por `cKey`.
- **Sin transacciones**: si un handler explota a mitad, la instancia
  puede quedar en estado raro.
- **Reglas básicas**: `roles` solo OR, `fields` solo "no vacío",
  `limit` solo máximo. Suelo correcto, no techo.
- **`Validate()` en cada Run**: fácil de cachear, hoy no se cachea.
- **Sin eventos**: no hay forma de "escucharme cuando una instancia
  llega a este estado"; hay que meterlo dentro del handler.

---

## 12. Cheatsheet

```harbour
// Crear motor
oEng := BpmEngine():New()

// Crear instancia (transición)
hRes := oEng:Run( oProc, oUser, 'nombreTransicion',
                  { 'id' => 'X', 'campo1' => ..., ... } )

// Reanudar acción manual
hRes := oEng:Run( oProc, oUser, 'nombreAccion',
                  { 'id' => 'X', 'campoNuevo' => ... } )

// Leer
hInst   := oEng:Get( oProc, 'X' )       // expediente completo o NIL
aHist   := oEng:History( oProc, 'X' )   // historial o {}

// Interpretar la respuesta
hRes[ 'ok' ]       // .T. / .F.
hRes[ 'error' ]    // texto si .F.
hRes[ 'state' ]    // dónde está la instancia
hRes[ 'pending' ]  // acción manual que espera (o '')
hRes[ 'executed' ] // array de acciones automáticas corridas
hRes[ 'history' ]  // historial actualizado
```

Con esto deberías poder leer `BpmEngine.prg` como quien ve un
diagrama ya conocido.
