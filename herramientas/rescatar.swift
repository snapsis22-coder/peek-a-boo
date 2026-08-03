import CryptoKit
import Foundation

// Escáner de rescate: busca cabeceras de bóveda en un disco crudo.
//
//   sudo swift herramientas/rescatar.swift /dev/rdisk6s1
//
// Una bóveda borrada sigue en el disco hasta que algo escriba encima. Su cabecera
// son 512 bytes que empiezan por «BOVEDA» y terminan con un SHA-256 de sí mismos,
// así que se puede localizar con total certeza: si el checksum cuadra, es una
// cabecera de verdad y no una coincidencia.
//
// Lo que hay dentro y hace falta para rescatar el contenido:
//   - el salt y las iteraciones del KDF
//   - la clave de datos (DEK) cifrada con la contraseña
//   - dónde estaba el índice dentro del archivo

// Sin esto, `print` no vacía la salida cuando va a un archivo o a una tubería:
// el programa parece colgado aunque esté trabajando.
setvbuf(stdout, nil, _IONBF, 0)

let argumentos = CommandLine.arguments
guard argumentos.count > 1 else {
    print("Uso: sudo swift rescatar.swift /dev/rdiskNsM [gigas a escanear]")
    exit(1)
}
let dispositivo = argumentos[1]
let limiteGB = argumentos.count > 2 ? UInt64(argumentos[2]) ?? 0 : 0

// Lectura de bajo nivel: `FileHandle` reserva y libera el búfer en cada vuelta,
// y sobre un dispositivo crudo eso hunde la velocidad (13 MB/s medidos). Con
// `read(2)` y un búfer reutilizado se va a la velocidad real del disco.
let fd = open(dispositivo, O_RDONLY)
guard fd >= 0 else {
    print("No se pudo abrir \(dispositivo): \(String(cString: strerror(errno)))")
    print("¿Lo ejecutaste con sudo?")
    exit(1)
}
defer { close(fd) }

let magic: [UInt8] = Array("BOVEDA".utf8)
// 8 MB es el punto dulce para dispositivos crudos en macOS.
let tamanoBloque = 8 * 1024 * 1024
let tamanoSlot = 512
var offsetGlobal: UInt64 = 0
var hallazgos = 0
let inicio = Date()

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

func leerLE<T: FixedWidthInteger>(_ t: T.Type, _ d: Data, _ off: Int) -> T {
    var v: T = 0
    withUnsafeMutableBytes(of: &v) { dst in
        d.withUnsafeBytes { src in
            memcpy(dst.baseAddress!, src.baseAddress!.advanced(by: off), MemoryLayout<T>.size)
        }
    }
    return T(littleEndian: v)
}

// Tamaño total, para poder dar porcentaje.
let tamanoTotal: UInt64 = {
    let fin = lseek(fd, 0, SEEK_END)
    lseek(fd, 0, SEEK_SET)
    return fin > 0 ? UInt64(fin) : 0
}()

// Búfer único, alineado a página: se reutiliza en todo el escaneo.
let buffer = UnsafeMutableRawPointer.allocate(byteCount: tamanoBloque, alignment: 4096)
defer { buffer.deallocate() }

print("Escaneando \(dispositivo)")
print("Tamaño: \(tamanoTotal / 1_073_741_824) GB")
print("Buscando cabeceras de bóveda…\n")

var ultimoAviso = Date()

while true {
    if limiteGB > 0, offsetGlobal >= limiteGB * 1_073_741_824 { break }

    let leidos = read(fd, buffer, tamanoBloque)
    if leidos <= 0 {
        if offsetGlobal == 0 {
            print("No se pudo leer el dispositivo: \(String(cString: strerror(errno)))")
            print("Comprueba que lo ejecutaste con sudo y que el disco sigue conectado.")
        }
        break
    }

    do {
        let buf = UnsafeRawBufferPointer(start: buffer, count: leidos)
        do {
            var i = 0
            while i + tamanoSlot <= leidos {
                if buf[i] == magic[0], buf[i+1] == magic[1], buf[i+2] == magic[2],
                   buf[i+3] == magic[3], buf[i+4] == magic[4], buf[i+5] == magic[5] {

                    let slot = Data(bytes: buffer.advanced(by: i), count: tamanoSlot)
                    let esperado = Data(SHA256.hash(data: slot.prefix(480)))
                    if slot.subdata(in: 480..<512) == esperado {
                        hallazgos += 1
                        let posicion = offsetGlobal + UInt64(i)
                        print("\n╔═══ CABECERA VÁLIDA #\(hallazgos) ═══")
                        print("║ posición en el disco : \(posicion) bytes (\(posicion / 1_048_576) MB)")
                        print("║ versión de formato   : \(leerLE(UInt16.self, slot, 6))")
                        print("║ iteraciones PBKDF2   : \(leerLE(UInt32.self, slot, 12))")
                        print("║ generación           : \(leerLE(UInt64.self, slot, 112))")
                        print("║ índice en el archivo : offset \(leerLE(UInt64.self, slot, 120)), " +
                              "largo \(leerLE(UInt64.self, slot, 128))")
                        print("║ salt                 : \(hex(slot.subdata(in: 16..<48)))")
                        print("║ DEK cifrada          : \(hex(slot.subdata(in: 48..<108)))")
                        print("╚═══════════════════════")
                        // El archivo empieza donde está el slot 0.
                        if posicion % 512 == 0 {
                            print("  → inicio probable del archivo: \(posicion) " +
                                  "(o \(posicion >= 512 ? posicion - 512 : 0) si es el slot B)")
                        }
                    }
                }
                i += tamanoSlot
            }
        }
    }

    offsetGlobal += UInt64(leidos)

    // Un aviso cada 5 segundos, con porcentaje y velocidad.
    if Date().timeIntervalSince(ultimoAviso) >= 5 {
        ultimoAviso = Date()
        let gb = Double(offsetGlobal) / 1_073_741_824
        let segundos = Date().timeIntervalSince(inicio)
        let porcentaje = tamanoTotal > 0 ? Double(offsetGlobal) * 100 / Double(tamanoTotal) : 0
        print(String(format: "  %.1f GB revisados (%.1f%%) — %.0f MB/s — %d cabeceras",
                     gb, porcentaje, gb * 1024 / max(segundos, 1), hallazgos))
    }
}

let minutos = Date().timeIntervalSince(inicio) / 60
print("\n\nRevisados \(offsetGlobal / 1_073_741_824) GB en \(String(format: "%.1f", minutos)) min.")
print(hallazgos == 0
      ? "No se encontró ninguna cabecera. La zona donde estaba fue sobrescrita."
      : "Encontradas \(hallazgos) cabeceras válidas.")
