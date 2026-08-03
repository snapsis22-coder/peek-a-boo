import BovedaKit
import Foundation

// Recupera una bóveda borrada leyendo el disco crudo.
//
//   sudo bovedarescate <dispositivo> <inicioEnDisco> <destino> [--listar]
//
// El inicio en disco lo da `rescatar`, que busca las cabeceras.

setvbuf(stdout, nil, _IONBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3 else {
    print("""
    Uso: sudo bovedarescate <dispositivo> <inicioEnDisco> <carpetaDestino> [--listar]

      dispositivo     p. ej. /dev/rdisk6s1
      inicioEnDisco   posición en bytes donde empieza la bóveda
      carpetaDestino  dónde dejar lo recuperado
      --listar        sólo muestra el contenido, sin extraer nada
    """)
    exit(1)
}

let dispositivo = args[0]
guard let inicio = UInt64(args[1]) else {
    print("El inicio en disco debe ser un número de bytes.")
    exit(1)
}
let destino = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
let soloListar = args.contains("--listar")

// MARK: - Acceso al disco

let fd = open(dispositivo, O_RDONLY)
guard fd >= 0 else {
    print("No se pudo abrir \(dispositivo): \(String(cString: strerror(errno)))")
    print("¿Lo ejecutaste con sudo?")
    exit(1)
}
defer { close(fd) }

/// Los dispositivos crudos exigen leer en múltiplos del sector y alineado, así que
/// se lee el bloque que envuelve a lo pedido y se recorta.
func leerDelDisco(_ posicion: UInt64, _ cuantos: Int) throws -> Data {
    let sector = 4096
    let desde = (posicion / UInt64(sector)) * UInt64(sector)
    let desfase = Int(posicion - desde)
    let bruto = ((desfase + cuantos + sector - 1) / sector) * sector

    var buffer = [UInt8](repeating: 0, count: bruto)
    let leidos = buffer.withUnsafeMutableBytes { dst -> Int in
        pread(fd, dst.baseAddress, bruto, off_t(desde))
    }
    guard leidos >= desfase + cuantos else {
        throw NSError(domain: "rescate", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "no se pudo leer en la posición \(posicion)"])
    }
    return Data(buffer[desfase..<(desfase + cuantos)])
}

// MARK: - Contraseña

func pedirContrasena() -> String {
    if let entorno = ProcessInfo.processInfo.environment["BOVEDA_PASSWORD"] { return entorno }
    FileHandle.standardError.write(Data("Contraseña de la bóveda: ".utf8))
    var original = termios()
    let esTerminal = tcgetattr(STDIN_FILENO, &original) == 0
    if esTerminal {
        var silencioso = original
        silencioso.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &silencioso)
    }
    defer {
        if esTerminal {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
    return readLine(strippingNewline: true) ?? ""
}

func tamano(_ bytes: UInt64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
}

// MARK: - Abrir

print("Leyendo la cabecera en la posición \(inicio)…")
let contrasena = pedirContrasena()

let contenido: Rescate.Contenido
do {
    contenido = try Rescate.abrir(inicioEnDisco: inicio, contrasena: contrasena, leer: leerDelDisco)
} catch {
    print("\n✗ No se pudo abrir: \(error.localizedDescription)")
    print("  Si dice «contraseña incorrecta», prueba con otra.")
    print("  Si dice «índice dañado», esa parte del disco fue sobrescrita.")
    exit(1)
}

let totalBytes = contenido.piezas.reduce(UInt64(0)) { $0 + $1.tamano }
print("\n✓ ¡Bóveda abierta! (generación \(contenido.generacion))")
print("  \(contenido.piezas.count) archivos · \(tamano(totalBytes))\n")

// Agrupadas por carpeta, para que se entienda qué había.
let porCarpeta = Dictionary(grouping: contenido.piezas) { $0.carpeta ?? "· sueltos ·" }
for (carpeta, piezas) in porCarpeta.sorted(by: { $0.key < $1.key }) {
    let suma = piezas.reduce(UInt64(0)) { $0 + $1.tamano }
    print("  \(carpeta)  —  \(piezas.count) archivos, \(tamano(suma))")
    for pieza in piezas.prefix(soloListar ? 1000 : 3) {
        print("      \(pieza.rutaRelativa ?? pieza.nombre)  (\(tamano(pieza.tamano)))")
    }
    if !soloListar, piezas.count > 3 { print("      … y \(piezas.count - 3) más") }
}

if soloListar {
    print("\n(sólo listado; para extraer, quita --listar)")
    exit(0)
}

// MARK: - Extraer

print("\nExtrayendo a \(destino.path)…\n")
var rescatados = 0, danados = 0, fallidos = 0
let inicioTiempo = Date()

for (i, pieza) in contenido.piezas.enumerated() {
    // Se respeta la estructura original de carpetas.
    let relativa = pieza.carpeta.map { "\($0)/\(pieza.rutaRelativa ?? pieza.nombre)" }
        ?? (pieza.rutaRelativa ?? pieza.nombre)
    let archivo = destino.appendingPathComponent(relativa)

    do {
        let intacto = try Rescate.extraer(pieza, inicioEnDisco: inicio, a: archivo, leer: leerDelDisco)
        if intacto {
            rescatados += 1
        } else {
            danados += 1
            print("  ⚠︎ \(relativa) — descifrado pero el contenido no cuadra")
        }
    } catch {
        fallidos += 1
        try? FileManager.default.removeItem(at: archivo)
        print("  ✗ \(relativa) — no se pudo recuperar (esa zona fue sobrescrita)")
    }

    if (i + 1) % 25 == 0 || i + 1 == contenido.piezas.count {
        print("  [\(i + 1)/\(contenido.piezas.count)] \(rescatados) recuperados, " +
              "\(danados) dañados, \(fallidos) perdidos")
    }
}

let minutos = Date().timeIntervalSince(inicioTiempo) / 60
print("""

╔══════════════════════════════════════
║ RESULTADO  (\(String(format: "%.1f", minutos)) min)
║   Recuperados intactos : \(rescatados)
║   Dañados parcialmente : \(danados)
║   Perdidos             : \(fallidos)
║   En: \(destino.path)
╚══════════════════════════════════════
""")
