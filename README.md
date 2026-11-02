# Peek a Boo

App nativa de macOS para **cifrar archivos y guardarlos fuera de la vista**, en un solo
archivo contenedor. Nació como reemplazo de [Hider 2](https://macpaw.com/hider) de MacPaw,
que quedó descontinuado, sigue siendo solo-Intel y deja los nombres de tus archivos en
claro dentro de un SQLite.

Escrita en Swift y SwiftUI. Sin dependencias externas: todo el cifrado es CryptoKit y
CommonCrypto del sistema.

## Para quién es

Para quien comparte el Mac —familia, oficina, un técnico que lo repara— y quiere que
ciertos archivos no estén ahí para quien abra el Finder. No es una herramienta contra un
adversario con recursos; es contra la persona que se sienta en tu silla.

## Qué hace

- **Bóveda en un solo archivo.** Todo el contenido vive en un `.peekb`. Un archivo suelto
  se copia, se respalda y se sincroniza sin corromperse a trozos (el bundle-carpeta de
  Hider 2 sí se corrompe al sincronizar).
- **Arrastrar y soltar** para cifrar; extraer, listar y eliminar desde la ventana.
- **Los metadatos también van cifrados.** Nombres, tamaños, categorías y rutas de origen
  no se ven sin la contraseña. Este era el agujero de Hider 2.
- **Cambiar la contraseña es instantáneo**, por grande que sea la bóveda: se vuelve a
  sellar la clave de datos, no se re-cifra el contenido.
- **Freno de fuerza bruta**: 3 intentos libres y luego una espera creciente, de 30 segundos
  hasta 24 horas. Nunca borra nada.

## Diseño criptográfico

```
contraseña ──PBKDF2-SHA256(salt, 600 000)──▶ KEK
                                             │
                    DEK (256 bits al azar) ──┴─ sellada con AES-256-GCM
                    │
                    ▼
  subclave por archivo = HKDF-SHA256(DEK, salt de la entrada, id)
```

- **AES-256-GCM** (cifrado autenticado) en vez del AES-CBC + HMAC del original.
- **Dos slots de cabecera alternantes**: una escritura interrumpida cuesta la última
  operación, nunca el archivo entero.
- Los archivos se trocean en chunks de 1 MiB, cada uno con su subclave. El número de orden
  y la marca de "último" van dentro del dato autenticado, así que **truncar o reordenar
  trozos es detectable**, no solo alterar un byte.

El layout exacto del archivo está documentado en [FORMATO.md](FORMATO.md).

## Qué protege y qué no

Conviene ser claro:

- ✅ Alguien que abra tu Mac y navegue con el Finder no ve el contenido ni los nombres.
- ✅ Un `.peekb` copiado a otra parte no sirve de nada sin la contraseña.
- ⚠️ **La contraseña es todo.** PBKDF2, aunque sea con 600 000 iteraciones, se ataca bien
  con GPU. Una contraseña corta o de diccionario es el punto débil real, no el cifrado.
- ⚠️ En claro queda solo la cabecera: que el archivo es una bóveda, su versión, los
  parámetros de derivación y el tamaño aproximado del contenido.
- ❌ No protege contra alguien con acceso a tu Mac **mientras la bóveda está abierta**.

## Instalar

Descarga el `.dmg` de la sección [Releases](../../releases), ábrelo y arrastra la app a
Applications.

La primera vez macOS avisará que viene de un desarrollador no identificado: clic derecho
sobre la app → **Abrir**, o Ajustes del Sistema › Privacidad y Seguridad › *Abrir de todos
modos*. Es porque está firmada con un certificado propio y no con uno de pago de Apple.

Las versiones siguientes se instalan desde la propia app: al abrir (como mucho una vez al día) o desde el menú **Peek a Boo › Buscar actualizaciones…**, avisa si hay una nueva en Releases y la instala solo si pulsas **Actualizar**. Antes comprueba que el DMG coincida con el hash que publica GitHub y que la app esté firmada con el mismo certificado; la versión vieja va a la Papelera. Como la descarga no pasa por el navegador, macOS no vuelve a pedir *Abrir de todos modos*.

## Compilar

Requiere macOS 14 o superior y las Command Line Tools de Xcode.

```
./build_app.sh                 compila, firma e instala en /Applications
./build_app.sh --sin-instalar
./build_dmg.sh                 arma el DMG
swift run bovedatests          45 pruebas
swift run bovedacli --help     acceso al motor por terminal
```

## Licencia

MIT — ver [LICENSE](LICENSE).
