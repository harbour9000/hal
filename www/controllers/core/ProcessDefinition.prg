/*-----------------------------------------------------------
  File ......: ProcessDefinition.prg
  Project....: HIX HAL - BPM generico
  Description: Definicion de un proceso de negocio en dos niveles.

               Nivel 1 (el dibujo): estados, transiciones, decisiones
               (rombos) y acciones. Los rombos apuntan a ACCIONES o a
               otros rombos; las acciones terminan siempre en un ESTADO.

               Nivel 2 (las reglas, opcional): roles, campos
               obligatorios y limites sobre las acciones.

               Esta clase solo DEFINE. Quien ejecuta es BpmEngine.
 -----------------------------------------------------------*/

#INCLUDE "hbclass.ch"

// Tipos de regla soportados en el nivel 2
#define RULE_ROLES   'roles'    // array de roles permitidos
#define RULE_FIELDS  'fields'   // array de campos obligatorios en los datos
#define RULE_LIMIT   'limit'    // hash { 'field' => cCampo, 'max' => nMax }

CLASS ProcessDefinition

   VAR cName          AS STRING   INIT ''
   VAR aStates        AS ARRAY    INIT {}
   VAR hTransitions   AS HASH     INIT { => }
   VAR hDecisions     AS HASH     INIT { => }
   VAR hActions       AS HASH     INIT { => }
   VAR hStateDecision AS HASH     INIT { => }
   VAR hHandlers      AS HASH     INIT { => }
   VAR hRules         AS HASH     INIT { => }

   METHOD New( cName )

   METHOD AddState( cState )
   METHOD AddTransition( cName, cToState )
   METHOD AddDecision( cName, hBranches )
   METHOD AddAction( cName, cToState, lManual )
   METHOD SetDecision( cState, cDecision )
   METHOD SetHandler( cName, bBlock )
   METHOD AddRule( cName, cType, xValue )

   METHOD IsState( cName )
   METHOD IsTransition( cName )
   METHOD IsDecision( cName )
   METHOD IsAction( cName )

   METHOD Validate()

ENDCLASS

// Clave canonica: minusculas y sin blancos, para no depender del case
STATIC FUNCTION Canon( cName )

   LOCAL cKey := ''

   IF ValType( cName ) == 'C'

      cKey := Lower( AllTrim( cName ) )

   ENDIF

RETURN cKey

METHOD New( cName ) CLASS ProcessDefinition

   ::cName := Canon( cName )

RETURN Self

// Un estado es un "Fin" o punto de espera del dibujo
METHOD AddState( cState ) CLASS ProcessDefinition

   LOCAL cKey := Canon( cState )

   IF ! Empty( cKey ) .AND. ! ::IsState( cKey )

      AAdd( ::aStates, cKey )

   ENDIF

RETURN Self

// Transicion: accion inicial que crea la instancia y la deja en un estado
METHOD AddTransition( cName, cToState ) CLASS ProcessDefinition

   ::hTransitions[ Canon( cName ) ] := { 'state' => Canon( cToState ) }

RETURN Self

// Decision (rombo): cada etiqueta apunta a una accion o a otra decision
METHOD AddDecision( cName, hBranches ) CLASS ProcessDefinition

   LOCAL hNorm := { => }
   LOCAL cLabel

   FOR EACH cLabel IN hb_HKeys( hBranches )

      hNorm[ Canon( cLabel ) ] := Canon( hBranches[ cLabel ] )

   NEXT

   ::hDecisions[ Canon( cName ) ] := hNorm

RETURN Self

// Accion: ejecuta un handler y termina en un estado.
// lManual = .T. -> el motor para y espera a que un usuario la lance
METHOD AddAction( cName, cToState, lManual ) CLASS ProcessDefinition

   ::hActions[ Canon( cName ) ] := { 'state' => Canon( cToState ), 'manual' => hb_defaultValue( lManual, .F. ) }

RETURN Self

// Cableado: al caer en cState, el motor evalua cDecision
METHOD SetDecision( cState, cDecision ) CLASS ProcessDefinition

   ::hStateDecision[ Canon( cState ) ] := Canon( cDecision )

RETURN Self

// Un mismo registro sirve para acciones y decisiones:
// - accion:   bBlock recibe hContext y ejecuta el trabajo
// - decision: bBlock recibe los datos y devuelve la etiqueta del camino
METHOD SetHandler( cName, bBlock ) CLASS ProcessDefinition

   IF ValType( bBlock ) == 'B'

      ::hHandlers[ Canon( cName ) ] := bBlock

   ENDIF

RETURN Self

// Regla de nivel 2 sobre una transicion o accion
METHOD AddRule( cName, cType, xValue ) CLASS ProcessDefinition

   LOCAL cKey  := Canon( cName )
   LOCAL cRule := Canon( cType )

   IF cRule $ '|' + RULE_ROLES + '|' + RULE_FIELDS + '|' + RULE_LIMIT + '|'

      IF ! hb_HHasKey( ::hRules, cKey )

         ::hRules[ cKey ] := { => }

      ENDIF

      ::hRules[ cKey ][ cRule ] := xValue

   ENDIF

RETURN Self

// Integridad referencial: nada apunta a algo que no existe
METHOD Validate() CLASS ProcessDefinition

   LOCAL aErrors := {}
   LOCAL cName, cLabel, cTarget, hDef

   // Transiciones y acciones deben terminar en estados definidos

   FOR EACH cName IN hb_HKeys( ::hTransitions )

      IF ! ::IsState( ::hTransitions[ cName ][ 'state' ] )

         AAdd( aErrors, 'transition ' + cName + ': unknown state ' + ::hTransitions[ cName ][ 'state' ] )

      ENDIF

   NEXT

   FOR EACH cName IN hb_HKeys( ::hActions )

      hDef := ::hActions[ cName ]

      IF ! ::IsState( hDef[ 'state' ] )

         AAdd( aErrors, 'action ' + cName + ': unknown state ' + hDef[ 'state' ] )

      ENDIF

      IF ! hb_HHasKey( ::hHandlers, cName )

         AAdd( aErrors, 'action ' + cName + ': missing handler' )

      ENDIF

   NEXT

   // Las ramas de cada rombo deben apuntar a acciones o rombos conocidos

   FOR EACH cName IN hb_HKeys( ::hDecisions )

      FOR EACH cLabel IN hb_HKeys( ::hDecisions[ cName ] )

         cTarget := ::hDecisions[ cName ][ cLabel ]

         IF ! ::IsAction( cTarget ) .AND. ! ::IsDecision( cTarget )

            AAdd( aErrors, 'decision ' + cName + ' branch ' + cLabel + ': unknown target ' + cTarget )

         ENDIF

      NEXT

      IF ! hb_HHasKey( ::hHandlers, cName )

         AAdd( aErrors, 'decision ' + cName + ': missing handler' )

      ENDIF

   NEXT

   // El cableado estado -> decision debe usar piezas definidas

   FOR EACH cName IN hb_HKeys( ::hStateDecision )

      IF ! ::IsState( cName )

         AAdd( aErrors, 'setdecision: unknown state ' + cName )

      ENDIF

      IF ! ::IsDecision( ::hStateDecision[ cName ] )

         AAdd( aErrors, 'setdecision: unknown decision ' + ::hStateDecision[ cName ] )

      ENDIF

   NEXT

   // Las reglas se ponen sobre transiciones o acciones

   FOR EACH cName IN hb_HKeys( ::hRules )

      IF ! ::IsTransition( cName ) .AND. ! ::IsAction( cName )

         AAdd( aErrors, 'rules on unknown node ' + cName )

      ENDIF

   NEXT

RETURN { 'ok' => Empty( aErrors ), 'errors' => aErrors }

METHOD IsState( cName ) CLASS ProcessDefinition

   LOCAL lFound

   lFound := AScan( ::aStates, {| c | c == Canon( cName ) } ) > 0

RETURN lFound

METHOD IsTransition( cName ) CLASS ProcessDefinition

RETURN hb_HHasKey( ::hTransitions, Canon( cName ) )

METHOD IsDecision( cName ) CLASS ProcessDefinition

RETURN hb_HHasKey( ::hDecisions, Canon( cName ) )

METHOD IsAction( cName ) CLASS ProcessDefinition

RETURN hb_HHasKey( ::hActions, Canon( cName ) )
