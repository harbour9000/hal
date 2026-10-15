/*-----------------------------------------------------------
  File ......: invoice_simple.prg
  Project....: HIX HAL - BPM generico
  Description: Proceso de facturas de Charly, fiel a su diagrama:

               Recibir factura -> Completa? --No--> Notificar -> Fin
                                     |Si
                                     v
                                 Monto? --No--> Aprobacion manual -> Fin
                                     |Si
                                     v
                                 Aprobacion auto -> Fin

               Nivel 1: el flujo de arriba. Nivel 2: las reglas.
 -----------------------------------------------------------*/

#INCLUDE "hbclass.ch"

// Construye la definicion del proceso, con handlers y reglas
FUNCTION SimpleInvoiceProcess()

   LOCAL oProc

   oProc := ProcessDefinition():New( 'invoice_simple' )

   // Estados (el "Fin" de cada camino)

   oProc:AddState( 'received' )
   oProc:AddState( 'approved' )
   oProc:AddState( 'returned' )

   // Accion inicial: recibir la factura

   oProc:AddTransition( 'receive', 'received' )

   // Rombos: cada camino lleva a una ACCION o a otro rombo

   oProc:AddDecision( 'complete', { ;
      'no'  => 'notify_supplier', ;
      'yes' => 'check_amount' } )

   oProc:AddDecision( 'check_amount', { ;
      'yes' => 'auto_approve', ;
      'no'  => 'manual_approve' } )

   // Acciones: ejecutan y terminan en un estado.
   // manual_approve es manual: el motor espera a que un usuario la lance

   oProc:AddAction( 'notify_supplier', 'returned' )
   oProc:AddAction( 'auto_approve',    'approved' )
   oProc:AddAction( 'manual_approve',  'approved', .T. )

   // Cableado: al caer en 'received' se evalua 'complete'

   oProc:SetDecision( 'received', 'complete' )

   // Handlers de los rombos: reciben los datos, devuelven la etiqueta

   oProc:SetHandler( 'complete', {| hData | ;
      IIf( ! Empty( hb_HGetDef( hData, 'supplier', '' ) ) .AND. ;
           ! Empty( hb_HGetDef( hData, 'amount',   0  ) ), 'yes', 'no' ) } )

   oProc:SetHandler( 'check_amount', {| hData | ;
      IIf( hb_HGetDef( hData, 'amount', 0 ) < 1000, 'yes', 'no' ) } )

   // Handlers de las acciones: reciben el contexto y hacen el trabajo

   oProc:SetHandler( 'notify_supplier', {| hCtx | ;
      hCtx[ 'data' ][ 'notified' ] := .T. } )

   oProc:SetHandler( 'auto_approve', {| hCtx | ;
      hCtx[ 'data' ][ 'approved_by' ] := 'system' } )

   oProc:SetHandler( 'manual_approve', {| hCtx | ;
      hCtx[ 'data' ][ 'approved_by' ] := hCtx[ 'user' ]:cName } )

   // Nivel 2 (reglas): recibir exige datos minimos;
   // la aprobacion manual exige el rol 'approver'

   oProc:AddRule( 'receive', 'fields', { 'supplier', 'amount' } )
   oProc:AddRule( 'manual_approve', 'roles', { 'approver' } )

RETURN oProc
