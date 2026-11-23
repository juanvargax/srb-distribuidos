#!/usr/bin/env python3
"""Resume los experimentos de pruebas/resultados/ en la tabla y las 4 graficas del informe.

uso (desde la carpeta del proyecto, despues de las seis corridas de experimento.sh):
    python3 pruebas/analizar.py

Por cada escenario (A, B, C) y arquitectura (base, escalable) calcula:
  - tiempo de respuesta promedio y desviacion estandar, por tipo de operacion, en ms
    (solicitudes respondidas: EXITO o RECHAZO; las SIN_RESPUESTA se cuentan aparte)
  - TPM: transacciones exitosas por minuto, por tipo = exitos / duracion de la corrida,
    donde la duracion va desde la primera solicitud enviada hasta la ultima respuesta

Escribe pruebas/resultados/resumen.csv, resumen.md y, si hay matplotlib
(sudo apt install python3-matplotlib), las graficas tiempo_consulta.png,
tiempo_reserva.png, tpm_consulta.png y tpm_reserva.png.
"""
import csv
import glob
import os
import statistics

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resultados")
TIPOS = ["CONSULTA", "RESERVA", "MODIFICACION"]
ARQUITECTURAS = ["base", "escalable"]


def leer_experimento(carpeta):
    info = {}
    with open(os.path.join(carpeta, "experimento.txt")) as f:
        for linea in f:
            clave, _, valor = linea.strip().partition("=")
            info[clave] = valor

    filas = []
    for ruta in glob.glob(os.path.join(carpeta, "metricas_*.csv")):
        with open(ruta) as f:
            filas += list(csv.DictReader(f))

    inicio = min(int(f["inicio_ms"]) for f in filas)
    fin = max(int(f["inicio_ms"]) + float(f["ms"]) for f in filas)
    minutos = (fin - inicio) / 60000

    fila = {
        "escenario": info["escenario"],
        "arquitectura": info["arquitectura"],
        "clientes": int(info["clientes"]),
        "solicitudes": len(filas),
        "sin_respuesta": sum(f["resultado"] == "SIN_RESPUESTA" for f in filas),
        "duracion_s": round(minutos * 60, 1),
    }
    for tipo in TIPOS:
        de_tipo = [f for f in filas if f["operacion"] == tipo]
        tiempos = [float(f["ms"]) for f in de_tipo if f["resultado"] in ("EXITO", "RECHAZO")]
        exitos = sum(f["resultado"] == "EXITO" for f in de_tipo)
        t = tipo.lower()
        fila[f"{t}_n"] = len(de_tipo)
        fila[f"{t}_ms_prom"] = round(statistics.mean(tiempos), 2) if tiempos else ""
        fila[f"{t}_ms_desv"] = round(statistics.stdev(tiempos), 2) if len(tiempos) > 1 else ""
        fila[f"{t}_tpm"] = round(exitos / minutos, 1) if de_tipo and minutos > 0 else ""
    return fila


def tabla_markdown(filas):
    titulos = ["Escenario", "Arquitectura", "Clientes",
               "Consulta: ms prom (desv)", "Reserva: ms prom (desv)", "Modificación: ms prom (desv)",
               "TPM consulta", "TPM reserva", "TPM modificación", "Sin respuesta"]
    lineas = ["| " + " | ".join(titulos) + " |", "|" + " --- |" * len(titulos)]

    def tiempo(f, t):
        return f"{f[t + '_ms_prom']} ({f[t + '_ms_desv']})" if f[t + "_ms_prom"] != "" else "—"

    for f in filas:
        lineas.append("| " + " | ".join(str(x) for x in [
            f["escenario"], f["arquitectura"], f["clientes"],
            tiempo(f, "consulta"), tiempo(f, "reserva"), tiempo(f, "modificacion"),
            f["consulta_tpm"] or "—", f["reserva_tpm"] or "—", f["modificacion_tpm"] or "—",
            f["sin_respuesta"]]) + " |")
    return "\n".join(lineas) + "\n"


def graficas(filas):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("No hay matplotlib: no se hicieron las graficas (sudo apt install python3-matplotlib)")
        return

    # base y escalable: los dos primeros colores categoricos de la paleta validada
    color = {"base": "#2a78d6", "escalable": "#eb6834"}
    texto, texto2, rejilla = "#1a1a19", "#5f5e5a", "#e8e7e3"
    graficas = [
        ("tiempo_consulta", "consulta_ms_prom", "consulta_ms_desv",
         "Tiempo de respuesta de las consultas", "Tiempo promedio (ms)"),
        ("tiempo_reserva", "reserva_ms_prom", "reserva_ms_desv",
         "Tiempo de respuesta de las reservas", "Tiempo promedio (ms)"),
        ("tpm_consulta", "consulta_tpm", None,
         "Consultas exitosas por minuto", "Transacciones por minuto (TPM)"),
        ("tpm_reserva", "reserva_tpm", None,
         "Reservas exitosas por minuto", "Transacciones por minuto (TPM)"),
    ]
    for archivo, campo, campo_desv, titulo, eje_y in graficas:
        fig, ax = plt.subplots(figsize=(6.4, 4), dpi=150)
        # si las dos series terminan muy cerca, sus etiquetas se separan para no pisarse
        finales = {arq: max(((f["clientes"], f[campo]) for f in filas
                             if f["arquitectura"] == arq and f[campo] != ""), default=None)
                   for arq in ARQUITECTURAS}
        # el alto del eje incluye las barras de desviacion
        tope = max([f[campo] + (f[campo_desv] or 0 if campo_desv else 0) for f in filas if f[campo] != ""] or [1])
        juntas = all(finales.values()) and abs(finales["base"][1] - finales["escalable"][1]) < 0.08 * tope
        for arq in ARQUITECTURAS:
            puntos = sorted((f["clientes"], f[campo], f[campo_desv] if campo_desv else 0)
                            for f in filas if f["arquitectura"] == arq and f[campo] != "")
            if not puntos:
                continue
            x = [p[0] for p in puntos]
            y = [p[1] for p in puntos]
            desv = [p[2] or 0 for p in puntos]
            ax.errorbar(x, y, yerr=desv if campo_desv else None, color=color[arq], linewidth=2,
                        marker="o", markersize=8, markeredgecolor="white", markeredgewidth=1.5,
                        capsize=4, elinewidth=1.25, label=arq.capitalize())
            separacion = 0
            if juntas:
                arriba = (y[-1] >= finales["base" if arq == "escalable" else "escalable"][1])
                separacion = 8 if arriba else -8
            ax.annotate(arq.capitalize(), (x[-1], y[-1]), xytext=(10, separacion), textcoords="offset points",
                        va="center", fontsize=9, color=texto2)
        ax.set_title(titulo, loc="left", fontsize=12, fontweight="bold", color=texto, pad=26)
        nota = "\nLas barras verticales son ± una desviación estándar." if campo_desv else ""
        ax.set_xlabel("Clientes simultáneos (escenarios A, B y C)" + nota, fontsize=9, color=texto2)
        ax.set_ylabel(eje_y, fontsize=9, color=texto2)
        ax.set_xticks([3, 5, 8])
        ax.set_xlim(2, 9.5)
        ax.set_ylim(bottom=0)
        ax.grid(axis="y", color=rejilla, linewidth=0.8)
        ax.set_axisbelow(True)
        for lado in ("top", "right"):
            ax.spines[lado].set_visible(False)
        for lado in ("left", "bottom"):
            ax.spines[lado].set_color(rejilla)
        ax.tick_params(colors=texto2, labelsize=9)
        # la leyenda va arriba, entre el titulo y la grafica, para no tapar ninguna linea
        ax.legend(frameon=False, fontsize=9, loc="lower left", bbox_to_anchor=(0, 1.0), ncol=2,
                  borderaxespad=0.2, handletextpad=0.4, columnspacing=1.2)
        fig.tight_layout()
        fig.savefig(os.path.join(DIR, archivo + ".png"))
        plt.close(fig)
        print("  grafica:", os.path.join(DIR, archivo + ".png"))


def main():
    carpetas = sorted(c for c in glob.glob(os.path.join(DIR, "*_*"))
                      if os.path.isfile(os.path.join(c, "experimento.txt")))
    if not carpetas:
        print("No hay resultados en", DIR, "- corra primero pruebas/experimento.sh")
        return
    filas = sorted((leer_experimento(c) for c in carpetas),
                   key=lambda f: (f["escenario"], ARQUITECTURAS.index(f["arquitectura"])))

    with open(os.path.join(DIR, "resumen.csv"), "w", newline="") as f:
        escritor = csv.DictWriter(f, fieldnames=list(filas[0].keys()))
        escritor.writeheader()
        escritor.writerows(filas)
    tabla = tabla_markdown(filas)
    with open(os.path.join(DIR, "resumen.md"), "w") as f:
        f.write(tabla)

    print(tabla)
    print("  tabla:", os.path.join(DIR, "resumen.csv"), "y resumen.md")
    graficas(filas)


if __name__ == "__main__":
    main()
