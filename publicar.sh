#!/bin/zsh
# Publica una versión de Peek a Boo en GitHub: prueba, compila, arma el DMG, etiqueta
# y crea la Release con el DMG adjunto para poder descargarlo desde otro Mac.
#
#     ./publicar.sh 0.2.1 "Arreglado el freno de intentos"
#
# El orden importa: las pruebas van PRIMERO. Publicar una versión rota de una app que
# guarda archivos cifrados es mucho más caro que esperar veinte segundos.
set -e

cd "$(dirname "$0")"
VERSION="$1"
NOTAS="${2:-}"

if [[ -z "$VERSION" ]]; then
    echo "uso: ./publicar.sh <versión> [notas]"
    echo "     ./publicar.sh 0.2.1 \"Arreglado el freno de intentos\""
    exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
    echo "✗ No has iniciado sesión en GitHub. Corre una vez:  gh auth login"
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ Hay cambios sin guardar. Haz commit antes de publicar:"
    git status --short
    exit 1
fi

echo "▸ Pruebas…"
swift run bovedatests | tail -3

echo "▸ Poniendo la versión $VERSION en Info.plist…"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" Info.plist
if [[ -n "$(git status --porcelain Info.plist)" ]]; then
    git add Info.plist
    git commit -q -m "Versión $VERSION"
fi

echo "▸ Compilando e instalando…"
./build_app.sh > /dev/null
echo "▸ Armando el DMG…"
./build_dmg.sh > /dev/null
DMG="$HOME/Desktop/Peek a Boo-$VERSION.dmg"
if [[ ! -f "$DMG" ]]; then
    echo "✗ No apareció el DMG en $DMG"
    exit 1
fi

echo "▸ Etiquetando y subiendo…"
git tag -f "v$VERSION"
git push -q origin main
git push -q -f origin "v$VERSION"

echo "▸ Creando la Release…"
if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" --clobber
else
    gh release create "v$VERSION" "$DMG" \
        --title "Peek a Boo $VERSION" \
        --notes "${NOTAS:-Sin notas.}

Descarga el .dmg de abajo, ábrelo y arrastra Peek a Boo a Applications.
La primera vez: clic derecho sobre la app › Abrir, o Ajustes del Sistema ›
Privacidad y Seguridad › «Abrir de todos modos»."
fi

echo "✓ Publicado: $(gh release view "v$VERSION" --json url -q .url)"
