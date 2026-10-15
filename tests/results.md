# Resultados de los tests

Tres test independientes, cada uno compilado con hbmk2 y ejecutado en su
propio proceso, con el cuerpo aislado en un hilo y TRY/CATCH con ErrorSys.

```
hbmk2 -mt test_<nombre>.prg ../controller/core/ProcessDefinition.prg \
        ../controller/core/BpmEngine.prg ../processes/invoice_simple.prg
```

| Test | Checks | Resultado |
|---|---|---|
| test_process_definition | 17 | PASS |
| test_bpm_engine | 30 | PASS |
| test_invoice_simple | 13 | PASS |

Total: 60 checks, 0 fallos.

- **test_process_definition**: construccion de la definicion, canon de
  nombres (case y blancos), registro de transiciones/rombos/acciones,
  cableado estado -> rombo, reglas, y Validate() explicando cada error
  (estado desconocido, rama huerfana, accion sin handler, regla sobre
  nodo inexistente).
- **test_bpm_engine**: cascada de rombos, accion automatica, accion
  manual con rol, repeticion como no-op con error claro, reglas
  roles/fields/limit, errores de uso (sin id, duplicado, accion o
  instancia desconocida, usuario o proceso invalido), rombo con
  etiqueta inexistente, freno anti-bucles, Get/History.
- **test_invoice_simple**: los 3 caminos del diagrama (auto-aprobada,
  firma manual, devuelta por incompleta), el borde de 1000 exactos, el
  historial por instancia y el aislamiento entre instancias.

El detalle por check esta en `results/<nombre>.md`.
