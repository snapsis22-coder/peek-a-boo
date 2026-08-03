#!/bin/bash
# Genera Peek a Boo.dmg con fondo personalizado, layout de iconos y enlace a /Applications.
# Mismo molde que los DMG de Calculadora+ y TRM Fixer. Uso: ./build_dmg.sh
#
# ⚠ Correr SIEMPRE este script, nunca un `hdiutil create` pelado: eso pierde el fondo,
# las posiciones de los iconos y el LÉEME.
set -e

APP="/Applications/Peek a Boo.app"
VOL="Peek a Boo"
BG="$(dirname "$0")/dmg_assets/background.png"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
OUT="$HOME/Desktop/Peek a Boo-$VERSION.dmg"
TMP_DMG="/tmp/PeekaBoo-rw.dmg"
MNT="/Volumes/$VOL"
echo "==> Versión: $VERSION"

echo "==> Limpieza previa"
hdiutil detach "$MNT" >/dev/null 2>&1 || true
rm -f "$TMP_DMG" "$OUT"

# 20m: la app pesa 2,6 MB (todo el cripto es nativo, no hay motor embebido).
echo "==> Creando DMG temporal de lectura/escritura"
hdiutil create -volname "$VOL" -srcfolder "$APP" -fs HFS+ -format UDRW -size 20m "$TMP_DMG"

echo "==> Montando"
hdiutil attach "$TMP_DMG" -mountpoint "$MNT"

echo "==> Enlace a /Applications, fondo y LÉEME"
ln -s /Applications "$MNT/Applications"
mkdir -p "$MNT/.background"
cp "$BG" "$MNT/.background/background.png"
cat > "$MNT/LÉEME.txt" <<'TXT'
Peek a Boo — Made by snapsis

Arrastra la app sobre "Applications".

PRIMERA VEZ QUE LA ABRAS
  1. Doble clic. macOS dirá que no se puede abrir. Cierra el aviso.
  2. Ve a  Ajustes del Sistema > Privacidad y Seguridad
     y baja hasta el mensaje sobre "Peek a Boo".
  3. Pulsa "Abrir de todos modos" y confirma.
  A partir de ahí abre con doble clic como cualquier app.

  (El truco viejo de clic derecho > Abrir YA NO funciona: Apple lo quitó
   en macOS 15.)

  Atajo si prefieres la Terminal, hace lo mismo de una vez:
     xattr -cr "/Applications/Peek a Boo.app"

QUÉ HACE
  • Guarda carpetas y archivos dentro de una bóveda cifrada (AES-256).
  • Lo que metes DESAPARECE del disco: no queda un archivo oculto,
    deja de existir hasta que lo vuelves a sacar.
  • Un interruptor por bóveda para mostrar u ocultar todo su contenido.
  • Funciona también en discos externos, incluso en exFAT.

ANTES DE EMPEZAR, DOS AVISOS
  • NO hay forma de recuperar la contraseña. Si se te olvida, lo que esté
    cifrado se pierde para siempre. No existe puerta trasera: ese es el punto.
  • Mientras una bóveda está en "Visible", sus archivos están descifrados
    sobre el disco. Vuélvela a ocultar cuando termines.

REQUISITOS
  Mac con Apple Silicon (M1/M2/M3/M4) y macOS 14 o superior.
TXT

echo "==> Configurando vista del Finder (mismo layout que Calculadora+ y TRM Fixer)"
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 108
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "Peek a Boo.app" of container window to {165, 245}
        set position of item "Applications" of container window to {495, 245}
        set position of item "LÉEME.txt" of container window to {330, 400}
        set the bounds of container window to {200, 100, 860, 663}
        update without registering applications
        delay 1
        set the bounds of container window to {200, 100, 860, 663}
        update without registering applications
        delay 2
        close
        open
        delay 2
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF

echo "==> Desmontando"
sync
sleep 2
hdiutil detach "$MNT"

echo "==> Comprimiendo a UDZO"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -f "$TMP_DMG"

# Aquí se generaba también un .zip del propio DMG (molde heredado de Calculadora+ y
# TRM Fixer). Quitado a petición del usuario el 3-ago-2026: el DMG ya va comprimido
# (UDZO), así que el zip no ahorra nada y sólo duplica archivos en el Escritorio.

echo "==> Listo:"
ls -lh "$OUT"
