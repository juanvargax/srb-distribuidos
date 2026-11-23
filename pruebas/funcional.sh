#!/bin/bash
# Prueba funcional: recorre todas las operaciones del enunciado, incluidos los rechazos,
# y compara cada respuesta con la esperada.
#
# uso (en la VM1, desde la carpeta del proyecto, con todo el sistema arriba):
#     ./pruebas/funcional.sh
#
# Usa clientes con un nombre nuevo en cada corrida (L<numero>, P<numero>) y al final
# cancela lo que reservo, asi que se puede repetir sin reiniciar la BD.
# Termina con codigo 0 si todo paso y 1 si algo fallo.

cd "$(dirname "$0")/.." || exit 1
[ -x ./cliente ] || { echo "Falta ./cliente: corra make primero."; exit 1; }

N=$(date +%s)
L="L$N"          # cliente que reserva, modifica y cancela
P="P$N"          # cliente sin reservas

# solicitud | resultado esperado (comienzo de la respuesta) | que se prueba
CASOS=(
"CONSULTA 2026-11|EXITO|consulta de un mes con eventos"
"CONSULTA 1999-01|RECHAZO|consulta de un mes sin eventos"
"RESERVA E1 2026-11-18 $L 2|EXITO|reserva normal"
"RESERVA E1 2026-11-18 $L 999|RECHAZO|reserva con mas asientos de los libres"
"RESERVA E99 2026-11-18 $L 1|RECHAZO|reserva de un evento que no existe"
"RESERVA E1 2026-11-18 $L 0|RECHAZO|reserva de 0 asientos"
"MODIFICACION E1 2026-11-18 $L 2026-11-06 3|EXITO|modificacion de fecha y asientos"
"MODIFICACION E1 2026-11-06 $L 2026-11-06 4|EXITO|modificacion solo de asientos"
"MODIFICACION E1 2026-11-06 $L 2026-11-30 1|RECHAZO|modificacion a una fecha que no existe"
"MODIFICACION E1 2026-11-06 $L 2026-11-18 999|RECHAZO|modificacion sin cupo (la reserva queda igual)"
"MODIFICACION E1 2026-11-06 $P 2026-11-18 1|RECHAZO|modificacion de un cliente sin reserva"
"ELIMINAR E1 2026-11-06 $L|RECIBIDO|cancelacion (asincrona)"
"ELIMINAR E1 2026-11-06 $L|RECIBIDO|cancelacion de algo ya cancelado"
"BORRAR E1 2026-11-06 $L|RECHAZO|tipo de solicitud desconocido"
)

# notificaciones que deben llegar por PUB/SUB despues de las dos cancelaciones
NOTIFICACIONES=(
"[Notificacion] $L CANCELACION E1 2026-11-06: Reserva cancelada. Se liberaron 4 asientos|primera cancelacion: libera los 4 asientos que quedaron despues de modificar"
"[Notificacion] $L CANCELACION E1 2026-11-06: No se encontro reserva para eliminar|segunda cancelacion: ya no habia nada"
)

ARCHIVO=$(mktemp)
SALIDA=$(mktemp)
for caso in "${CASOS[@]}"; do echo "${caso%%|*}" >> "$ARCHIVO"; done

echo "Prueba funcional con los clientes $L y $P..."
./cliente "$ARCHIVO" 600 > "$SALIDA" 2>&1       # 600 por minuto = una cada 100 ms

pasaron=0; fallaron=0
revisar() {   # $1 = paso (0/1), $2 = descripcion, $3 = detalle si fallo
    if [ "$1" = 1 ]; then
        printf '  \e[32mPASO\e[0m   %s\n' "$2"; pasaron=$((pasaron + 1))
    else
        printf '  \e[31mFALLO\e[0m  %s\n         %s\n' "$2" "$3"; fallaron=$((fallaron + 1))
    fi
}

# el cliente imprime una linea por solicitud, en orden: "<solicitud>  =>  <respuesta>  (<ms> ms)"
mapfile -t RESPUESTAS < <(grep -F "  =>  " "$SALIDA")

echo -e "\nRespuestas:"
for i in "${!CASOS[@]}"; do
    IFS='|' read -r solicitud esperado descripcion <<< "${CASOS[$i]}"
    linea=${RESPUESTAS[$i]}
    respuesta=${linea#*  =>  }
    if [[ "$linea" == "$solicitud  =>  "* && "$respuesta" == "$esperado"* ]]; then
        revisar 1 "$descripcion"
    else
        revisar 0 "$descripcion" "esperaba $esperado, llego: ${respuesta:-(nada)}"
    fi
done

echo -e "\nNotificaciones (PUB/SUB):"
for notif in "${NOTIFICACIONES[@]}"; do
    IFS='|' read -r texto descripcion <<< "$notif"
    if grep -qF "$texto" "$SALIDA"; then revisar 1 "$descripcion"
    else revisar 0 "$descripcion" "no llego: $texto"; fi
done
otras=$(grep -F "[Notificacion]" "$SALIDA" | grep -vcF "[Notificacion] $L ")
if [ "$otras" = 0 ]; then revisar 1 "solo llegan las notificaciones del propio cliente"
else revisar 0 "solo llegan las notificaciones del propio cliente" "llegaron $otras de otros clientes"; fi

echo -e "\nResultado: $pasaron pasaron, $fallaron fallaron."
[ "$fallaron" = 0 ] || echo "Salida completa del cliente en $SALIDA"
rm -f "$ARCHIVO"
[ "$fallaron" = 0 ] && rm -f "$SALIDA"
[ "$fallaron" = 0 ]
