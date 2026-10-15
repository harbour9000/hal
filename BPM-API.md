# BPM generico en HAL: API y ejemplo de uso

Dos piezas en `controller/core`:

- **ProcessDefinition** define el proceso. Nivel 1: el dibujo (estados,
  transicion inicial, rombos, acciones). Nivel 2: las reglas (opcional).
- **BpmEngine** lo ejecuta: crea instancias, evalua rombos, llama a los
  handlers, aplica reglas y registra historial.

Regla de fidelidad con el diagrama: los rombos apuntan a ACCIONES (o a
otros rombos) y las acciones terminan siempre en un ESTADO.

## ProcessDefinition

```
oProc := ProcessDefinition():New( 'invoice_simple' )

oProc:AddState( 'received' )                    // un Fin o punto de espera
oProc:AddTransition( 'receive', 'received' )    // accion inicial: crea la instancia

oProc:AddDecision( 'complete', { ;              // rombo: etiqueta -> destino
   'no'  => 'notify_supplier', ;                //   (accion u otro rombo)
   'yes' => 'check_amount' } )

oProc:AddAction( 'notify_supplier', 'returned' )        // automatica
oProc:AddAction( 'manual_approve', 'approved', .T. )    // manual: espera usuario

oProc:SetDecision( 'received', 'complete' )     // al caer en 'received', evalua 'complete'

oProc:SetHandler( 'complete', {| hData | ... 'yes'/'no' } )   // rombo: devuelve etiqueta
oProc:SetHandler( 'notify_supplier', {| hCtx | ... } )        // accion: hace el trabajo

oProc:AddRule( 'receive', 'fields', { 'supplier', 'amount' } )        // nivel 2
oProc:AddRule( 'manual_approve', 'roles', { 'approver' } )
oProc:AddRule( 'receive', 'limit', { 'field' => 'amount', 'max' => 10000 } )

oProc:Validate()  // -> { 'ok' => .T./.F., 'errors' => { ... } }
```

## BpmEngine

```
oEng := BpmEngine():New()

hRes := oEng:Run( oProc, oUsuario, 'receive', ;
   { 'id' => 'FAC-1', 'supplier' => 'ACME', 'amount' => 500 } )
// -> hRes['state'] = 'approved'  (la cascada corrio sola)

hRes := oEng:Run( oProc, oUsuario, 'receive', ;
   { 'id' => 'FAC-2', 'supplier' => 'ACME', 'amount' => 1500 } )
// -> hRes['pending'] = 'manual_approve'  (el motor espera)

hRes := oEng:Run( oProc, oJefa, 'manual_approve', { 'id' => 'FAC-2' } )
// -> hRes['state'] = 'approved'

oEng:Get( oProc, 'FAC-2' )       // instancia completa (estado, datos, historial)
oEng:History( oProc, 'FAC-2' )   // solo el historial
```

`Run` devuelve un hash: `ok`, `error`, `id`, `state`, `pending`,
`executed` (acciones que corrio la cascada) y `history`.

Detalles que conviene saber:

- `hData` siempre lleva `'id'`: es la identidad de la instancia.
- Los datos de llamadas posteriores se funden con los de la instancia.
- El usuario es cualquier objeto con `cName` y `aRoles`.
- Los handlers de accion reciben `hCtx` con `id`, `data`, `user` y
  `state`; `data` es la referencia viva, asi que el handler puede
  escribir en ella (p.ej. `hCtx['data']['approved_by'] := ...`).
- Una accion `manual` aparca la instancia: el historial registra
  `route -> wait <accion>` y solo un `Run` de un usuario con permiso la
  reanuda.
- Si una cascada supera 100 pasos, el motor para con
  `max steps exceeded` (proteccion contra rombos en ciclo).

## Ejemplo completo

`processes/invoice_simple.prg` es el proceso de facturas del diagrama,
nodo a nodo. Los tres caminos, con sus tests en
`tests/test_invoice_simple.prg`:

- completa y < 1000 -> `approved` por `system`
- completa y >= 1000 -> espera firma de un usuario con rol `approver`
- incompleta -> notifica al proveedor y `returned`

## Tests

Ver `tests/results.md`. Cada test es un `.prg` independiente con
TRY/CATCH y ErrorSys, aislado en su propio hilo, y deja su detalle en
`tests/results/`.
