/*-----------------------------------------------------------
  File ......: test.prg
  Project....: HIX HAL - BPM generico
  Description: Tests del BPM en el modulo main. Las suites que antes
               vivian sueltas en /tests ahora se definen aqui y se
               lanzan desde la pantalla (boton Test de main.html).

               GET /test?name=invoice_simple|engine|definition|all

               Devuelve JSON: { 'name', 'ok', 'pass', 'fail',
               'lines' => { { 'kind' => ..., 'text' => ... }, ... } }
               Las lineas narran lo que el test va haciendo para
               pintarse en la consola de la pantalla.

               Aislamiento: HIX recompila el controlador en cada
               peticion (HRB fresco), y ademas los acumuladores son
               THREAD STATIC: dos requests simultaneos jamas se
               pisan las lineas ni los contadores.
 -----------------------------------------------------------*/

#INCLUDE "hbclass.ch"

// Acumuladores de la suite en curso. THREAD STATIC = una copia por
// hilo: aunque HIX cacheara algun dia el HRB del controlador, dos
// requests en paralelo seguirian sin compartir estado.
THREAD STATIC s_aLines := {}
THREAD STATIC s_nPass  := 0
THREAD STATIC s_nFail  := 0

// OJO: FUNCTION Main va la primera en el archivo. HIX ejecuta el
// primer simbolo publico del HRB; si la clase va antes, su New()
// se ejecutaria como entrada y la ruta devolveria "** object **".

// Punto de entrada HTTP
FUNCTION Main()

   LOCAL cName := Lower( AllTrim( UGet( 'name', 'invoice_simple' ) ) )
   LOCAL aSuites := {}
   LOCAL hRes, hSuite, hLine

   DO CASE

   CASE cName == 'invoice_simple'

      AAdd( aSuites, TestBpm_InvoiceSimple() )

   CASE cName == 'engine'

      AAdd( aSuites, TestBpm_Engine() )

   CASE cName == 'definition'

      AAdd( aSuites, TestBpm_Definition() )

   CASE cName == 'all'

      AAdd( aSuites, TestBpm_Definition() )
      AAdd( aSuites, TestBpm_Engine() )
      AAdd( aSuites, TestBpm_InvoiceSimple() )

   OTHERWISE

      RETURN USendJson( { 'ok' => .F., 'error' => 'unknown test ' + cName }, 404 )

   ENDCASE

   // Resumen conjunto (para 'all': agrega las suites)

   hRes := { 'name' => cName, 'ok' => .T., 'pass' => 0, 'fail' => 0, 'lines' => {} }

   FOR EACH hSuite IN aSuites

      hRes[ 'ok' ]   := hRes[ 'ok' ] .AND. hSuite[ 'ok' ]
      hRes[ 'pass' ] += hSuite[ 'pass' ]
      hRes[ 'fail' ] += hSuite[ 'fail' ]

      // Cabecera de la suite: la consola la pinta con color propio
      AAdd( hRes[ 'lines' ], { 'kind' => 'suite', ;
         'text' => '== suite ' + hSuite[ 'name' ] + ': ' + hb_ntos( hSuite[ 'pass' ] ) + ;
            iif( hSuite[ 'fail' ] == 0, ' checks OK', ' checks, ' + hb_ntos( hSuite[ 'fail' ] ) + ' FALLOS' ) + ' ==' } )

      FOR EACH hLine IN hSuite[ 'lines' ]

         AAdd( hRes[ 'lines' ], hLine )

      NEXT

   NEXT

RETURN USendJson( hRes )


// Usuario minimo para el motor: cName y aRoles
CLASS BpmTestUser

   VAR cName
   VAR aRoles

   METHOD New( cName, aRoles )

ENDCLASS

METHOD New( cName, aRoles ) CLASS BpmTestUser

   ::cName  := cName
   ::aRoles := aRoles

RETURN Self

// ---------------------------------------------------------------
// Utilidades de las suites
// ---------------------------------------------------------------

STATIC PROCEDURE TReset()

   s_aLines := {}
   s_nPass  := 0
   s_nFail  := 0

RETURN

// Linea narrativa para la consola
STATIC PROCEDURE TLine( cKind, cText )

   AAdd( s_aLines, { 'kind' => cKind, 'text' => cText } )

RETURN

// Comprobacion: suma pass/fail y deja linea verde o roja
STATIC PROCEDURE TCheck( lCond, cLabel )

   IF lCond

      s_nPass++
      TLine( 'ok', 'PASS ' + cLabel )

   ELSE

      s_nFail++
      TLine( 'err', 'FAIL ' + cLabel )

   ENDIF

RETURN

STATIC FUNCTION TResult( cName )

   TLine( iif( s_nFail == 0, 'ok', 'err' ), ;
          cName + ': ' + hb_ntos( s_nPass ) + ' checks OK, ' + hb_ntos( s_nFail ) + ' fallos' )

RETURN { 'name' => cName, 'ok' => s_nFail == 0, 'pass' => s_nPass, 'fail' => s_nFail, 'lines' => s_aLines }

// ---------------------------------------------------------------
// Suite 1: el proceso de facturas, camino a camino
// ---------------------------------------------------------------

STATIC FUNCTION TestBpm_InvoiceSimple()

   LOCAL oErr
   LOCAL oProc, oEng, uIn, uAp, hRes, aHist

   TReset()
   TLine( 'sys', '--- test invoice_simple: los 3 caminos del diagrama ---' )

   TRY

      oProc := SimpleInvoiceProcess()
      oEng  := BpmEngine():New()
      uIn   := BpmTestUser():New( 'recepcion', { 'clerk' } )
      uAp   := BpmTestUser():New( 'supervisora', { 'approver' } )

      TLine( 'sys', 'proceso invoice_simple construido y validado: ' + iif( oProc:Validate()[ 'ok' ], 'OK', 'ERROR' ) )

      // CAMINO A: completa y < 1000 -> se aprueba sola

      TLine( 'user', "> Run receive FAC-A (Papelera Sur, 320)" )

      hRes := oEng:Run( oProc, uIn, 'receive', ;
         { 'id' => 'FAC-A', 'supplier' => 'Papelera Sur', 'amount' => 320 } )

      TLine( 'sys', 'rombo complete -> yes, rombo check_amount -> yes' )
      TLine( 'sys', 'accion auto_approve -> estado ' + hRes[ 'state' ] )

      TCheck( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'approved', 'A: auto-approved' )
      TCheck( oEng:Get( oProc, 'FAC-A' )[ 'data' ][ 'approved_by' ] == 'system', 'A: approved by system' )

      aHist := oEng:History( oProc, 'FAC-A' )
      TCheck( aHist[ 1 ][ 'action' ] == 'receive' .AND. aHist[ 1 ][ 'user' ] == 'recepcion', 'A: receive logged with user' )
      TCheck( aHist[ 2 ][ 'action' ] == 'auto_approve' .AND. aHist[ 2 ][ 'to' ] == 'approved', 'A: auto_approve logged to approved' )

      // CAMINO B: completa y >= 1000 -> espera firma humana

      TLine( 'user', "> Run receive FAC-B (Papelera Sur, 2400)" )

      hRes := oEng:Run( oProc, uIn, 'receive', ;
         { 'id' => 'FAC-B', 'supplier' => 'Papelera Sur', 'amount' => 2400 } )

      TLine( 'sys', 'rombo complete -> yes, rombo check_amount -> no' )
      TLine( 'sys', 'accion manual_approve es manual: el motor espera (pending)' )

      TCheck( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'received', 'B: waits in received' )
      TCheck( hRes[ 'pending' ] == 'manual_approve', 'B: manual approval pending' )

      TLine( 'user', "> Run manual_approve FAC-B (supervisora)" )

      hRes := oEng:Run( oProc, uAp, 'manual_approve', { 'id' => 'FAC-B' } )

      TLine( 'sys', 'accion manual_approve -> estado ' + hRes[ 'state' ] )

      TCheck( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'approved', 'B: approved by human' )
      TCheck( oEng:Get( oProc, 'FAC-B' )[ 'data' ][ 'approved_by' ] == 'supervisora', 'B: approver recorded' )

      // CAMINO C: incompleta -> notifica y se devuelve
      // (sin la regla fields para poder llegar al rombo con datos incompletos)

      hb_HDel( oProc:hRules, 'receive' )

      TLine( 'user', "> Run receive FAC-C (sin supplier, 75)" )

      hRes := oEng:Run( oProc, uIn, 'receive', ;
         { 'id' => 'FAC-C', 'supplier' => '', 'amount' => 75 } )

      TLine( 'sys', 'rombo complete -> no, accion notify_supplier -> estado ' + hRes[ 'state' ] )

      TCheck( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'returned', 'C: incomplete returned' )
      TCheck( oEng:Get( oProc, 'FAC-C' )[ 'data' ][ 'notified' ], 'C: supplier notified' )

      aHist := oEng:History( oProc, 'FAC-C' )
      TCheck( aHist[ 2 ][ 'action' ] == 'notify_supplier' .AND. aHist[ 2 ][ 'to' ] == 'returned', 'C: notify logged to returned' )

      // El borde: 1000 exactos ya NO es < 1000, va a manual

      TLine( 'user', "> Run receive FAC-D (Papelera Sur, 1000)" )

      hRes := oEng:Run( oProc, uIn, 'receive', ;
         { 'id' => 'FAC-D', 'supplier' => 'Papelera Sur', 'amount' => 1000 } )

      TLine( 'sys', 'rombo check_amount con 1000 -> no (manual)' )

      TCheck( hRes[ 'pending' ] == 'manual_approve', 'edge: 1000 goes to manual' )

      // Las instancias conviven sin mezclarse

      TCheck( oEng:Get( oProc, 'FAC-A' )[ 'state' ] == 'approved' .AND. ;
              oEng:Get( oProc, 'FAC-B' )[ 'state' ] == 'approved' .AND. ;
              oEng:Get( oProc, 'FAC-C' )[ 'state' ] == 'returned', 'instances isolated' )

   CATCH oErr

      TLine( 'err', 'ERROR ' + oErr:description )
      s_nFail++

   END

RETURN TResult( 'invoice_simple' )

// ---------------------------------------------------------------
// Suite 2: el motor (cascada, reglas, errores, historial)
// ---------------------------------------------------------------

STATIC FUNCTION TestBpm_Engine()

   LOCAL oErr
   LOCAL oProc, oEng, uAna, uBoss, hRes, oBad, oLoop

   TReset()
   TLine( 'sys', '--- test bpm_engine: motor, reglas y errores ---' )

   TRY

      oProc := SimpleInvoiceProcess()
      oEng  := BpmEngine():New()
      uAna  := BpmTestUser():New( 'ana', { 'clerk' } )
      uBoss := BpmTestUser():New( 'boss', { 'approver' } )

      TLine( 'user', "> Run receive F-1 (500) -> cascada automatica" )

      hRes := oEng:Run( oProc, uAna, 'receive', { 'id' => 'F-1', 'supplier' => 'ACME', 'amount' => 500 } )

      TCheck( hRes[ 'ok' ], 'receive ok' )
      TCheck( hRes[ 'state' ] == 'approved', 'auto path reaches approved' )
      TCheck( Empty( hRes[ 'pending' ] ), 'auto path has nothing pending' )
      TCheck( Len( hRes[ 'executed' ] ) == 1 .AND. hRes[ 'executed' ][ 1 ] == 'auto_approve', 'auto_approve executed by cascade' )
      TCheck( oEng:Get( oProc, 'F-1' )[ 'data' ][ 'approved_by' ] == 'system', 'auto handler ran' )
      TCheck( Len( oEng:History( oProc, 'F-1' ) ) == 2, 'history: receive + auto_approve' )

      TLine( 'user', "> Run receive F-2 (1500) -> espera manual" )

      hRes := oEng:Run( oProc, uAna, 'receive', { 'id' => 'F-2', 'supplier' => 'ACME', 'amount' => 1500 } )

      TCheck( hRes[ 'state' ] == 'received', 'manual path waits in received' )
      TCheck( hRes[ 'pending' ] == 'manual_approve', 'manual_approve pending' )

      TLine( 'user', "> Run manual_approve F-2 SIN rol -> rechazo" )

      hRes := oEng:Run( oProc, uAna, 'manual_approve', { 'id' => 'F-2' } )

      TLine( 'sys', 'motor responde: ' + hRes[ 'error' ] )
      TCheck( ! hRes[ 'ok' ] .AND. 'role not allowed' $ hRes[ 'error' ], 'manual approve refused without role' )

      TLine( 'user', "> Run manual_approve F-2 con rol approver" )

      hRes := oEng:Run( oProc, uBoss, 'manual_approve', { 'id' => 'F-2' } )

      TCheck( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'approved', 'manual approve with role' )
      TCheck( oEng:Get( oProc, 'F-2' )[ 'data' ][ 'approved_by' ] == 'boss', 'manual handler ran with user' )
      TCheck( Empty( hRes[ 'pending' ] ), 'pending cleared after manual approve' )

      TLine( 'user', "> repetir manual_approve F-2 -> error claro" )

      hRes := oEng:Run( oProc, uBoss, 'manual_approve', { 'id' => 'F-2' } )

      TLine( 'sys', 'motor responde: ' + hRes[ 'error' ] )
      TCheck( ! hRes[ 'ok' ] .AND. 'not pending' $ hRes[ 'error' ], 'repeated manual approve is a clear no-op error' )

      TLine( 'user', "> receive sin campos obligatorios -> regla fields" )

      hRes := oEng:Run( oProc, uAna, 'receive', { 'id' => 'F-3', 'supplier' => '', 'amount' => 0 } )

      TLine( 'sys', 'motor responde: ' + hRes[ 'error' ] )
      TCheck( ! hRes[ 'ok' ] .AND. 'missing field' $ hRes[ 'error' ], 'receive without fields refused by rule' )

      TLine( 'user', "> otra instancia y camino 'no' del rombo (definicion sin regla fields)" )

      oBad := SimpleInvoiceProcess()
      hRes := oEng:Run( oBad, uAna, 'receive', { 'id' => 'F-4', 'supplier' => 'ACME', 'amount' => 10 } )
      TCheck( hRes[ 'ok' ], 'second instance independent' )

      hb_HDel( oBad:hRules, 'receive' )
      hRes := oEng:Run( oBad, uAna, 'receive', { 'id' => 'F-5', 'supplier' => '', 'amount' => 100 } )
      TCheck( hRes[ 'ok' ] .AND. hRes[ 'state' ] == 'returned', 'incomplete invoice returned' )
      TCheck( oEng:Get( oBad, 'F-5' )[ 'data' ][ 'notified' ], 'supplier notified by handler' )

      TLine( 'user', "> errores de uso: sin id, duplicado, accion desconocida" )

      hRes := oEng:Run( oProc, uAna, 'receive', { 'supplier' => 'ACME', 'amount' => 1 } )
      TCheck( ! hRes[ 'ok' ] .AND. "'id'" $ hRes[ 'error' ], 'missing id refused' )

      hRes := oEng:Run( oProc, uAna, 'receive', { 'id' => 'F-1', 'supplier' => 'ACME', 'amount' => 1 } )
      TCheck( ! hRes[ 'ok' ] .AND. 'already exists' $ hRes[ 'error' ], 'duplicate instance refused' )

      hRes := oEng:Run( oProc, uAna, 'fly', { 'id' => 'F-9' } )
      TCheck( ! hRes[ 'ok' ] .AND. 'unknown action' $ hRes[ 'error' ], 'unknown action refused' )

      hRes := oEng:Run( oProc, uBoss, 'manual_approve', { 'id' => 'F-9' } )
      TCheck( ! hRes[ 'ok' ] .AND. 'unknown instance' $ hRes[ 'error' ], 'unknown instance refused' )

      hRes := oEng:Run( oProc, 'not a user', 'receive', { 'id' => 'F-9' } )
      TCheck( ! hRes[ 'ok' ] .AND. 'cName' $ hRes[ 'error' ], 'bad user refused' )

      hRes := oEng:Run( 'not a process', uAna, 'receive', { 'id' => 'F-9' } )
      TCheck( ! hRes[ 'ok' ] .AND. 'ProcessDefinition' $ hRes[ 'error' ], 'bad process refused' )

      oBad := ProcessDefinition():New( 'inv' )
      oBad:AddTransition( 'go', 'nowhere' )
      hRes := oEng:Run( oBad, uAna, 'go', { 'id' => 'X' } )
      TCheck( ! hRes[ 'ok' ] .AND. 'invalid process definition' $ hRes[ 'error' ], 'invalid definition refused' )

      TLine( 'user', "> rombo que devuelve etiqueta inexistente" )

      oBad := ProcessDefinition():New( 'badlabel' )
      oBad:AddState( 's1' ) ; oBad:AddState( 's2' )
      oBad:AddTransition( 'go', 's1' )
      oBad:AddDecision( 'd', { 'yes' => 'act' } )
      oBad:AddAction( 'act', 's2' )
      oBad:SetHandler( 'act', {|| NIL } )
      oBad:SetHandler( 'd', {|| 'maybe' } )
      oBad:SetDecision( 's1', 'd' )

      hRes := oEng:Run( oBad, uAna, 'go', { 'id' => 'B-1' } )

      TLine( 'sys', 'motor responde: ' + hRes[ 'error' ] )
      TCheck( ! hRes[ 'ok' ] .AND. 'unknown branch' $ hRes[ 'error' ], 'decision with unknown branch refused' )

      TLine( 'user', "> dos rombos en ciclo -> freno anti-bucles" )

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

      TLine( 'sys', 'motor responde: ' + hRes[ 'error' ] )
      TCheck( ! hRes[ 'ok' ] .AND. 'max steps' $ hRes[ 'error' ], 'decision loop stopped by guard' )

      TLine( 'user', "> regla limit en receive (max 10000)" )

      oBad := SimpleInvoiceProcess()
      oBad:AddRule( 'receive', 'limit', { 'field' => 'amount', 'max' => 10000 } )

      hRes := oEng:Run( oBad, uAna, 'receive', { 'id' => 'F-6', 'supplier' => 'ACME', 'amount' => 20000 } )

      TLine( 'sys', 'motor responde: ' + hRes[ 'error' ] )
      TCheck( ! hRes[ 'ok' ] .AND. 'limit exceeded' $ hRes[ 'error' ], 'limit rule on receive' )

      TCheck( oEng:Get( oProc, 'NOPE' ) == NIL, 'get unknown returns NIL' )
      TCheck( Empty( oEng:History( oProc, 'NOPE' ) ), 'history unknown returns empty' )

      TCheck( Len( oEng:Get( oProc, 'F-2' )[ 'history' ] ) == 3, 'F-2 history: receive + route + manual_approve' )

   CATCH oErr

      TLine( 'err', 'ERROR ' + oErr:description )
      s_nFail++

   END

RETURN TResult( 'bpm_engine' )

// ---------------------------------------------------------------
// Suite 3: la definicion (construccion y Validate)
// ---------------------------------------------------------------

STATIC FUNCTION TestBpm_Definition()

   LOCAL oErr
   LOCAL oProc, hVal

   TReset()
   TLine( 'sys', '--- test process_definition: construccion y Validate ---' )

   TRY

      oProc := SimpleInvoiceProcess()
      hVal  := oProc:Validate()

      TCheck( hVal[ 'ok' ], 'invoice definition validates' )
      TCheck( oProc:IsState( 'RECEIVED' ) .AND. oProc:IsState( ' received ' ), 'state names case/space safe' )
      TCheck( oProc:IsAction( 'Auto_Approve' ) .AND. oProc:IsDecision( 'COMPLETE' ), 'action/decision names canon' )
      TCheck( ! oProc:IsState( 'approved2' ), 'unknown state refused' )
      TCheck( oProc:IsTransition( 'receive' ), 'transition registered' )
      TCheck( oProc:hTransitions[ 'receive' ][ 'state' ] == 'received', 'transition lands in received' )
      TCheck( oProc:hActions[ 'manual_approve' ][ 'manual' ], 'manual flag kept' )
      TCheck( ! oProc:hActions[ 'auto_approve' ][ 'manual' ], 'auto flag default' )
      TCheck( oProc:hStateDecision[ 'received' ] == 'complete', 'state wired to decision' )
      TCheck( oProc:hDecisions[ 'complete' ][ 'yes' ] == 'check_amount', 'branch to decision kept' )
      TCheck( hb_HHasKey( oProc:hRules, 'receive' ) .AND. hb_HHasKey( oProc:hRules, 'manual_approve' ), 'rules registered' )

      TLine( 'user', '> definiciones rotas: Validate explica cada error' )

      oProc := ProcessDefinition():New( 'broken' )
      oProc:AddState( 'a' )
      oProc:AddTransition( 'go', 'nowhere' )
      hVal := oProc:Validate()
      TLine( 'sys', hVal[ 'errors' ][ 1 ] )
      TCheck( ! hVal[ 'ok' ] .AND. 'unknown state' $ hVal[ 'errors' ][ 1 ], 'transition to unknown state' )

      oProc := ProcessDefinition():New( 'broken2' )
      oProc:AddState( 'a' )
      oProc:AddDecision( 'd', { 'yes' => 'ghost' } )
      oProc:SetHandler( 'd', {|| 'yes' } )
      hVal := oProc:Validate()
      TLine( 'sys', hVal[ 'errors' ][ 1 ] )
      TCheck( ! hVal[ 'ok' ] .AND. 'unknown target' $ hVal[ 'errors' ][ 1 ], 'branch to unknown target' )

      oProc := ProcessDefinition():New( 'broken3' )
      oProc:AddState( 'a' )
      oProc:AddAction( 'act', 'a' )
      hVal := oProc:Validate()
      TLine( 'sys', hVal[ 'errors' ][ 1 ] )
      TCheck( ! hVal[ 'ok' ] .AND. 'missing handler' $ hVal[ 'errors' ][ 1 ], 'action without handler' )

      oProc := ProcessDefinition():New( 'broken4' )
      oProc:AddState( 'a' )
      oProc:SetDecision( 'ghost', 'd' )
      hVal := oProc:Validate()
      TLine( 'sys', hVal[ 'errors' ][ 1 ] )
      TCheck( ! hVal[ 'ok' ] .AND. 'unknown state' $ hVal[ 'errors' ][ 1 ], 'setdecision unknown state' )

      oProc := ProcessDefinition():New( 'broken5' )
      oProc:AddState( 'a' )
      oProc:AddRule( 'ghost', 'roles', { 'x' } )
      hVal := oProc:Validate()
      TLine( 'sys', hVal[ 'errors' ][ 1 ] )
      TCheck( ! hVal[ 'ok' ] .AND. 'unknown node' $ hVal[ 'errors' ][ 1 ], 'rule on unknown node' )

      oProc := ProcessDefinition():New( 'broken6' )
      oProc:AddState( 'a' )
      oProc:AddAction( 'act', 'a' )
      oProc:SetHandler( 'act', 'not a block' )
      hVal := oProc:Validate()
      TCheck( ! hVal[ 'ok' ], 'non-block handler refused' )

   CATCH oErr

      TLine( 'err', 'ERROR ' + oErr:description )
      s_nFail++

   END

RETURN TResult( 'process_definition' )
