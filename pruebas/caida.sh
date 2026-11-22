#!/bin/bash
# Prueba de caida: mata (o traba) un servicio y mide cuanto tarda systemd en tenerlo
# otra vez arriba con un proceso nuevo.
#
# uso (en la VM del servicio, con los servicios instalados):
#     sudo ./pruebas/caida.sh srb-rmc@2              mata el proceso (SIGTERM)
#     sudo ./pruebas/caida.sh srb-gestor@1 kill9     lo mata sin aviso (SIGKILL)
#     sudo ./pruebas/caida.sh srb-persistencia trabar
#                                                    lo congela (SIGSTOP): prueba el watchdog
#
# Mientras tanto, en la VM1 un cliente sigue mandando solicitudes; su CSV muestra
# si alguna quedo sin respuesta y cuanto tardo la que le toco la caida.

SERVICIO=${1%.service}; ACCION=${2:-matar}
[ -n "$SERVICIO" ] || { echo "uso: sudo $0 <servicio> [matar|kill9|trabar]"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Hay que correrlo con sudo."; exit 1; }

pid=$(systemctl show -p MainPID --value "$SERVICIO")
reinicios=$(systemctl show -p NRestarts --value "$SERVICIO")
[ "$pid" != 0 ] || { echo "$SERVICIO no esta corriendo."; exit 1; }

case "$ACCION" in
    matar)  senal=TERM; limite=15 ;;
    kill9)  senal=KILL; limite=15 ;;
    trabar) senal=STOP; limite=30 ;;   # el watchdog espera 5 s (10 s el gestor) antes de actuar
    *) echo "La accion es matar, kill9 o trabar"; exit 1 ;;
esac

echo "$SERVICIO: PID $pid, reiniciado $reinicios veces. Enviando SIG$senal..."
inicio=$(date +%s%N)
kill -s "$senal" "$pid"

while true; do
    sleep 0.2
    ms=$(( ($(date +%s%N) - inicio) / 1000000 ))     # milisegundos desde la senal
    nuevo=$(systemctl show -p MainPID --value "$SERVICIO")
    estado=$(systemctl show -p ActiveState --value "$SERVICIO")
    if [ "$nuevo" != 0 ] && [ "$nuevo" != "$pid" ] && [ "$estado" = active ]; then
        printf 'Volvio en %d.%d s con el PID %s (reinicios: %s).\n' $((ms / 1000)) $((ms % 1000 / 100)) "$nuevo" \
            "$(systemctl show -p NRestarts --value "$SERVICIO")"
        [ "$ACCION" = trabar ] && journalctl -u "$SERVICIO" --since "-1min" --no-pager | grep -i watchdog | tail -1
        exit 0
    fi
    if [ "$ms" -gt $((limite * 1000)) ]; then
        echo "No volvio en $limite s. Estado: $estado. Revise: journalctl -u $SERVICIO -n 20"
        [ "$ACCION" = trabar ] && kill -s CONT "$pid" 2>/dev/null
        exit 1
    fi
done
