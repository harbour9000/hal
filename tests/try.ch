// TRY / CATCH / FINALLY sobre BEGIN SEQUENCE (Harbour 3.x no los trae).
// Misma tecnica que usa HIX (hix_const.ch).
#xcommand TRY                    => BEGIN SEQUENCE WITH {| oErr | Break( oErr ) }
#xcommand CATCH [<!oErr!>]       => RECOVER [USING <oErr>] <-oErr->
#xcommand FINALLY                => ALWAYS
