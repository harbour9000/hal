# HIX HAL — Análisis didáctico

> Lectura pensada para alguien que mira el repo por primera vez y quiere
> entender **qué hay, qué hace cada pieza y por qué está donde está**.
> No describe lo que falta añadir, describe lo que ya está construido.

---

## 1. ¿Qué es este proyecto, en una frase?

Un **servidor web en xBase/Harbour (HIX)** que expone un **motor BPM
genérico** (dos clases) y un **proceso de ejemplo** (facturas), con una
pantalla web que lanza los tests y muestra la traza coloreada.

Está anunciado como "intento IA + MCP + BPM", pero **a día de hoy en el
código solo vive el BPM**. No hay cliente de LLM, no hay servidor MCP,
no hay prompts. El BPM es el ladrillo base sobre el que, en un paso
posterior, se podrá colgar un servidor MCP que exponga `Run`, `Get`,
`History`, `Validate` como herramientas para una IA. Ver §7.

---

## 2. Mapa del repositorio

```
C:\hix.hal\
├─ hix.exe              servidor HIX (binario Harbour)
├─ claude.exe           Claude Code CLI (no es parte del proyecto)
├─ hix.json             configuración del servidor (puerto 4322, pools...)
├─ libcrypto / libssl / libcurl .dll   runtime
├─ readme.md            "# HIX HAL"
├─ doc/
│  ├─ BPM-API.md        guía de uso del BPM (ya existente)
│  └─ analisis.md       ← este archivo
└─ www/                 raíz del sitio
   ├─ config.json       sets de xBase, claves, DBF
   ├─ routes/web.json   3 rutas: /, /main, /test
   ├─ loaders/
   │  └─ 00_bpm_core.prg      monta el núcleo al arranque
   ├─ controllers/
   │  ├─ main.prg             render de /main
   │  ├─ test.prg             endpoint /test (lanza las 3 suites)
   │  ├─ invoice_simple.prg   proceso de facturas de ejemplo
   │  └─ core/
   │     ├─ ProcessDefinition.prg   clase: definir un proceso
   │     └─ BpmEngine.prg           clase: ejecutar un proceso
   ├─ views/
   │  ├─ index.html       portada ("HIX" latiendo)
   │  ├─ main.html        pantalla con botón Test + consola
   │  └─ common/          header y navbar reutilizables
   └─ public/             css + imágenes
```

Puntos clave para orientarse:

- Todo lo que vive en `www/loaders/` lo **carga HIX al arrancar**, una
  sola vez, y queda disponible globalmente. Por eso `00_bpm_core.prg`
  se limita a `#INCLUDE` las tres piezas que forman el núcleo.
- Todo lo que vive en `www/controllers/` **se recompila por petición**
  (HRB fresco). Es decir, el `test.prg` se compila en cada `GET /test`.
  Esto da aislamiento, pero obliga a `test.prg` a declarar
  `THREAD STATIC` para no mezclar estado entre peticiones simultáneas.

---

## 3. El BPM en una pizarra

El proceso de facturas (fiel al diagrama original) es:

```
   receive ─▶ [received] ─▶ ◇ complete ─no─▶ notify_supplier ─▶ [returned]
                               │yes
                               ▼
                           ◇ check_amount ─yes─▶ auto_approve   ─▶ [approved]
                               │no
                               ▼
                           manual_approve (manual) ─▶ [approved]
```

Cuatro tipos de pieza, y hay que verlos como piezas distintas:

| pieza          | qué es                                               | ejemplo               |
|----------------|------------------------------------------------------|-----------------------|
| **estado**     | un "fin" o punto de espera                           | `received`, `approved`|
| **transición** | acción inicial, crea la instancia                    | `receive`             |
| **decisión** ◇ | rombo, elige una etiqueta y salta a acción u otro ◇  | `complete`            |
| **acción**     | hace trabajo y acaba en un estado; auto o manual     | `auto_approve`        |

**Regla de fidelidad al diagrama:** los rombos *nunca* apuntan a
estados; apuntan a **acciones** (o a otros rombos). Son las acciones
las que terminan en un estado. Esto es importante porque es la
convención que hace que el motor funcione: el motor "cae" en un estado
tras ejecutar una acción, y es ahí donde comprueba si ese estado tiene
un rombo cableado para seguir.

---

## 4. Las dos clases, explicadas

### 4.1 `ProcessDefinition` — el dibujo

Vive en `www/controllers/core/ProcessDefinition.prg`. **Solo define**:
no ejecuta nada. Guarda la topología del proceso en siete hashes/arrays:

```
cName            nombre canónico del proceso
aStates          lista de estados ("fins")
hTransitions     cName → { state }
hDecisions       cName → { etiqueta → destino }
hActions         cName → { state, manual }
hStateDecision   estado → rombo que se dispara al caer en él
hHandlers        cName → code block  (para acciones y rombos)
hRules           cName → { roles|fields|limit → valor }   ← nivel 2
```

Lo relevante del diseño:

- **Canonicalización**: toda clave entra por `Canon()` (minúsculas +
  trim). Esto hace que el usuario pueda escribir `'Receive'` o
  `' receive '` sin romper nada. Un test lo verifica (`state names
  case/space safe`).
- **Dos niveles**:
  - *Nivel 1 (dibujo)*: estados, transiciones, decisiones, acciones.
  - *Nivel 2 (reglas, opcional)*: `roles` (quién puede), `fields`
    (campos obligatorios), `limit` (máximo numérico). Las reglas se
    cuelgan de una transición o acción.
- **Validate()** es la "integridad referencial": comprueba que nada
  apunte a algo que no existe (transición a estado desconocido,
  rombo a acción fantasma, acción sin handler, regla sobre un nodo
  inexistente...). Devuelve `{ ok, errors }`.

### 4.2 `BpmEngine` — el motor

Vive en `www/controllers/core/BpmEngine.prg`. **Solo ejecuta**:
no sabe nada del dominio. Guarda las instancias vivas en memoria:

```harbour
VAR hInstances AS HASH   // clave 'nombreproceso|id' → instancia
```

Una **instancia** es un hash:

```
{ 'id', 'process', 'state', 'data', 'pending', 'history' }
```

Un único punto de entrada:

```harbour
oEng:Run( oProcess, oUser, cAction, hData )
   → { ok, error, id, state, pending, executed, history }
```

Lo que hace `Run` por dentro (lectura recomendada en paralelo con el
código, `BpmEngine.prg:40`):

1. **Valida la entrada**: que `oProcess` sea una `ProcessDefinition`
   válida, que `oUser` tenga `cName` y `aRoles`, que `hData` traiga
   `id`. Error = devuelve `{ ok: .F., error }` legible.
2. **Decide la rama** por el tipo de `cAction`:
   - *Es una transición* → **crea** la instancia (si no existe).
   - *Es una acción manual* → **reanuda** la instancia (si estaba
     pendiente de esa acción exacta).
   - *Otra cosa* → `unknown action`.
3. **Aplica las reglas** de nivel 2 (`CheckRules`): roles, fields,
   limit. Si fallan, aborta con error.
4. **Fusión de datos**: en acciones manuales, los datos nuevos se
   funden sobre la instancia con `hb_HMerge`. Es decir, el `data` que
   acumula la instancia *crece* a lo largo del proceso.
5. **Cascada automática** (`Cascade`): mientras el estado actual
   tenga un rombo cableado, se:
   a) **evalúa la cadena de rombos** (un rombo puede apuntar a otro
      rombo; se sigue hasta aterrizar en una acción);
   b) si la acción es **manual** → aparca la instancia (`pending`),
      registra `route -> wait <accion>` en el historial y **retorna**;
   c) si la acción es **automática** → ejecuta su handler, cambia de
      estado, registra en historial y vuelve a mirar si el nuevo
      estado tiene rombo.
6. **Freno anti-bucles**: `MAX_STEPS = 100`. Dos rombos que se
   apuntan mutuamente no cuelgan el servidor; el motor corta con
   `max steps exceeded`.

**Handlers.** Un handler es un code block. Dos usos:

- *Handler de acción*: recibe `hCtx = { id, data, user, state }` y
  hace el trabajo. `data` es la **referencia viva** de la instancia,
  así que escribir en `hCtx['data']['approved_by']` persiste.
- *Handler de rombo*: recibe `hData` y devuelve la **etiqueta** del
  camino (`'yes'`, `'no'`...). Si devuelve una etiqueta que el rombo
  no conoce, el motor aborta con `unknown branch`.

**Historial.** Cada movimiento añade una línea:

```
{ ts, user, action, from, to }
```

El historial se graba desde dentro del motor; el handler no tiene
que preocuparse de ello.

---

## 5. El ejemplo (invoice_simple)

`www/controllers/invoice_simple.prg` es una **función de fábrica** que
devuelve un `ProcessDefinition` completamente configurado:

```harbour
oProc := SimpleInvoiceProcess()
oEng  := BpmEngine():New()

hRes := oEng:Run( oProc, oUser, 'receive',
    { 'id' => 'FAC-1', 'supplier' => 'ACME', 'amount' => 500 } )
```

Caminos del diagrama, con el porqué:

- **completa y < 1000** → cascada total: `complete=yes` → `check_amount=yes`
  → `auto_approve` ejecuta su handler → `approved`. El usuario solo
  llamó a `receive` una vez.
- **completa y ≥ 1000** → `check_amount=no` apunta a `manual_approve`
  (manual) → motor aparca, instancia queda en `received` con
  `pending='manual_approve'`. Hace falta una **segunda llamada** con
  un usuario que tenga rol `approver`.
- **incompleta** → `complete=no` → `notify_supplier` (auto) → `returned`.

Reglas (nivel 2) que trae el ejemplo:

```
receive        ← fields: supplier, amount
manual_approve ← roles:  approver
```

El límite (`amount max 10000`) no se activa en el ejemplo "en caliente"
— se usa solo en los tests, como demostración.

---

## 6. Cómo se expone todo al navegador

### Rutas (`www/routes/web.json`)

```
GET /       → views/index.html         portada
GET /main   → controllers/main.prg     pantalla con consola
GET /test   → controllers/test.prg     ejecuta las suites, devuelve JSON
```

### La pantalla `/main`

`views/main.html` es una página con:

- un botón **Test** grande,
- una `<div id="hal-console">` que simula una consola oscura con
  colores por tipo de línea (suite / user / ok / err / sys / how / pass / fail).

Al pulsar Test, el JS hace `fetch('/test?name=all')`, recibe el JSON
con `lines[]` y pinta cada línea con la clase CSS que le toca por su
`kind`. El resultado final (`TEST PASS` / `TEST FAIL`) va en una
banda verde o roja.

### El endpoint `/test`

`controllers/test.prg` acepta `?name=invoice_simple|engine|definition|all`
y devuelve:

```
{ name, ok, pass, fail, lines: [ { kind, text }, ... ] }
```

Dos detalles que explican decisiones del archivo:

- **`FUNCTION Main` va primero.** Un controlador HIX ejecuta el primer
  símbolo público del HRB. Si pusieras la clase `BpmTestUser` antes,
  su `New()` sería la entrada y la respuesta sería `** object **`.
  Está anotado en el propio `test.prg`.
- **`THREAD STATIC` para los acumuladores (`s_aLines`, `s_nPass`,
  `s_nFail`).** HIX recompila el HRB por petición, así que *hoy*
  no habría colisión, pero si algún día cachea el HRB, dos peticiones
  simultáneas podrían pisar los acumuladores. `THREAD STATIC` da una
  copia por hilo y lo evita por diseño.

### Las tres suites de tests

Cada suite narra lo que hace (`TLine`) y comprueba (`TCheck`):

| suite               | qué cubre                                                           |
|---------------------|---------------------------------------------------------------------|
| `process_definition`| construcción, canonicalización, `Validate()` sobre procesos rotos  |
| `bpm_engine`        | cascada, reglas, errores de uso, freno anti-bucles, instancias     |
| `invoice_simple`    | los 3 caminos del diagrama + el borde amount=1000                   |

El total son ~60 checks. Cada `PASS` lleva debajo una línea `how` en
púrpura con la **explicación didáctica** del porqué: el objetivo era
que la consola enseñe el BPM al mirarla, no solo que diga "verde".

---

## 7. Dónde entraría la IA + MCP (lo que **aún no** está)

Hoy el BPM se opera por HTTP (vía `test.prg`) y por código. Para
convertir esto en un sistema "IA + MCP + BPM" el camino natural es:

1. **Un servidor MCP** (fuera o dentro del propio HIX) que exponga
   herramientas 1-a-1 con la API del motor:
   - `bpm.run(process, user, action, data)` → `BpmEngine:Run`
   - `bpm.get(process, id)` → `BpmEngine:Get`
   - `bpm.history(process, id)` → `BpmEngine:History`
   - `bpm.validate(process)` → `ProcessDefinition:Validate`
   - `bpm.list_processes()` / `bpm.describe(process)` para
     introspección.
2. **Un cliente de LLM** (Claude, por ejemplo) que, con esas
   herramientas, pueda:
   - leer una factura (OCR / texto),
   - mapearla a `hData`,
   - llamar a `bpm.run` como si fuera un operador humano,
   - interpretar el resultado (`pending`, `error`, `state`).

El diseño actual del BPM **ya está preparado** para ese paso: el
motor devuelve un JSON autodescriptivo (`ok`, `error`, `pending`,
`executed`, `history`), los errores son texto plano legible por un
LLM, y los handlers son code blocks que pueden hacer cualquier cosa
(incluido llamar a modelos). No hay deuda bloqueante.

---

## 8. Puntos finos que vale la pena recordar

- **Identidad = `id` + proceso.** Dos procesos pueden tener instancias
  con el mismo `id`; se diferencian por la clave `proceso|id`.
- **Las instancias viven en memoria** (`hInstances`). Reiniciar el
  servidor las pierde. Para persistencia habría que serializar
  `hInstances` o enganchar un RDD/DBF.
- **El `data` es acumulativo.** Cada `Run` manual hace `hb_HMerge`
  del `hData` recibido con el `data` existente. El handler puede
  escribir en él y queda guardado.
- **Las reglas se aplican a la acción que el usuario pide, no a las
  automáticas de la cascada.** Es decir, `roles` sobre `auto_approve`
  no tendría sentido porque la ejecuta `system`.
- **El `Validate()` del proceso lo llama el motor en cada `Run`.**
  Es un coste pequeño que compra la garantía de que nunca ejecuta un
  proceso roto.
- **La separación "definición vs motor" es la decisión arquitectónica
  central.** Permite que haya varios procesos distintos usando el
  mismo motor, y que el motor sea testeable sin dominio.

---

## 9. Lectura mínima recomendada, por orden

1. `doc/BPM-API.md` — la referencia corta de API.
2. `www/controllers/core/ProcessDefinition.prg` — qué se puede
   describir.
3. `www/controllers/invoice_simple.prg` — un ejemplo real.
4. `www/controllers/core/BpmEngine.prg` — cómo se ejecuta.
5. `www/controllers/test.prg` — los 3 caminos vistos como tests
   narrativos (muy didáctico).
6. `www/views/main.html` — cómo se pinta todo en pantalla.

Con eso se entiende el proyecto entero.
