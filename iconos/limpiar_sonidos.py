#!/usr/bin/env python3
"""Recorta el silencio de los extremos y normaliza el nivel.

Las grabaciones traen aire antes y después del golpe. Ese hueco inicial haría
que el sonido llegara tarde respecto a la animación, así que se quita.
"""
import struct
import sys
import wave

UMBRAL = 0.004          # más bajo: conserva la cola, que es lo que suena real
COLA = 0.080            # segundos de margen que se dejan al final
PICO = 0.90


def limpiar(entrada, salida):
    with wave.open(entrada) as w:
        canales, ancho, tasa, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        crudo = w.readframes(n)

    assert ancho == 2, f"se esperaba 16 bits, hay {ancho*8}"
    m = list(struct.unpack(f"<{len(crudo)//2}h", crudo))
    if canales == 2:
        m = [(m[i] + m[i + 1]) / 2 for i in range(0, len(m), 2)]
    m = [v / 32768 for v in m]

    fuertes = [i for i, v in enumerate(m) if abs(v) > UMBRAL]
    if not fuertes:
        print(f"⚠ {entrada}: todo por debajo del umbral, se deja igual")
        recorte = m
    else:
        ini = max(0, fuertes[0] - int(tasa * 0.002))
        fin = min(len(m), fuertes[-1] + int(tasa * COLA))
        recorte = m[ini:fin]

    pico = max(abs(v) for v in recorte) or 1.0
    recorte = [v / pico * PICO for v in recorte]

    with wave.open(salida, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(tasa)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in recorte))

    print(f"✓ {salida}: {len(m)/tasa*1000:.0f} ms → {len(recorte)/tasa*1000:.0f} ms")


limpiar(sys.argv[1], sys.argv[2])
