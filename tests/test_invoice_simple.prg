/*-----------------------------------------------------------
  File ......: test_invoice_simple.prg
  Description: Test extremo a extremo del proceso de facturas:
               los 3 caminos del diagrama de Charly, nodo a nodo.
               Aislado en hilo; resultado en results/.
 -----------------------------------------------------------*/

#INCLUDE "hbclass.ch"
#INCLUDE "try.ch"

STATIC s_aOk  := {}
STATIC s_aErr := {}

CLASS TestUser

   VAR cName
   VAR aRoles

   METHOD New( cName, aRoles )

ENDCLASS

METHOD New( cName, aRoles ) CLASS TestUser

   ::cName  := cName
   ::aRoles := aRoles

RETURN Self

PROCEDURE ErrorSys

   ErrorBlock( {| oError | Break( oError ) } )

RETURN

FUNCTION Main()

   LOCAL hThread := hb_threadStart( @RunTests() )

   hb_threadJoin( hThread )

   WriteResult( 'test_invoice_simple', s_aOk, s_aErr )

   IF Empty( s_aErr )

      QOut( 'PASS test_invoice_simple (' + hb_ntos( Len( s_aOk ) ) + ' checks)' )

   ELSE

      QOut( 'FAIL test_invoice_simple: ' + s_aErr[ 1 ] )

   ENDIF

RETURN NIL

STATIC PROCEDURE RunTests()

   LOCAL oProc := SimpleInvoiceProcess()
   LOCAL oEng  := BpmEngine():New()
   LOCAL uIn   := TestUser():New( 'recepcion', { 'clerk' } )
   LOCAL uAp   := TestUser():New( 'supervisora', { 'approver' } )
   LOCAL hRes, aHist, oErr

   TRY

      // CAMINO A: factura completa y < 1000 -> aprobada sola
      // Recibir -> Completa? Si -> Monto? Si -> Auto -> Fin approved

      hRes := oEng:Run( oProc, uIn, 'receive', ;
         { 'id' => 'FAC-A', 'supplier' => 'Papelera Sur', 'amount' => 320 } )

      SpecAssert( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'approved', 'A: auto-approved' )
      SpecAssert( oEng:Get( oProc, 'FAC-A' )[ 'data' ][ 'approved_by' ] == 'system', 'A: approved by system' )

      aHist := oEng:History( oProc, 'FAC-A' )
      SpecAssert( aHist[ 1 ][ 'action' ] == 'receive' .AND. aHist[ 1 ][ 'user' ] == 'recepcion', 'A: receive logged with user' )
      SpecAssert( aHist[ 2 ][ 'action' ] == 'auto_approve' .AND. aHist[ 2 ][ 'to' ] == 'approved', 'A: auto_approve logged to approved' )

      // CAMINO B: factura completa y >= 1000 -> espera firma humana
      // Recibir -> Completa? Si -> Monto? No -> Manual -> Fin approved

      hRes := oEng:Run( oProc, uIn, 'receive', ;
         { 'id' => 'FAC-B', 'supplier' => 'Papelera Sur', 'amount' => 2400 } )

      SpecAssert( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'received', 'B: waits in received' )
      SpecAssert( hRes[ 'pending' ] == 'manual_approve', 'B: manual approval pending' )

      hRes := oEng:Run( oProc, uAp, 'manual_approve', { 'id' => 'FAC-B' } )

      SpecAssert( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'approved', 'B: approved by human' )
      SpecAssert( oEng:Get( oProc, 'FAC-B' )[ 'data' ][ 'approved_by' ] == 'supervisora', 'B: approver recorded' )

      // CAMINO C: factura incompleta -> se notifica y se devuelve
      // Recibir -> Completa? No -> Notificar -> Fin returned
      // (sin la regla fields para poder llegar al rombo con datos incompletos)

      hb_HDel( oProc:hRules, 'receive' )

      hRes := oEng:Run( oProc, uIn, 'receive', ;
         { 'id' => 'FAC-C', 'supplier' => '', 'amount' => 75 } )

      SpecAssert( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'returned', 'C: incomplete returned' )
      SpecAssert( oEng:Get( oProc, 'FAC-C' )[ 'data' ][ 'notified' ], 'C: supplier notified' )

      aHist := oEng:History( oProc, 'FAC-C' )
      SpecAssert( aHist[ 2 ][ 'action' ] == 'notify_supplier' .AND. aHist[ 2 ][ 'to' ] == 'returned', 'C: notify logged to returned' )

      // El justo en el borde: 1000 ya NO es < 1000, va a manual

      hRes := oEng:Run( oProc, uIn, 'receive', ;
         { 'id' => 'FAC-D', 'supplier' => 'Papelera Sur', 'amount' => 1000 } )

      SpecAssert( hRes[ 'pending' ] == 'manual_approve', 'edge: 1000 goes to manual' )

      // Tres instancias conviven sin mezclarse

      SpecAssert( oEng:Get( oProc, 'FAC-A' )[ 'state' ] == 'approved' .AND. ;
                  oEng:Get( oProc, 'FAC-B' )[ 'state' ] == 'approved' .AND. ;
                  oEng:Get( oProc, 'FAC-C' )[ 'state' ] == 'returned', 'instances isolated' )

   CATCH oErr

      AAdd( s_aErr, 'ERROR ' + oErr:description )

   END

RETURN

STATIC PROCEDURE SpecAssert( lCond, cLabel )

   IF lCond

      AAdd( s_aOk, cLabel )

   ELSE

      AAdd( s_aErr, cLabel )

   ENDIF

RETURN

STATIC PROCEDURE WriteResult( cName, aOk, aErr )

   LOCAL cText := '# ' + cName + hb_eol() + hb_eol()
   LOCAL cItem

   FOR EACH cItem IN aOk

      cText += '- [x] ' + cItem + hb_eol()

   NEXT

   FOR EACH cItem IN aErr

      cText += '- [ ] FAIL: ' + cItem + hb_eol()

   NEXT

   cText += hb_eol() + iif( Empty( aErr ), '**PASS**', '**FAIL**' ) + hb_eol()

   hb_MemoWrit( 'results/' + cName + '.md', cText )

RETURN
