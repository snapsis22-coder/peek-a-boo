#!/usr/bin/env python3
"""Fondo del DMG de Peek a Boo — mismo molde visual que Calculadora+ y TRM Fixer
(gris con gradiente, título oscuro, flecha de acento, firma abajo a la izquierda),
con el acento en el acero azulado del candado de la app.

900×720, más grande que la ventana del Finder a propósito: si el usuario redimensiona,
aparece más gris en vez de blanco.
"""
import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

AQUI = Path(__file__).parent
# Carpeta con los .ttf a usar. Se puede apuntar a otra con la variable de entorno
# BOVEDA_FONTS; por defecto, las del sistema.
FONTS = Path(os.environ.get("BOVEDA_FONTS", "/System/Library/Fonts"))

W, H = 900, 720
# Gradiente gris idéntico al de Calculadora+ y TRM Fixer: #a8a8ad (arriba) → #c8c8cd (abajo)
TOP = (0xA8, 0xA8, 0xAD)
BOT = (0xC8, 0xC8, 0xCD)
OSCURO = (0x2A, 0x2A, 0x30)
GRIS_TEXTO = (0x55, 0x55, 0x5C)
# Acento: el acero azulado del candado de la pantalla de entrada. Oscurecido lo justo
# para que se lea sobre el gris del fondo (el acero claro se perdía).
ACERO = (0x3D, 0x5A, 0x7A)
ACERO_FIRMA = (0x4A, 0x68, 0x88)

img = Image.new("RGB", (W, H))
d = ImageDraw.Draw(img)
for y in range(H):
    t = y / H
    d.line([(0, y), (W, y)], fill=tuple(int(TOP[i] + (BOT[i] - TOP[i]) * t) for i in range(3)))


def fuente(nombre, tam):
    return ImageFont.truetype(str(FONTS / nombre), tam)


# Todo el arte en la zona visible superior-izquierda (la ventana muestra ~660×540)
titulo = fuente("Inter-Bold.ttf", 44)
sub = fuente("Inter-SemiBold.ttf", 20)
firma = fuente("Inter-SemiBold.ttf", 18)

d.text((60, 70), "Peek a Boo", font=titulo, fill=OSCURO)
d.text((62, 128), "Guarda tus carpetas bajo llave", font=sub, fill=GRIS_TEXTO)

# Flecha del app hacia Applications. Los iconos van en y≈245 (x=165 app, x=495
# Applications), así que la flecha va justo en medio.
fy = 245
d.line([(250, fy), (410, fy)], fill=ACERO, width=7)
d.polygon([(410, fy - 16), (440, fy), (410, fy + 16)], fill=ACERO)
d.text((250, fy - 52), "Arrástrala aquí", font=sub, fill=ACERO)

# Firma
d.text((60, 560), "Made by snapsis", font=firma, fill=ACERO_FIRMA)

img.save(AQUI / "background.png")
print(f"✓ background.png {img.size}")
