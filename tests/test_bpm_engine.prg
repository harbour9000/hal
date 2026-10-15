/*-----------------------------------------------------------
  File ......: test_bpm_engine.prg
  Description: Test del motor BpmEngine: cascada de rombos, acciones
               automaticas y manuales, reglas de nivel 2, historial
               y errores claros. Aislado en hilo; resultado en results/.
 -----------------------------------------------------------*/

#INCLUDE "hbclass.ch"
#INCLUDE "try.ch"

STATIC s_aOk  := {}
STATIC s_aErr := {}

// Usuario minimo para el motor: cName y aRoles
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

   WriteResult( 'test_bpm_engine', s_aOk, s_aErr )

   IF Empty( s_aErr )

      QOut( 'PASS test_bpm_engine (' + hb_ntos( Len( s_aOk ) ) + ' checks)' )

   ELSE

      QOut( 'FAIL test_bpm_engine: ' + s_aErr[ 1 ] )

   ENDIF

RETURN NIL

STATIC PROCEDURE RunTests()

   LOCAL oProc := SimpleInvoiceProcess()
   LOCAL oEng  := BpmEngine():New()
   LOCAL uAna  := TestUser():New( 'ana', { 'clerk' } )
   LOCAL uBoss := TestUser():New( 'boss', { 'approver' } )
   LOCAL hRes, hInst, oErr, oBad, oLoop

   TRY

      // Camino 1: factura pequena -> aprobacion automatica

      hRes := oEng:Run( oProc, uAna, 'receive', { 'id' => 'F-1', 'supplier' => 'ACME', 'amount' => 500 } )

      SpecAssert( hRes[ 'ok' ], 'receive ok' )
      SpecAssert( hRes[ 'state' ] == 'approved', 'auto path reaches approved' )
      SpecAssert( Empty( hRes[ 'pending' ] ), 'auto path has nothing pending' )
      SpecAssert( Len( hRes[ 'executed' ] ) == 1 .AND. hRes[ 'executed' ][ 1 ] == 'auto_approve', 'auto_approve executed by cascade' )
      SpecAssert( oEng:Get( oProc, 'F-1' )[ 'data' ][ 'approved_by' ] == 'system', 'auto handler ran' )
      SpecAssert( Len( oEng:History( oProc, 'F-1' ) ) == 2, 'history: receive + auto_approve' )

      // Camino 2: factura grande -> el motor espera aprobacion manual

      hRes := oEng:Run( oProc, uAna, 'receive', { 'id' => 'F-2', 'supplier' => 'ACME', 'amount' => 1500 } )

      SpecAssert( hRes[ 'state' ] == 'received', 'manual path waits in received' )
      SpecAssert( hRes[ 'pending' ] == 'manual_approve', 'manual_approve pending' )

      // Sin rol no hay aprobacion

      hRes := oEng:Run( oProc, uAna, 'manual_approve', { 'id' => 'F-2' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'role not allowed' $ hRes[ 'error' ], 'manual approve refused without role' )

      // Con rol: aprueba y queda registrado quien

      hRes := oEng:Run( oProc, uBoss, 'manual_approve', { 'id' => 'F-2' } )
      SpecAssert( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'approved', 'manual approve with role' )
      SpecAssert( oEng:Get( oProc, 'F-2' )[ 'data' ][ 'approved_by' ] == 'boss', 'manual handler ran with user' )
      SpecAssert( Empty( hRes[ 'pending' ] ), 'pending cleared after manual approve' )

      // Repetir la misma accion ya no vale: no esta pendiente

      hRes := oEng:Run( oProc, uBoss, 'manual_approve', { 'id' => 'F-2' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'not pending' $ hRes[ 'error' ], 'repeated manual approve is a clear no-op error' )

      // Camino 3: factura incompleta -> notificar y devolver

      hRes := oEng:Run( oProc, uAna, 'receive', { 'id' => 'F-3', 'supplier' => '', 'amount' => 0 } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'missing field' $ hRes[ 'error' ], 'receive without fields refused by rule' )

      // La regla 'fields' mira los datos de la llamada; con amount 0 y supplier vacio no pasa.
      // Para probar el camino 'no' del rombo usamos datos que SI pasan la regla
      // pero el handler de complete considera incompletos: amount sin supplier no llega,
      // asi que probamos el rombo con una definicion sin la regla fields

      oBad := SimpleInvoiceProcess()
      hRes := oEng:Run( oBad, uAna, 'receive', { 'id' => 'F-4', 'supplier' => 'ACME', 'amount' => 10 } )
      SpecAssert( hRes[ 'ok' ], 'second instance independent' )

      // Factura devuelta: quitamos la regla fields en una copia para llegar al rombo

      oBad := SimpleInvoiceProcess()
      hb_HDel( oBad:hRules, 'receive' )
      hRes := oEng:Run( oBad, uAna, 'receive', { 'id' => 'F-5', 'supplier' => '', 'amount' => 100 } )
      SpecAssert( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'returned', 'incomplete invoice returned' )
      SpecAssert( oEng:Get( oBad, 'F-5' )[ 'data' ][ 'notified' ], 'supplier notified by handler' )

      // Errores claros de uso

      hRes := oEng:Run( oProc, uAna, 'receive', { 'supplier' => 'ACME', 'amount' => 1 } )
      SpecAssert( ! hRes[ 'ok' ] .AND. "'id'" $ hRes[ 'error' ], 'missing id refused' )

      hRes := oEng:Run( oProc, uAna, 'receive', { 'id' => 'F-1', 'supplier' => 'ACME', 'amount' => 1 } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'already exists' $ hRes[ 'error' ], 'duplicate instance refused' )

      hRes := oEng:Run( oProc, uAna, 'fly', { 'id' => 'F-9' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'unknown action' $ hRes[ 'error' ], 'unknown action refused' )

      hRes := oEng:Run( oProc, uBoss, 'manual_approve', { 'id' => 'F-9' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'unknown instance' $ hRes[ 'error' ], 'unknown instance refused' )

      hRes := oEng:Run( oProc, 'not a user', 'receive', { 'id' => 'F-9' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'cName' $ hRes[ 'error' ], 'bad user refused' )

      hRes := oEng:Run( 'not a process', uAna, 'receive', { 'id' => 'F-9' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'ProcessDefinition' $ hRes[ 'error' ], 'bad process refused' )

      // Definicion invalida: el motor no la ejecuta

      oBad := ProcessDefinition():New( 'inv' )
      oBad:AddTransition( 'go', 'nowhere' )
      hRes := oEng:Run( oBad, uAna, 'go', { 'id' => 'X' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'invalid process definition' $ hRes[ 'error' ], 'invalid definition refused' )

      // Rombo que devuelve una etiqueta inexistente: error claro

      oBad := ProcessDefinition():New( 'badlabel' )
      oBad:AddState( 's1' ) ; oBad:AddState( 's2' )
      oBad:AddTransition( 'go', 's1' )
      oBad:AddDecision( 'd', { 'yes' => 'act' } )
      oBad:AddAction( 'act', 's2' )
      oBad:SetHandler( 'act', {|| NIL } )
      oBad:SetHandler( 'd', {|| 'maybe' } )
      oBad:SetDecision( 's1', 'd' )
      hRes := oEng:Run( oBad, uAna, 'go', { 'id' => 'B-1' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'unknown branch' $ hRes[ 'error' ], 'decision with unknown branch refused' )

      // Dos rombos apuntandose en ciclo: el freno anti-bucles salta

      oLoop := ProcessDefinition():New( 'loop' )
      oLoop:AddState( 's1' ) ; oLoop:AddState( 's2' )
      oLoop:AddTransition( 'go', 's1' )
      oLoop:AddDecision( 'd1', { 'yes' => 'd2' } )
      oLoop:AddDecision( 'd2', { 'yes' => 'd1' } )
      oLoop:AddAction( 'never', 's2' )
      oLoop:SetHandler( 'never', {|| NIL } )
      oLoop:SetHandler( 'd1', {|| 'yes' } )
      oLoop:SetHandler( 'd2', {|| 'yes' } )
      oLoop:SetDecision( 's1', 'd1' )
      hRes := oEng:Run( oLoop, uAna, 'go', { 'id' => 'L-1' } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'max steps' $ hRes[ 'error' ], 'decision loop stopped by guard' )

      // Regla de limite sobre la transicion

      oBad := SimpleInvoiceProcess()
      oBad:AddRule( 'receive', 'limit', { 'field' => 'amount', 'max' => 10000 } )
      hRes := oEng:Run( oBad, uAna, 'receive', { 'id' => 'F-6', 'supplier' => 'ACME', 'amount' => 20000 } )
      SpecAssert( ! hRes[ 'ok' ] .AND. 'limit exceeded' $ hRes[ 'error' ], 'limit rule on receive' )

      // Lectura de instancias inexistentes

      SpecAssert( oEng:Get( oProc, 'NOPE' ) == NIL, 'get unknown returns NIL' )
      SpecAssert( Empty( oEng:History( oProc, 'NOPE' ) ), 'history unknown returns empty' )

      hInst := oEng:Get( oProc, 'F-2' )
      SpecAssert( Len( hInst[ 'history' ] ) == 3, 'F-2 history: receive + route + manual_approve' )

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
