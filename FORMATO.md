# Formato del archivo `.boveda` — versión 1

Un solo archivo, no un bundle-carpeta (Hider 2 usaba carpeta, lo que se corrompe a
trozos al sincronizar por iCloud). Todo va en little-endian salvo los contadores de
chunk, que son big-endian por estar dentro de un nonce.

```
offset 0     ┌─────────────────────────┐
             │ Slot de cabecera A      │ 512 bytes
offset 512   ├─────────────────────────┤
             │ Slot de cabecera B      │ 512 bytes
offset 1024  ├─────────────────────────┤
             │ Blobs cifrados          │  ← se añaden siempre al final
             │ + índices ya obsoletos  │
             ├─────────────────────────┤
             │ Índice cifrado vigente  │  ← el último bloque del archivo
             └─────────────────────────┘
```

## Cabecera (512 bytes por slot)

| offset | tam | campo |
|---|---|---|
| 0 | 6 | magic `BOVEDA` |
| 6 | 2 | versión de formato (= 1) |
| 8 | 1 | algoritmo de KDF (1 = PBKDF2-SHA256) |
| 9 | 1 | algoritmo de cifrado (1 = AES-256-GCM) |
| 10 | 2 | reservado |
| 12 | 4 | iteraciones de PBKDF2 |
| 16 | 32 | salt del KDF |
| 48 | 60 | DEK sellada: nonce 12 + clave cifrada 32 + tag 16 |
| 108 | 4 | reservado |
| 112 | 8 | generación |
| 120 | 8 | offset del índice |
| 128 | 8 | longitud del índice |
| 136 | 12 | nonce del índice |
| 148 | 332 | reservado (ceros) |
| 480 | 32 | SHA-256 de los bytes 0..<480 |

**Por qué dos slots.** Cada operación escribe el slot que *no* está activo. Al abrir
gana el de generación mayor cuyo checksum cuadre; si ese no descifra, se cae al otro.
Una escritura interrumpida cuesta la última operación, nunca el archivo entero.

## Claves

```
contraseña ──PBKDF2-SHA256(salt, 600 000)──▶ KEK
                                             │
                    DEK (256 bits al azar) ──┴─ sellada con AES-GCM
                                             │   (AAD = bytes 0..<48 de la cabecera)
                    ┌────────────────────────┘
                    ▼
  subclave por archivo = HKDF-SHA256(DEK, salt de la entrada, "boveda-archivo-v1" + id)
```

Cambiar la contraseña vuelve a sellar la DEK con una KEK nueva: **no re-cifra el
contenido**, así que es instantáneo por grande que sea la bóveda.

Usar los bytes 0..<48 como AAD significa que manipular las iteraciones o el salt hace
fallar el desbloqueo, en vez de debilitarlo en silencio.

## Índice

JSON sellado con AES-GCM bajo la DEK. Contiene `generation`, `deadBytes` y las entradas:
`{id, name, size, createdAt, modifiedAt, addedAt, category, tags, sha256, originalPath,
offset, storedLength, chunkSize, keySalt, nonceBase}`.

Va cifrado, así que **los nombres, tamaños, categorías y rutas de origen no son visibles
sin la contraseña** — el defecto de Hider 2, que los dejaba en claro en un SQLite.

AAD del índice = `magic ‖ versión ‖ generación ‖ offset ‖ longitud`. Atarlo a su posición
y generación impide revertir la bóveda a un estado anterior reescribiendo la cabecera.

## Blobs

Cada archivo se trocea en chunks de 1 MiB porque CryptoKit sella en memoria y un archivo
de varios GB no cabe de una vez.

```
chunk i:  AES-GCM(subclave, nonce = nonceBase(8B) ‖ i(4B BE),
                  AAD = id(16B) ‖ i(4B BE) ‖ ¿es el último?(1B))
```

En disco cada chunk ocupa su tamaño en claro + 16 bytes de tag. Un archivo vacío tiene
un chunk vacío pero autenticado, para que no pueda hacerse pasar por "sin datos".

Meter el número de orden y la marca de último en la AAD es lo que hace detectable el
**truncado** y el **reordenamiento** de trozos, no sólo la alteración de un byte.

## Escritura transaccional

1. El blob nuevo se escribe **detrás** del índice vigente — nunca encima de nada.
2. `fsync`.
3. El índice nuevo se escribe detrás del blob.
4. `fsync`.
5. Se escribe el slot de cabecera inactivo. **Esto es lo que confirma la operación.**

Si el proceso muere antes del paso 5, la cabecera anterior sigue apuntando al estado
consistente de antes y los bytes a medio escribir se descartan al reabrir (se trunca al
fin lógico). El precio es espacio muerto: el índice anterior y los blobs borrados quedan
ahí hasta que `compact()` reescribe el contenedor y lo reemplaza atómicamente.

Al abrir se toma un `flock` exclusivo: dos procesos no pueden escribir la misma bóveda.

## Lo que sigue en claro

Sólo la cabecera: que el archivo es una bóveda, su versión, los parámetros del KDF y
el tamaño aproximado del contenido (deducible del tamaño del archivo). El número de
entradas y sus tamaños individuales no son visibles.
