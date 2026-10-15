# Documentación de HIX HAL

Índice de los documentos de `/doc`. Están pensados para leerse en el
orden que marca cada sección.

---

## Para entender el proyecto de cero

Si es la primera vez que miras el repo, empieza por aquí.

1. **[analisis.md](analisis.md)** — Análisis general del proyecto en
   9 secciones: qué es, mapa del repositorio, pizarra del BPM, las
   dos clases, el ejemplo, cómo se expone al navegador, dónde entraría
   la IA + MCP, puntos finos y orden de lectura.

2. **[traza-de-un-test.md](traza-de-un-test.md)** — Paso a paso de
   qué ocurre cuando corre un test. Toma como hilo el camino B del
   test `invoice_simple` (factura de 2400 €) y recorre toda la pila
   citando fichero y línea. Incluye pros/contras del diseño.

---

## Las tres piezas, en profundidad

Mini-manual de cada pieza del BPM. Didácticos, con analogías y
ejemplos. Léelos en este orden.

3. **[01-ProcessDefinition.md](01-ProcessDefinition.md)** — El
   **plano** del proceso. Las 4 piezas de LEGO (estado, transición,
   decisión, acción), los 7 cajones de la clase, canonicalización,
   los 10 métodos uno a uno, ejemplo progresivo (pizzería) y errores
   habituales.

4. **[02-BpmEngine.md](02-BpmEngine.md)** — El **motor** que ejecuta
   el plano. Qué es una instancia, los 12 subpasos de `Run`, cómo
   funciona `Cascade` con el freno anti-bucles, las reglas,
   el historial, ejemplo guiado completo y catálogo de errores.

5. **[03-SimpleInvoiceProcess.md](03-SimpleInvoiceProcess.md)** — El
   **proceso real** de facturas. Diagrama, la fábrica sección a
   sección, los 3 caminos vividos con valores reales, casos de
   borde e ideas de extensión.

---

## Referencia rápida

Para cuando ya conoces el BPM y solo necesitas recordar la API.

6. **[BPM-API.md](BPM-API.md)** — Guía corta de uso: construcción
   de un `ProcessDefinition`, llamadas al `BpmEngine`, formato de
   la respuesta y detalles que conviene saber.

---

## Otros

- **`log.txt`** — Volcado de ejemplo de una ejecución de los tests
  (`/test?name=all`). Útil como referencia visual del formato que
  pinta la consola de `/main`.
