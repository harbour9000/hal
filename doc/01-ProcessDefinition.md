# ProcessDefinition — El plano del proceso

> Fichero: `www/controllers/core/ProcessDefinition.prg`
>
> Objetivo del documento: que al terminar de leerlo sepas qué es cada
> variable y qué hace cada método **sin necesidad de abrir el código**.
> Luego podrás abrirlo y simplemente *confirmar*.

---

## 1. La analogía: un plano, no una obra

Imagina que vas a montar un mueble de IKEA.

- El **plano** del mueble te dice: "hay 4 patas, 1 tablero, 12 tornillos
  y estas son las piezas que encajan con cuáles". El plano **no monta**
  el mueble: solo lo **describe**.
- El **montador** (una persona o un robot) coge el plano y lo convierte
  en un mueble real.

`ProcessDefinition` es el **plano**. No ejecuta nada. Solo describe
un proceso de negocio.
`BpmEngine` es el **montador**. Verás esa pieza en el documento 2.

> Si entiendes esta separación tienes el 50 % del BPM: una clase define,
> otra clase ejecuta. Nunca se mezclan.

---

## 2. Las 4 piezas de LEGO

Un proceso en este BPM se dibuja combinando **cuatro tipos de pieza**.
Si piensas en un diagrama de flujo clásico, los cuatro ya los conoces.

### 2.1 Estado — un círculo con "Fin" o "espera"

Un **estado** es un *punto donde el proceso se queda quieto*. O bien
porque es un final (`'approved'`, `'returned'`), o bien porque está
esperando una decisión (`'received'`).

```
       ┌──────────┐
       │ received │   ← un estado
       └──────────┘
```

### 2.2 Transición — la puerta de entrada

Una **transición** es la acción que **crea** la instancia. Para una
factura, es `receive`: "ha llegado una factura, empieza el proceso".
Siempre deja la instancia en un **estado inicial**.

```
       (nada)  ──receive──▶  [ received ]
```

### 2.3 Decisión — un rombo que elige camino

Una **decisión** es el clásico rombo del diagrama. Tiene **ramas con
etiquetas** (`'yes'`, `'no'`, `'retry'`...), y cada rama apunta a algo:

- A una **acción** (lo normal).
- O a **otro rombo** (los rombos se pueden encadenar).

```
                      ┌─ yes ──▶ (algo)
   ◇ ¿completa?  ─────┤
                      └─ no  ──▶ (otra cosa)
```

> **Regla importante** del BPM:
> Los rombos **nunca** apuntan directamente a un estado. Apuntan a
> acciones (o a otros rombos). Son las acciones las que terminan en un
> estado. Si rompes esta regla, `Validate()` te lo canta.

### 2.4 Acción — un operario que hace algo

Una **acción** es un **trabajo concreto** que:

1. Ejecuta un **handler** (un bloque de código que hace lo que haga
   falta: enviar un email, grabar en BBDD, cambiar un campo...).
2. Termina en un **estado**.

Hay dos sabores:

- **Automática** (por defecto): el motor la ejecuta sola cuando le toca.
- **Manual** (`.T.` como tercer parámetro): el motor **para** cuando
  llega a ella y espera a que un usuario con permiso la lance.

```
  manual_approve  (manual=.T.)  ──▶  [ approved ]
      │
      └── handler que graba quién firmó
```

---

## 3. La anatomía de la clase: 7 cajones

`ProcessDefinition` guarda su información en **7 variables** (los
"cajones"). Si entiendes qué guarda cada cajón, has entendido la clase.

```harbour
CLASS ProcessDefinition
   VAR cName          AS STRING   // nombre del proceso
   VAR aStates        AS ARRAY    // lista de estados
   VAR hTransitions   AS HASH     // transiciones
   VAR hDecisions     AS HASH     // rombos
   VAR hActions       AS HASH     // acciones
   VAR hStateDecision AS HASH     // cableado estado → rombo
   VAR hHandlers      AS HASH     // bloques de código (rombos y acciones)
   VAR hRules         AS HASH     // reglas de nivel 2
```

Cajón por cajón:

### `cName`
Un string, por ejemplo `'invoice_simple'`. Sirve para formar la clave
cuando el motor guarda instancias: `'invoice_simple|FAC-7'`.

### `aStates` — un array plano de estados
```
aStates := { 'received', 'approved', 'returned' }
```
Es un **array**, no un hash, porque un estado no tiene atributos: o
existe o no existe.

### `hTransitions` — hash de transiciones
Clave = nombre de la transición. Valor = *dónde deja la instancia*.
```
hTransitions := {
   'receive' => { 'state' => 'received' }
}
```

### `hDecisions` — hash de rombos
Cada rombo tiene su hash de ramas:
```
hDecisions := {
   'complete' => {
      'yes' => 'check_amount',    ← rama que lleva a otro rombo
      'no'  => 'notify_supplier'  ← rama que lleva a una acción
   },
   'check_amount' => {
      'yes' => 'auto_approve',
      'no'  => 'manual_approve'
   }
}
```

### `hActions` — hash de acciones
Cada acción dice **dónde termina** y si es manual:
```
hActions := {
   'notify_supplier' => { 'state' => 'returned', 'manual' => .F. },
   'auto_approve'    => { 'state' => 'approved', 'manual' => .F. },
   'manual_approve'  => { 'state' => 'approved', 'manual' => .T. }
}
```

### `hStateDecision` — el **cableado**
Esto es lo que **conecta** el flujo. Dice: *"cuando la instancia caiga
en este estado, evalúa este rombo"*.
```
hStateDecision := {
   'received' => 'complete'   ← tras receive → received → se dispara 'complete'
}
```

Sin esta línea, el motor nunca entraría en los rombos. Es el detalle
más fácil de olvidar.

### `hHandlers` — el cerebro de cada pieza
Cada **rombo** y cada **acción** necesita un handler (code block).
- Handler de **rombo**: recibe los datos y devuelve la etiqueta del
  camino (`'yes'`, `'no'`...).
- Handler de **acción**: recibe el contexto completo y hace trabajo
  (opcionalmente escribe en los datos).

```
hHandlers := {
   'complete'        => {| hData | ... 'yes' o 'no' },
   'check_amount'    => {| hData | ... 'yes' o 'no' },
   'notify_supplier' => {| hCtx  | ... hace trabajo },
   'auto_approve'    => {| hCtx  | ... hace trabajo },
   'manual_approve'  => {| hCtx  | ... hace trabajo }
}
```

### `hRules` — reglas de nivel 2 (opcional)
Filtros que se cuelgan de una transición o acción. Hay 3 tipos:
```
hRules := {
   'receive' => {
      'fields' => { 'supplier', 'amount' }   ← ambos deben venir con valor
   },
   'manual_approve' => {
      'roles'  => { 'approver' }             ← usuario debe tener este rol
   }
}
```
También existe `'limit' => { 'field' => 'amount', 'max' => 10000 }`.

---

## 4. `Canon()` — el conserje que normaliza nombres

Antes de guardar nada, los nombres pasan por una función interna:

```harbour
STATIC FUNCTION Canon( cName )
   LOCAL cKey := ''
   IF ValType( cName ) == 'C'
      cKey := Lower( AllTrim( cName ) )
   ENDIF
RETURN cKey
```

Hace dos cosas:
1. **Minúsculas**: `'Receive'` → `'receive'`.
2. **Sin espacios al borde**: `' receive '` → `'receive'`.

Gracias a esto, tú o el usuario podéis escribir los nombres con
cualquier mayúscula/espacio. Internamente siempre es la misma clave.

> Prueba mental: `oProc:IsState('RECEIVED')` devuelve `.T.`
> aunque hayas registrado el estado como `'received'`. Lo verás en
> los tests de `test.prg`.

---

## 5. Los métodos, uno a uno

### 5.1 `New(cName)` — nacer

```harbour
oProc := ProcessDefinition():New( 'invoice_simple' )
```

Simplemente guarda el nombre canonicalizado en `::cName`. Los 7
cajones empiezan vacíos.

### 5.2 `AddState(cState)` — "esto es un fin / espera"

```harbour
oProc:AddState( 'received' )
oProc:AddState( 'approved' )
```

Añade al array `::aStates` si no estaba ya. Idempotente: puedes
llamarlo dos veces con el mismo nombre y no pasa nada.

### 5.3 `AddTransition(cName, cToState)` — la puerta de entrada

```harbour
oProc:AddTransition( 'receive', 'received' )
```

Equivalente a:
```
hTransitions['receive'] := { 'state' => 'received' }
```

Nota: no comprueba todavía que `'received'` exista como estado. Esa
comprobación la hace `Validate()` después. Es intencionado: así
puedes añadir las piezas en el orden que quieras.

### 5.4 `AddDecision(cName, hBranches)` — un rombo

```harbour
oProc:AddDecision( 'complete', {
   'yes' => 'check_amount',
   'no'  => 'notify_supplier'
} )
```

Internamente canonicaliza tanto la etiqueta como el destino, y
guarda el hash en `::hDecisions`.

### 5.5 `AddAction(cName, cToState, lManual)` — una acción

```harbour
oProc:AddAction( 'notify_supplier', 'returned' )              // automática
oProc:AddAction( 'manual_approve',  'approved', .T. )         // manual
```

El tercer parámetro, si es `.T.`, marca la acción como "manual":
el motor se detendrá al llegar a ella.

### 5.6 `SetDecision(cState, cDecision)` — el cable

```harbour
oProc:SetDecision( 'received', 'complete' )
```

**Esta línea es la que arranca la cascada**. Sin ella, la instancia
cae en `received` y se queda ahí quieta porque el motor no sabe que
tiene que evaluar el rombo `complete`.

### 5.7 `SetHandler(cName, bBlock)` — el cerebro

```harbour
oProc:SetHandler( 'complete', {| hData |
   IIf( ! Empty(hData['supplier']) .AND. ! Empty(hData['amount']),
        'yes', 'no' )
} )

oProc:SetHandler( 'notify_supplier', {| hCtx |
   hCtx['data']['notified'] := .T.
} )
```

Dos tipos de block, misma clase de llamada:
- Para un **rombo**, el block recibe `hData` y **devuelve una etiqueta**.
- Para una **acción**, el block recibe `hCtx = { id, data, user, state }`
  y hace trabajo. Lo que devuelva se ignora.

El method **comprueba que `bBlock` sea realmente un bloque** (`ValType()
== 'B'`). Si le pasas otra cosa, lo ignora silenciosamente — y
después `Validate()` dirá `missing handler` para esa pieza.

### 5.8 `AddRule(cName, cType, xValue)` — un filtro

Sólo admite 3 tipos: `'roles'`, `'fields'`, `'limit'`. Si pones otro,
lo ignora. Puedes añadir varias reglas al mismo nodo:

```harbour
oProc:AddRule( 'receive', 'fields', { 'supplier', 'amount' } )
oProc:AddRule( 'receive', 'limit',  { 'field' => 'amount', 'max' => 10000 } )
oProc:AddRule( 'manual_approve', 'roles', { 'approver' } )
```

Internamente:
```
hRules := {
   'receive' => {
      'fields' => { 'supplier', 'amount' },
      'limit'  => { 'field' => 'amount', 'max' => 10000 }
   },
   'manual_approve' => {
      'roles' => { 'approver' }
   }
}
```

### 5.9 Los `IsXxx(...)` — chismes

Cuatro métodos de consulta rápida:

```harbour
oProc:IsState( 'received' )         // .T./.F.
oProc:IsTransition( 'receive' )     // .T./.F.
oProc:IsDecision( 'complete' )      // .T./.F.
oProc:IsAction( 'manual_approve' )  // .T./.F.
```

Útiles si estás escribiendo código genérico que inspecciona el
proceso. El motor los usa internamente para decidir cómo tratar
el `cAction` que le pide un `Run`.

### 5.10 `Validate()` — el inspector municipal

Devuelve `{ 'ok' => .T./.F., 'errors' => { ... } }`. Comprueba:

| comprobación                                      | ejemplo de error                                      |
|---------------------------------------------------|-------------------------------------------------------|
| Cada transición acaba en un estado conocido       | `transition go: unknown state nowhere`                |
| Cada acción acaba en un estado conocido           | `action act: unknown state ghost`                     |
| Cada acción tiene handler                         | `action act: missing handler`                         |
| Cada rama de cada rombo apunta a algo conocido    | `decision d branch yes: unknown target ghost`         |
| Cada rombo tiene handler                          | `decision d: missing handler`                         |
| El cableado estado→rombo usa piezas conocidas     | `setdecision: unknown state ghost`                    |
| Las reglas se cuelgan de transición o acción      | `rules on unknown node ghost`                         |

Es **puramente estructural**. No ejecuta nada. No llama a handlers.

> El motor llama a `Validate()` en cada `Run()`. Por eso **jamás**
> ejecuta un proceso roto. El coste es un recorrido de hashes.

---

## 6. Ejemplo progresivo: pizzeria

Veamos cómo construir un proceso distinto, para fijar ideas.

**Flujo**: llega un pedido. Si lleva piña, lo rechazamos (es una
pizzería seria). Si no, miramos si el cliente es VIP. VIP → cocinar
rápido. No VIP → cocinar normal. Las dos cocciones acaban en "listo".

```harbour
FUNCTION PizzeriaProcess()

   LOCAL oProc := ProcessDefinition():New( 'pizzeria' )

   // Estados (los "fins")
   oProc:AddState( 'nuevo' )
   oProc:AddState( 'listo' )
   oProc:AddState( 'rechazado' )

   // Transición (entrada)
   oProc:AddTransition( 'order', 'nuevo' )

   // Rombos
   oProc:AddDecision( 'con_pina', { ;
      'si' => 'rechazar', ;
      'no' => 'por_vip' } )

   oProc:AddDecision( 'por_vip', { ;
      'si' => 'cocinar_rapido', ;
      'no' => 'cocinar_normal' } )

   // Acciones (todas automáticas en este ejemplo)
   oProc:AddAction( 'rechazar',       'rechazado' )
   oProc:AddAction( 'cocinar_rapido', 'listo' )
   oProc:AddAction( 'cocinar_normal', 'listo' )

   // Cableado: al caer en 'nuevo' evalúa 'con_pina'
   oProc:SetDecision( 'nuevo', 'con_pina' )

   // Handlers de rombos (deciden camino)
   oProc:SetHandler( 'con_pina', {| hData | ;
      IIf( hb_HGetDef( hData, 'pina', .F. ), 'si', 'no' ) } )

   oProc:SetHandler( 'por_vip', {| hData | ;
      IIf( hb_HGetDef( hData, 'vip',  .F. ), 'si', 'no' ) } )

   // Handlers de acciones (hacen trabajo)
   oProc:SetHandler( 'rechazar', {| hCtx | ;
      hCtx['data']['motivo'] := 'pina detectada' } )

   oProc:SetHandler( 'cocinar_rapido', {| hCtx | ;
      hCtx['data']['tiempo'] := 8 } )

   oProc:SetHandler( 'cocinar_normal', {| hCtx | ;
      hCtx['data']['tiempo'] := 15 } )

   // Regla: el pedido debe traer cliente
   oProc:AddRule( 'order', 'fields', { 'cliente' } )

RETURN oProc
```

Con eso, un `Run(oProc, oUser, 'order', { 'id' => 'P-1', 'cliente' =>
'Ana', 'pina' => .F., 'vip' => .T. })` acabaría con `state='listo'` y
`data['tiempo']=8` en una sola llamada.

---

## 7. Errores habituales de principiante

Cosas con las que vas a tropezar la primera semana:

1. **Olvidar `SetDecision`**. El proceso valida bien, pero al correr
   te quedas eternamente en `received` porque el motor nunca entra
   en los rombos.

2. **El handler del rombo devuelve una etiqueta que no existe**.
   `Validate()` **no** lo pilla (sería imposible: el handler puede
   devolver cualquier cosa en tiempo de ejecución). Lo pilla el motor:
   `unknown branch`.

3. **Un rombo apuntando a un estado**. No puedes:
   ```harbour
   oProc:AddDecision( 'd', { 'yes' => 'approved' } )  // 'approved' es ESTADO
   ```
   `Validate()` lo rechaza (`unknown target approved`), porque
   `IsAction` e `IsDecision` dicen `.F.` para un estado.

4. **Pasar un string donde debería ir un code block**. `SetHandler`
   lo ignora en silencio y luego `Validate()` dice `missing handler`.
   El silencio inicial puede despistar.

5. **Reutilizar un nombre entre tipos**. Un mismo nombre puede ser
   simultáneamente estado y acción (los cajones son independientes).
   Mejor no hacerlo: desorienta y hace la cascada ambigua a la vista.

6. **Olvidar que las reglas van sobre la acción que llama el
   usuario**. Si pones `roles` sobre `auto_approve`, no servirá:
   `auto_approve` corre dentro de la cascada, nunca la pide un
   usuario directamente.

---

## 8. Cheatsheet

```harbour
oProc := ProcessDefinition():New( 'nombre' )

// NIVEL 1 — el dibujo
oProc:AddState( 'estado' )
oProc:AddTransition( 'nombre', 'estadoInicial' )
oProc:AddDecision( 'nombre', { 'etiqueta' => 'destino', ... } )
oProc:AddAction( 'nombre', 'estadoFinal' [, lManual ] )
oProc:SetDecision( 'estado', 'rombo' )     // CABLEADO: no lo olvides
oProc:SetHandler( 'nombre', {|...| ... } ) // para cada rombo y acción

// NIVEL 2 — reglas (opcional)
oProc:AddRule( 'nombre', 'roles',  { 'rol1', 'rol2' } )
oProc:AddRule( 'nombre', 'fields', { 'campo1', 'campo2' } )
oProc:AddRule( 'nombre', 'limit',  { 'field' => 'c', 'max' => 1000 } )

// INSPECCIÓN
hRes := oProc:Validate()  // { ok => .T./.F., errors => { ... } }
oProc:IsState('x')  oProc:IsTransition('x')
oProc:IsDecision('x')  oProc:IsAction('x')
```

Con esto en la cabeza, ya puedes leer `ProcessDefinition.prg` como
quien lee una lista: cada método encaja en un cajón, y no hay
sorpresas.
