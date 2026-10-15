/*-----------------------------------------------------------
  File ......: BpmEngine.prg
  Project....: HIX HAL - BPM generico
  Description: Motor generico de procesos. Recibe un ProcessDefinition
               y lo ejecuta: crea instancias, evalua rombos, llama a los
               handlers de las acciones, aplica las reglas de nivel 2 y
               registra el historial de cada instancia.

               Uso: oEng:Run( oProceso, oUsuario, cAccion, hDatos )
               - cAccion = transicion    -> crea la instancia
               - cAccion = accion manual -> la ejecuta si esta pendiente
               hDatos debe traer 'id' para identificar la instancia.
 -----------------------------------------------------------*/

#INCLUDE "hbclass.ch"

#define MAX_STEPS  100   // freno anti-bucles en la cascada

CLASS BpmEngine

   VAR hInstances AS HASH INIT { => }   // clave: proceso|id -> instancia

   METHOD New()
   METHOD Run( oProcess, oUser, cAction, hData )
   METHOD Get( oProcess, cId )
   METHOD History( oProcess, cId )

   HIDDEN:
   METHOD Cascade( oProcess, hInst, hRes )
   METHOD CheckRules( oProcess, cName, oUser, hData )
   METHOD Log( hInst, cUser, cAction, cFrom, cTo )

ENDCLASS

METHOD New() CLASS BpmEngine

RETURN Self

// Punto unico de entrada: avanza el proceso un paso "de usuario"
METHOD Run( oProcess, oUser, cAction, hData ) CLASS BpmEngine

   LOCAL cName := Lower( AllTrim( hb_defaultValue( cAction, '' ) ) )
   LOCAL hRes  := { 'ok' => .T., 'error' => '', 'id' => '', 'state' => '', 'pending' => '', 'executed' => {} }
   LOCAL hValid, hInst, cId, cKey, hDef, hCtx, hRule

   // Validaciones de entrada, de lo general a lo concreto

   IF ValType( oProcess ) != 'O' .OR. ! __ObjHasMsg( oProcess, 'VALIDATE' )

      hRes[ 'ok' ]    := .F.
      hRes[ 'error' ] := 'process is not a ProcessDefinition'

      RETURN hRes

   ENDIF

   hValid := oProcess:Validate()

   IF ! hValid[ 'ok' ]

      hRes[ 'ok' ]    := .F.
      hRes[ 'error' ] := 'invalid process definition: ' + hValid[ 'errors' ][ 1 ]

      RETURN hRes

   ENDIF

   IF ValType( oUser ) != 'O' .OR. ! __ObjHasMsg( oUser, 'CNAME' ) .OR. ! __ObjHasMsg( oUser, 'AROLES' )

      hRes[ 'ok' ]    := .F.
      hRes[ 'error' ] := 'user must expose cName and aRoles'

      RETURN hRes

   ENDIF

   hb_default( @hData, { => } )

   cId := hb_HGetDef( hData, 'id', '' )

   IF Empty( cId )

      hRes[ 'ok' ]    := .F.
      hRes[ 'error' ] := "missing 'id' in data"

      RETURN hRes

   ENDIF

   cKey := oProcess:cName + '|' + cId
   hRes[ 'id' ] := cId

   DO CASE

   CASE oProcess:IsTransition( cName )

      // Una transicion crea la instancia; no puede existir ya

      IF hb_HHasKey( ::hInstances, cKey )

         hRes[ 'ok' ]    := .F.
         hRes[ 'error' ] := 'instance already exists'

         RETURN hRes

      ENDIF

      hRule := ::CheckRules( oProcess, cName, oUser, hData )

      IF ! hRule[ 'ok' ]

         hRule[ 'id' ] := cId
         RETURN hRule

      ENDIF

      hInst := { 'id' => cId, 'process' => oProcess:cName, 'state' => '', ;
                 'data' => hData, 'pending' => '', 'history' => {} }

      hInst[ 'state' ] := oProcess:hTransitions[ cName ][ 'state' ]
      ::hInstances[ cKey ] := hInst
      ::Log( hInst, oUser:cName, cName, '', hInst[ 'state' ] )

   CASE oProcess:IsAction( cName )

      // Una accion manual solo corre si la instancia la tiene pendiente

      IF ! hb_HHasKey( ::hInstances, cKey )

         hRes[ 'ok' ]    := .F.
         hRes[ 'error' ] := 'unknown instance'

         RETURN hRes

      ENDIF

      hInst := ::hInstances[ cKey ]

      IF hInst[ 'pending' ] != cName

         hRes[ 'ok' ]    := .F.
         hRes[ 'error' ] := 'action ' + cName + ' not pending (state ' + hInst[ 'state' ] + ')'

         RETURN hRes

      ENDIF

      hRule := ::CheckRules( oProcess, cName, oUser, hData )

      IF ! hRule[ 'ok' ]

         hRule[ 'id' ] := cId
         RETURN hRule

      ENDIF

      // Los datos nuevos se funden con los de la instancia

      hb_HMerge( hInst[ 'data' ], hData )

      hDef := oProcess:hActions[ cName ]
      hCtx := { 'id' => cId, 'data' => hInst[ 'data' ], 'user' => oUser, 'state' => hInst[ 'state' ] }

      Eval( oProcess:hHandlers[ cName ], hCtx )

      hInst[ 'pending' ] := ''
      ::Log( hInst, oUser:cName, cName, hInst[ 'state' ], hDef[ 'state' ] )
      hInst[ 'state' ] := hDef[ 'state' ]

   OTHERWISE

      hRes[ 'ok' ]    := .F.
      hRes[ 'error' ] := 'unknown action ' + cName

      RETURN hRes

   ENDCASE

   // Cascada automatica: rombos y acciones no manuales hasta parar

   hRes := ::Cascade( oProcess, hInst, hRes )

   hRes[ 'id' ]      := cId
   hRes[ 'state' ]   := hInst[ 'state' ]
   hRes[ 'pending' ] := hInst[ 'pending' ]
   hRes[ 'history' ] := hInst[ 'history' ]

RETURN hRes

// Rombos y acciones automaticas encadenados desde el estado actual
METHOD Cascade( oProcess, hInst, hRes ) CLASS BpmEngine

   LOCAL nSteps := 0
   LOCAL cDecision, hBranch, cLabel, cTarget, hDef, hCtx

   // Mientras el estado actual tenga un rombo cableado, se evalua

   DO WHILE hb_HHasKey( oProcess:hStateDecision, hInst[ 'state' ] )

      IF ++nSteps > MAX_STEPS

         hRes[ 'ok' ]    := .F.
         hRes[ 'error' ] := 'max steps exceeded (loop?)'

         RETURN hRes

      ENDIF

      cDecision := oProcess:hStateDecision[ hInst[ 'state' ] ]

      // Resuelve la cadena de rombos hasta llegar a una accion

      DO WHILE .T.

         IF ++nSteps > MAX_STEPS

            hRes[ 'ok' ]    := .F.
            hRes[ 'error' ] := 'max steps exceeded (loop?)'

            RETURN hRes

         ENDIF

         hBranch := oProcess:hDecisions[ cDecision ]

         // El handler del rombo elige la etiqueta del camino

         cLabel := Lower( AllTrim( hb_defaultValue( Eval( oProcess:hHandlers[ cDecision ], hInst[ 'data' ] ), '' ) ) )

         IF ! hb_HHasKey( hBranch, cLabel )

            hRes[ 'ok' ]    := .F.
            hRes[ 'error' ] := 'decision ' + cDecision + ' returned unknown branch ' + cLabel

            RETURN hRes

         ENDIF

         cTarget := hBranch[ cLabel ]

         IF oProcess:IsDecision( cTarget )

            cDecision := cTarget
            LOOP

         ENDIF

         EXIT

      ENDDO

      hDef := oProcess:hActions[ cTarget ]

      // Accion manual: el motor aparca la instancia y espera al usuario

      IF hDef[ 'manual' ]

         hInst[ 'pending' ] := cTarget
         ::Log( hInst, 'system', 'route', hInst[ 'state' ], 'wait ' + cTarget )
         AAdd( hRes[ 'executed' ], cTarget + ' (pending)' )

         RETURN hRes

      ENDIF

      // Accion automatica: se ejecuta y la instancia cambia de estado

      hCtx := { 'id' => hInst[ 'id' ], 'data' => hInst[ 'data' ], 'user' => NIL, 'state' => hInst[ 'state' ] }

      Eval( oProcess:hHandlers[ cTarget ], hCtx )

      ::Log( hInst, 'system', cTarget, hInst[ 'state' ], hDef[ 'state' ] )
      hInst[ 'state' ] := hDef[ 'state' ]
      AAdd( hRes[ 'executed' ], cTarget )

   ENDDO

RETURN hRes

// Reglas de nivel 2 sobre la accion que pide el usuario
METHOD CheckRules( oProcess, cName, oUser, hData ) CLASS BpmEngine

   LOCAL hRes := { 'ok' => .T., 'error' => '', 'state' => '', 'pending' => '' }
   LOCAL hRules, cField, hLimit, lAllowed, nI, nJ

   IF ! hb_HHasKey( oProcess:hRules, cName )

      RETURN hRes

   ENDIF

   hRules := oProcess:hRules[ cName ]

   // roles: el usuario debe tener al menos uno de los permitidos

   IF hb_HHasKey( hRules, 'roles' )

      lAllowed := .F.

      FOR nI := 1 TO Len( hRules[ 'roles' ] )

         FOR nJ := 1 TO Len( oUser:aRoles )

            IF Lower( oUser:aRoles[ nJ ] ) == Lower( hRules[ 'roles' ][ nI ] )

               lAllowed := .T.

            ENDIF

         NEXT

      NEXT

      IF ! lAllowed

         hRes[ 'ok' ]    := .F.
         hRes[ 'error' ] := 'role not allowed for ' + cName

         RETURN hRes

      ENDIF

   ENDIF

   // fields: todos los campos obligatorios deben venir con valor

   IF hb_HHasKey( hRules, 'fields' )

      FOR EACH cField IN hRules[ 'fields' ]

         IF Empty( hb_HGetDef( hData, cField, NIL ) )

            hRes[ 'ok' ]    := .F.
            hRes[ 'error' ] := 'missing field ' + cField

            RETURN hRes

         ENDIF

      NEXT

   ENDIF

   // limit: un campo numerico no puede superar el maximo

   IF hb_HHasKey( hRules, 'limit' )

      hLimit := hRules[ 'limit' ]

      IF hb_HGetDef( hData, hLimit[ 'field' ], 0 ) > hLimit[ 'max' ]

         hRes[ 'ok' ]    := .F.
         hRes[ 'error' ] := 'limit exceeded on ' + hLimit[ 'field' ]

         RETURN hRes

      ENDIF

   ENDIF

RETURN hRes

// Una linea de historial por movimiento
METHOD Log( hInst, cUser, cAction, cFrom, cTo ) CLASS BpmEngine

   AAdd( hInst[ 'history' ], { 'ts' => hb_TToS( hb_DateTime() ), 'user' => cUser, ;
                               'action' => cAction, 'from' => cFrom, 'to' => cTo } )

RETURN NIL

// Lectura del estado actual de una instancia (NIL si no existe)
METHOD Get( oProcess, cId ) CLASS BpmEngine

RETURN hb_HGetDef( ::hInstances, oProcess:cName + '|' + cId, NIL )

// Historial de una instancia (vacio si no existe)
METHOD History( oProcess, cId ) CLASS BpmEngine

   LOCAL hInst := ::Get( oProcess, cId )

RETURN IF( hInst == NIL, {}, hInst[ 'history' ] )
