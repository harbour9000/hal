# SimpleInvoiceProcess — Un proceso real, pieza a pieza

> Fichero: `www/controllers/invoice_simple.prg`
>
> Prerrequisito: haber leído `01-ProcessDefinition.md` (sabrás qué es
> cada método que se usa) y `02-BpmEngine.md` (sabrás cómo se ejecuta).
> Si solo te interesa *qué modela este proceso en concreto*, puedes
> leer este documento solo, aunque hay guiños a los otros.

---

## 1. ¿Qué modela?

Un proceso de **recepción de facturas de proveedor**. Fiel al diagrama
original:

> Recibo una factura. Si no está completa, aviso al proveedor y la
> devuelvo. Si está completa, miro el importe: si es pequeña, la
> apruebo automáticamente; si es grande, pido firma humana.

En código, todo esto cabe en **una sola función** llamada
`SimpleInvoiceProcess()`. Esa función es una **fábrica**: devuelve un
`ProcessDefinition` ya montado y listo para `Run`.

---

## 2. El dibujo

```
          ┌──────────┐
          │          │
          ▼          │
      ┌──────┐       │
──▶   receive         (transición: crea la instancia)
      └──────┘
          │
          ▼
     [ received ]  ◀── estado tras receive
          │
          ▼
      ◇ complete  ◀── "¿la factura trae supplier y amount?"
      ╱       ╲
    no         yes
    │           │
    ▼           ▼
notify     ◇ check_amount   ◀── "¿amount < 1000?"
supplier       ╱    ╲
    │        yes      no
    │        │        │
    ▼        ▼        ▼
[returned][approved]  manual_approve  (MANUAL: espera firma)
             ▲             │
             │             ▼
             └────────[ approved ]
```

Reglas prometidas por el diagrama:

- **Completa y pequeña (<1000)** → `approved` por `system`, sin
  intervención humana.
- **Completa y grande (≥1000)** → espera firma de un usuario con rol
  `approver`.
- **Incompleta** → `notified` al proveedor, estado `returned`.

---

## 3. La fábrica, pieza a pieza

El código entero cabe en ~80 líneas útiles. Vamos sección a sección.

### 3.1 Nacimiento

```harbour
oProc := ProcessDefinition():New( 'invoice_simple' )
```

Un plano vacío con nombre canónico `'invoice_simple'`.

### 3.2 Los estados ("fins")

```harbour
oProc:AddState( 'received' )
oProc:AddState( 'approved' )
oProc:AddState( 'returned' )
```

Tres puntos de parada. `received` es temporal (ahí se decidirá
camino); `approved` y `returned` son finales reales.

### 3.3 La transición de entrada

```harbour
oProc:AddTransition( 'receive', 'received' )
```

**La única forma de empezar** un expediente de factura es llamando a
`Run(..., 'receive', ...)`. Cualquier intento de llamar a `auto_approve`
"a pelo" devolvería `unknown action`.

### 3.4 Los rombos

```harbour
oProc:AddDecision( 'complete', {
   'no'  => 'notify_supplier',
   'yes' => 'check_amount'
} )

oProc:AddDecision( 'check_amount', {
   'yes' => 'auto_approve',
   'no'  => 'manual_approve'
} )
```

Nota algo elegante: la rama `'yes'` de `complete` **no apunta a una
acción** sino a **otro rombo** (`check_amount`). El motor sabe
encadenarlos, no hay que hacer nada especial.

### 3.5 Las acciones

```harbour
oProc:AddAction( 'notify_supplier', 'returned' )
oProc:AddAction( 'auto_approve',    'approved' )
oProc:AddAction( 'manual_approve',  'approved', .T. )   ← MANUAL
```

Dos automáticas y una manual. La manual se declara con el tercer
parámetro en `.T.`. El motor **no la ejecuta** sola: cuando la cascada
aterrice en ella, aparcará la instancia.

### 3.6 El cable que arranca la cascada

```harbour
oProc:SetDecision( 'received', 'complete' )
```

Esta línea pequeña es **vital**. Es la que le dice al motor:
> *"cuando una instancia caiga en `'received'`, evalúa el rombo
> `'complete'`"*.

Si la quitas, el proceso pasa `Validate()` pero cualquier `receive`
dejaría la instancia pegada eternamente en `'received'`.

### 3.7 Los handlers de los rombos

Un handler de rombo recibe los **datos** y **devuelve una etiqueta**.

```harbour
oProc:SetHandler( 'complete', {| hData |
   IIf( ! Empty( hb_HGetDef( hData, 'supplier', '' ) ) .AND.
        ! Empty( hb_HGetDef( hData, 'amount',   0  ) ),
        'yes', 'no' ) } )
```

Traducido: *"está completa si supplier y amount tienen valor"*.
`'yes'` o `'no'` son las dos únicas etiquetas que `AddDecision`
registró para `complete`; si devolviera cualquier otra cosa, el motor
diría `unknown branch`.

```harbour
oProc:SetHandler( 'check_amount', {| hData |
   IIf( hb_HGetDef( hData, 'amount', 0 ) < 1000, 'yes', 'no' ) } )
```

Pequeña si amount **estrictamente** menor que 1000. **1000 exactos**
cae en `'no'` y, por tanto, va a manual. Esto hay un test que lo
verifica (`edge: 1000 goes to manual` en `test.prg`).

### 3.8 Los handlers de las acciones

Un handler de acción recibe `hCtx = { id, data, user, state }` y
suele **escribir en `hCtx['data']`** (que es la referencia viva).

```harbour
oProc:SetHandler( 'notify_supplier', {| hCtx |
   hCtx[ 'data' ][ 'notified' ] := .T. } )
```

Marca el expediente como notificado. En un proyecto real, aquí
habría también un `SendMail(...)` o similar. El motor no se entera:
le da igual.

```harbour
oProc:SetHandler( 'auto_approve', {| hCtx |
   hCtx[ 'data' ][ 'approved_by' ] := 'system' } )
```

Las aprobadas automáticamente dejan rastro de que las aprobó "el
sistema". Importante para auditoría luego.

```harbour
oProc:SetHandler( 'manual_approve', {| hCtx |
   hCtx[ 'data' ][ 'approved_by' ] := hCtx[ 'user' ]:cName } )
```

Las manuales dejan rastro del **nombre del usuario que firmó**.
Fíjate que aquí sí usamos `hCtx['user']`, mientras que en
`auto_approve` ni lo miramos (en la cascada, `user` llega como `NIL`).

### 3.9 Las reglas (nivel 2)

```harbour
oProc:AddRule( 'receive',        'fields', { 'supplier', 'amount' } )
oProc:AddRule( 'manual_approve', 'roles',  { 'approver' } )
```

Dos reglas, muy distintas en espíritu:

- `receive + fields`: **al crear** una factura, los campos `supplier`
  y `amount` deben venir con valor. Es una validación de entrada.
- `manual_approve + roles`: **al firmar** manualmente, el usuario
  debe tener el rol `approver`. Es un control de autorización.

> No hay reglas sobre `auto_approve` ni `notify_supplier`. Tampoco
> tendría sentido: esas acciones **las ejecuta el motor en cascada**,
> no las pide un usuario. Las reglas se aplican a lo que un
> **usuario** llama por `Run`.

---

## 4. Los 3 caminos vividos con casos reales

Vamos a ejecutar los tres caminos del diagrama. Todo lo que sigue
es ejecutable en el proyecto (con el motor cargado).

### Caso A — Pequeña y completa → `approved` automática

```harbour
oProc  := SimpleInvoiceProcess()
oEng   := BpmEngine():New()
oClerk := BpmTestUser():New( 'ana', { 'clerk' } )

hRes := oEng:Run( oProc, oClerk, 'receive',
   { 'id' => 'FAC-A', 'supplier' => 'Papelera Sur', 'amount' => 320 } )

?  hRes[ 'ok' ]        // .T.
?  hRes[ 'state' ]     // 'approved'
?  hRes[ 'pending' ]   // ''
?  hRes[ 'executed' ]  // { 'auto_approve' }
?  oEng:Get(oProc, 'FAC-A')['data']['approved_by']   // 'system'
```

Lo que pasó en orden:

1. `receive` creó la instancia en `received`.
2. Cascada: `complete` → `'yes'` (supplier y amount llenos).
3. Encadenado: `check_amount` → `'yes'` (320 < 1000).
4. Aterrizó en `auto_approve` (automática).
5. Handler escribió `approved_by='system'`.
6. Estado → `approved`.
7. No hay rombo colgado de `approved` → termina.

**Un solo `Run`. Ana ni se entera de los rombos.**

### Caso B — Grande y completa → espera firma

```harbour
hRes := oEng:Run( oProc, oClerk, 'receive',
   { 'id' => 'FAC-B', 'supplier' => 'Papelera Sur', 'amount' => 2400 } )

?  hRes[ 'state' ]     // 'received'
?  hRes[ 'pending' ]   // 'manual_approve'
```

Cascada: `complete`→yes, `check_amount`→no (2400≥1000), aterriza en
`manual_approve` → es manual → **aparca**. El estado **sigue siendo
`received`** porque todavía no se ejecutó nada que lo cambiase.

Ahora firma la supervisora:

```harbour
oBoss := BpmTestUser():New( 'supervisora', { 'approver' } )

hRes := oEng:Run( oProc, oBoss, 'manual_approve', { 'id' => 'FAC-B' } )

?  hRes[ 'state' ]  // 'approved'
?  oEng:Get(oProc, 'FAC-B')['data']['approved_by']   // 'supervisora'
```

Y el historial deja huella de que **boss** firmó la factura FAC-B.

**¿Qué pasa si Ana intenta firmarla?**

```harbour
hRes := oEng:Run( oProc, oClerk, 'manual_approve', { 'id' => 'FAC-B' } )

?  hRes[ 'ok' ]     // .F.
?  hRes[ 'error' ]  // 'role not allowed for manual_approve'
```

La regla `roles` lo bloquea. El motor **no toca la instancia**, así
que puedes reintentar con otro usuario sin consecuencias.

### Caso C — Incompleta → `returned`

Aquí hay un detalle: la regla `fields` sobre `receive` nos impediría
llegar al rombo con datos incompletos (`missing field supplier`).
Para ver el camino 'no' del rombo, los tests quitan la regla a
propósito:

```harbour
hb_HDel( oProc:hRules, 'receive' )

hRes := oEng:Run( oProc, oClerk, 'receive',
   { 'id' => 'FAC-C', 'supplier' => '', 'amount' => 75 } )

?  hRes[ 'state' ]     // 'returned'
?  oEng:Get(oProc, 'FAC-C')['data']['notified']   // .T.
```

Cascada: `complete`→'no' (supplier vacío) → `notify_supplier`
(automática) → handler marca `notified=.T.` → estado `returned`.

**Moraleja de este caso**: las reglas de nivel 2 y los rombos
pueden solaparse. Aquí el **rombo** también detecta "incompleta",
pero las reglas lo cortan antes. Es una decisión de diseño: ¿quieres
que el proveedor reciba la notificación (el camino del rombo) o
quieres rechazar la petición de entrada (regla)? Normalmente la
regla es más estricta y se usa para pedir datos limpios al
consumidor; el rombo cubre casos donde los datos no se pueden
limpiar antes.

---

## 5. Las reglas en acción, con casos de borde

Añadiendo también la regla `limit` sobre `receive`:

```harbour
oProc:AddRule( 'receive', 'limit', { 'field' => 'amount', 'max' => 10000 } )
```

Ahora:

| caso                                                 | respuesta                              |
|------------------------------------------------------|----------------------------------------|
| `supplier='ACME', amount=5000`                       | OK, va a `manual_approve`              |
| `supplier='ACME', amount=20000`                      | `limit exceeded on amount` (regla)     |
| `supplier='', amount=50`                             | `missing field supplier` (regla)       |
| `amount=1000` (exacto)                               | OK, va a `manual_approve` (rombo: no)  |
| `amount=999.99`                                       | OK, va a `auto_approve` (rombo: yes)   |

El borde de `check_amount` es **estrictamente menor que 1000**. Si lo
quisieras `<=`, cambiarías el handler. Hay un test que lo garantiza:
`edge: 1000 goes to manual`.

---

## 6. ¿Cómo lo haría tuyo?

Partiendo de este archivo, aquí hay ideas de extensión:

### 6.1 Añadir un camino de "revisión"

Antes de aprobar, un rombo `necesita_revision` que mire si el
`supplier` es nuevo. Si lo es, acción `enviar_a_revision` (manual,
rol `reviewer`) que acabe en el estado `review_ok` que, a su vez,
tenga `SetDecision('review_ok', 'check_amount')`. Encadenas rombos
y estados sin cambiar el motor.

### 6.2 Añadir eventos de auditoría al handler

El handler de `manual_approve` podría grabar en una tabla DBF:

```harbour
oProc:SetHandler( 'manual_approve', {| hCtx |
   hCtx['data']['approved_by'] := hCtx['user']:cName
   DbSelectArea('AUDIT')
   APPEND BLANK
   REPLACE id WITH hCtx['id'], user WITH hCtx['user']:cName, ...
} )
```

El motor no se entera. Para él, el handler sigue siendo una caja
negra.

### 6.3 Añadir una regla "monto mínimo"

Hoy `limit` solo máximo. Si quisieras mínimo, dos opciones:

- *En el handler del rombo*: cambia la lógica de `check_amount` para
  rechazar amounts <0.
- *Extender `CheckRules`*: añadir un tipo `'between'` con
  `{field, min, max}`. Cambio localizado y reutilizable.

### 6.4 Múltiples firmas (dos niveles de aprobación)

Un rombo tras `received` que mira el importe; si es > 10 000, va a
`manual_approve_1` (rol `approver`) y, al pasar, cae en un estado
`half_approved` que tiene su propio rombo o acción `manual_approve_2`
(rol `director`). Dos acciones manuales encadenadas.

---

## 7. Lo que no hace este proceso (y conviene saberlo)

Para que no haya expectativas erróneas:

- **No persiste**. Si reinicias el servidor, se olvida de todas las
  facturas en vuelo.
- **No notifica realmente al proveedor**. El handler solo marca
  `notified=.T.`. Mandar un email es trabajo tuyo.
- **No controla duplicados** más allá del `id` único. Si recibes dos
  facturas distintas del mismo proveedor con `id='FAC-1'` y
  `id='FAC-2'`, para el BPM son dos casos independientes.
- **No permite "cancelar" o "rechazar manualmente"** una vez
  aprobada. Si la quieres, hay que añadir una acción manual que
  salga de `approved` a algún `cancelled`. Nada técnico lo impide.
- **El `amount` se trata como número a secas**. No hay divisa, no
  hay IVA. Son conceptos que viven en `data` y en los handlers que
  tú escribas.

---

## 8. Cheatsheet mental

```
receive(datos) ──► received ──► complete? ──no──► notify_supplier ──► returned
                                   │yes
                                   ▼
                               check_amount? ──yes──► auto_approve ──► approved
                                   │no
                                   ▼
                               manual_approve (manual, rol approver) ──► approved

Reglas:
  receive         requiere fields {supplier, amount}
  manual_approve  requiere rol    {approver}

Datos típicos:
  { id, supplier, amount [, notified, approved_by, comment, ...] }

Usuarios típicos:
  Clerk      aRoles={'clerk'}      puede recibir
  Supervisor aRoles={'approver'}   puede firmar manual_approve
```

Y con eso, `invoice_simple.prg` deja de ser "una fábrica rara" para
convertirse en lo que es: un **catálogo** de piezas (estado,
transición, decisión, acción, handler, regla) encajadas una detrás
de otra en el orden que el diagrama manda.
