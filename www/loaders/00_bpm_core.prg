/*-----------------------------------------------------------
  File ......: 00_bpm_core.prg
  Project....: HIX HAL - BPM generico
  Description: Loader del nucleo BPM. HIX compila y carga en memoria
               todo lo de www/loaders al arrancar, asi que aqui se
               montan las piezas que viven en controllers/ para que
               sean accesibles globalmente (clases y proceso).
 -----------------------------------------------------------*/

// Las clases del BPM (definicion y motor)

#INCLUDE "controllers/core/ProcessDefinition.prg"
#INCLUDE "controllers/core/BpmEngine.prg"

// El primer proceso: facturas simples

#INCLUDE "controllers/invoice_simple.prg"
