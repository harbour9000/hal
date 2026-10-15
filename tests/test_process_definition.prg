/*-----------------------------------------------------------
  File ......: test_process_definition.prg
  Description: Test de la clase ProcessDefinition: construccion,
               canon de nombres y Validate() de integridad.
               Aislado en su propio hilo; resultado en results/.
 -----------------------------------------------------------*/

#INCLUDE "hbclass.ch"
#INCLUDE "try.ch"

STATIC s_aOk  := {}
STATIC s_aErr := {}

// Error handler minimo: convierte errores en excepciones capturables
PROCEDURE ErrorSys

   ErrorBlock( {| oError | Break( oError ) } )

RETURN

FUNCTION Main()

   LOCAL hThread := hb_threadStart( @RunTests() )

   // El cuerpo corre en un hilo aparte: su error handler y su
   // estado quedan confinados y no contaminan el proceso

   hb_threadJoin( hThread )

   WriteResult( 'test_process_definition', s_aOk, s_aErr )

   IF Empty( s_aErr )

      QOut( 'PASS test_process_definition (' + hb_ntos( Len( s_aOk ) ) + ' checks)' )

   ELSE

      QOut( 'FAIL test_process_definition: ' + s_aErr[ 1 ] )

   ENDIF

RETURN NIL

STATIC PROCEDURE RunTests()

   LOCAL oProc, hVal, oErr

   TRY

      // Definicion sana: Validate debe pasar

      oProc := SimpleInvoiceProcess()
      hVal  := oProc:Validate()

      SpecAssert( hVal[ 'ok' ], 'invoice definition validates' )

      // Canon: los nombres no dependen del case ni de blancos

      SpecAssert( oProc:IsState( 'RECEIVED' ) .AND. oProc:IsState( ' received ' ), 'state names case/space safe' )
      SpecAssert( oProc:IsAction( 'Auto_Approve' ) .AND. oProc:IsDecision( 'COMPLETE' ), 'action/decision names canon' )
      SpecAssert( ! oProc:IsState( 'approved2' ), 'unknown state refused' )

      // Transicion, rombo y accion quedan registrados

      SpecAssert( oProc:IsTransition( 'receive' ), 'transition registered' )
      SpecAssert( oProc:hTransitions[ 'receive' ][ 'state' ] == 'received', 'transition lands in received' )
      SpecAssert( oProc:hActions[ 'manual_approve' ][ 'manual' ], 'manual flag kept' )
      SpecAssert( ! oProc:hActions[ 'auto_approve' ][ 'manual' ], 'auto flag default' )
      SpecAssert( oProc:hStateDecision[ 'received' ] == 'complete', 'state wired to decision' )
      SpecAssert( oProc:hDecisions[ 'complete' ][ 'yes' ] == 'check_amount', 'branch to decision kept' )

      // Reglas registradas en su nodo

      SpecAssert( hb_HHasKey( oProc:hRules, 'receive' ) .AND. hb_HHasKey( oProc:hRules, 'manual_approve' ), 'rules registered' )

      // Definiciones rotas: Validate debe explicar cada error

      oProc := ProcessDefinition():New( 'broken' )
      oProc:AddState( 'a' )
      oProc:AddTransition( 'go', 'nowhere' )
      hVal := oProc:Validate()
      SpecAssert( ! hVal[ 'ok' ] .AND. 'unknown state' $ hVal[ 'errors' ][ 1 ], 'transition to unknown state' )

      oProc := ProcessDefinition():New( 'broken2' )
      oProc:AddState( 'a' )
      oProc:AddDecision( 'd', { 'yes' => 'ghost' } )
      oProc:SetHandler( 'd', {|| 'yes' } )
      hVal := oProc:Validate()
      SpecAssert( ! hVal[ 'ok' ] .AND. 'unknown target' $ hVal[ 'errors' ][ 1 ], 'branch to unknown target' )

      oProc := ProcessDefinition():New( 'broken3' )
      oProc:AddState( 'a' )
      oProc:AddAction( 'act', 'a' )
      hVal := oProc:Validate()
      SpecAssert( ! hVal[ 'ok' ] .AND. 'missing handler' $ hVal[ 'errors' ][ 1 ], 'action without handler' )

      oProc := ProcessDefinition():New( 'broken4' )
      oProc:AddState( 'a' )
      oProc:SetDecision( 'ghost', 'd' )
      hVal := oProc:Validate()
      SpecAssert( ! hVal[ 'ok' ] .AND. 'unknown state' $ hVal[ 'errors' ][ 1 ], 'setdecision unknown state' )

      oProc := ProcessDefinition():New( 'broken5' )
      oProc:AddState( 'a' )
      oProc:AddRule( 'ghost', 'roles', { 'x' } )
      hVal := oProc:Validate()
      SpecAssert( ! hVal[ 'ok' ] .AND. 'unknown node' $ hVal[ 'errors' ][ 1 ], 'rule on unknown node' )

      // Handler que no es codeblock no se registra

      oProc := ProcessDefinition():New( 'broken6' )
      oProc:AddState( 'a' )
      oProc:AddAction( 'act', 'a' )
      oProc:SetHandler( 'act', 'not a block' )
      hVal := oProc:Validate()
      SpecAssert( ! hVal[ 'ok' ], 'non-block handler refused' )

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

// Un results.md por test, en Markdown
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
