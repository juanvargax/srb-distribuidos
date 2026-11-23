#!/bin/bash
# Corre un escenario de la Tabla 1 del enunciado: lanza los clientes en paralelo en modo
# carga y guarda sus metricas en pruebas/resultados/<escenario>_<arquitectura>/.
#
# uso (en la VM1, desde la carpeta del proyecto):
#     ./pruebas/experimento.sh <A|B|C> <base|escalable> [operaciones] [porMinuto]
#     ./pruebas/experimento.sh B escalable              (300 operaciones por cliente, sin pausa)
#
# Escenarios (Tabla 1):
#   A: 3 clientes  ->  2 con 100 % consulta; 1 con 50 % consulta y 50 % reserva
#   B: 5 clientes  ->  3 con 100 % consulta; 2 con 50 % reserva y 50 % modificacion
#   C: 8 clientes  ->  4 con 100 % consulta; 4 con 50 % reserva y 50 % modificacion
#
# La arquitectura la deja lista el que corre la prueba en la VM2, ANTES de lanzar esto:
#   base:      sudo systemctl stop  srb-gestor@2 srb-rmc@2 srb-rmc@3     (1 gestor, 1 RMC)
#   escalable: sudo systemctl start srb-gestor@2 srb-rmc@2 srb-rmc@3     (2 gestores, 3 RMC)
# En la escalable los clientes se reparten entre los dos gestores (uno empieza por el 1,
# el siguiente por el 2); en la base todos van al gestor 1.
#
# Despues de las seis corridas: python3 pruebas/analizar.py

cd "$(dirname "$0")/.." || exit 1
ESCENARIO=${1^^}; ARQUITECTURA=${2,,}; OPERACIONES=${3:-300}; POR_MINUTO=${4:-0}

case "$ESCENARIO" in
    A) CLIENTES=("100 0 0" "100 0 0" "50 50 0") ;;
    B) CLIENTES=("100 0 0" "100 0 0" "100 0 0" "0 50 50" "0 50 50") ;;
    C) CLIENTES=("100 0 0" "100 0 0" "100 0 0" "100 0 0" "0 50 50" "0 50 50" "0 50 50" "0 50 50") ;;
    *) echo "uso: $0 <A|B|C> <base|escalable> [operaciones] [porMinuto]"; exit 1 ;;
esac
case "$ARQUITECTURA" in
    base|escalable) ;;
    *) echo "La arquitectura es base o escalable"; exit 1 ;;
esac
[ -x ./cliente ] || { echo "Falta ./cliente: corra make primero."; exit 1; }

DIR="pruebas/resultados/${ESCENARIO}_${ARQUITECTURA}"
rm -rf "$DIR" && mkdir -p "$DIR"
ritmo=$([ "$POR_MINUTO" = 0 ] && echo "sin pausa" || echo "$POR_MINUTO por minuto")
echo "Escenario $ESCENARIO, arquitectura $ARQUITECTURA: ${#CLIENTES[@]} clientes, $OPERACIONES operaciones cada uno, $ritmo"

{
    echo "escenario=$ESCENARIO"
    echo "arquitectura=$ARQUITECTURA"
    echo "clientes=${#CLIENTES[@]}"
    echo "operaciones=$OPERACIONES"
    echo "por_minuto=$POR_MINUTO"
    echo "fecha=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "maquina=$(hostname)"
} > "$DIR/experimento.txt"

inicio=$(date +%s)
pids=()
for i in "${!CLIENTES[@]}"; do
    nombre="${ESCENARIO}${ARQUITECTURA:0:1}_C$((i + 1))"     # ej. Be_C3
    gestor=1
    [ "$ARQUITECTURA" = escalable ] && [ $((i % 2)) = 1 ] && gestor=2
    read -r c r m <<< "${CLIENTES[$i]}"
    echo "  $nombre: $c % consulta, $r % reserva, $m % modificacion, gestor $gestor"
    SRB_GESTOR_INICIAL=$gestor ./cliente carga "$nombre" $c $r $m "$OPERACIONES" "$POR_MINUTO" \
        > "$DIR/$nombre.log" 2>&1 &
    pids+=($!)
done
wait "${pids[@]}"
mv metricas_"${ESCENARIO}${ARQUITECTURA:0:1}"_C*.csv "$DIR/"

total=$(cat "$DIR"/metricas_*.csv | grep -vc '^operacion')
sin=$(cat "$DIR"/metricas_*.csv | grep -c 'SIN_RESPUESTA')
echo "Terminado en $(( $(date +%s) - inicio )) s: $total solicitudes, $sin sin respuesta. Resultados en $DIR"
