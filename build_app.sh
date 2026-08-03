#!/bin/zsh
# Compila Bóveda, arma el bundle .app, lo firma e instala en /Applications.
# Molde tomado de ~/Documents/TRMFixer/build_app.sh, pero mucho más simple:
# aquí no hay motor Python que congelar, todo el cripto es nativo.
set -e

cd "$(dirname "$0")"
PROYECTO="$PWD"
NOMBRE_APP="Peek a Boo"
# El target de SwiftPM se sigue llamando Boveda; dentro del bundle el binario se
# renombra para que abrir el paquete no delate nada.
PRODUCTO="Boveda"
EJECUTABLE="Peek a Boo"
DESTINO="/Applications/${NOMBRE_APP}.app"
IDENTIDAD="snapsis-dev"

echo "▸ Compilando…"
swift build -c release --product "$PRODUCTO"

echo "▸ Armando el bundle…"
BUNDLE="$PROYECTO/.build/${NOMBRE_APP}.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$PROYECTO/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$PROYECTO/.build/release/$PRODUCTO" "$BUNDLE/Contents/MacOS/$EJECUTABLE"
for icono in AppIcon DocIcon; do
    [ -f "$PROYECTO/Resources/$icono.icns" ] && cp "$PROYECTO/Resources/$icono.icns" "$BUNDLE/Contents/Resources/"
done
# Los clacs del candado. Sin esto `Sonidos` no los encuentra en el bundle y la
# animación va muda — sin fallar, que es peor porque no se nota.
for sonido in abrir cerrar; do
    [ -f "$PROYECTO/Resources/$sonido.wav" ] && cp "$PROYECTO/Resources/$sonido.wav" "$BUNDLE/Contents/Resources/"
done

# Con firma estable (no ad-hoc) los permisos de TCC sobreviven al rebuild.
#
# ⚠ `security find-identity` NO sirve para decidir esto: si al certificado le falta
# el ajuste de confianza (`security add-trusted-cert`) responde «0 valid identities»
# aunque `codesign` sí sepa firmar con él. Pasó en el Mac mini el 3-ago-2026 y el
# script se iba a ad-hoc en silencio — que es justo lo que tira los permisos de TCC
# ya concedidos. La única prueba fiable es intentar una firma de verdad.
SONDA="$(mktemp -d)"
cp /bin/echo "$SONDA/sonda"
if codesign --force --sign "$IDENTIDAD" "$SONDA/sonda" >/dev/null 2>&1; then
    SIGN="$IDENTIDAD"
    echo "  firmando con '$IDENTIDAD' — los permisos sobreviven al rebuild"
else
    SIGN="-"
    echo "  ⚠ No pude firmar con '$IDENTIDAD' — firma ad-hoc, se pierden los permisos ya concedidos."
fi
rm -rf "$SONDA"

# xattr -cr es obligatorio antes de firmar, o codesign falla con
# "resource fork, Finder information, or similar detritus not allowed".
#
# ⚠ Y hay que firmar el bundle YA INSTALADO, no el de .build: si el proyecto vive
# en ~/Documents con iCloud activo, el proveedor de archivos le vuelve a poner
# com.apple.FinderInfo a la carpeta en cuanto se limpia, y la firma nace rota.
# /Applications está fuera de iCloud y ahí sí aguanta.
firmar() {
    xattr -cr "$1"
    codesign --force --sign "$SIGN" "$1"
    codesign --verify --deep --strict "$1"
}

# Durante el desarrollo conviene probar el bundle sin tocar /Applications.
if [[ "$1" == "--sin-instalar" ]]; then
    echo "▸ Firmando en el sitio…"
    firmar "$BUNDLE" || echo "  ⚠ La firma no verifica (¿iCloud reensuciando .build?)"
    echo "✓ Bundle listo (sin instalar): $BUNDLE"
    exit 0
fi

echo "▸ Instalando en $DESTINO…"
rm -rf "$DESTINO"
cp -R "$BUNDLE" "$DESTINO"

echo "▸ Firmando lo instalado…"
firmar "$DESTINO"

echo "✓ Listo: $DESTINO"
