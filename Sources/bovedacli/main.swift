import BovedaKit
import CommonCrypto
import Foundation

// Herramienta de línea de comandos para ejercitar el motor de Bóveda sin interfaz.
// La contraseña se pide por terminal sin eco; para pruebas automatizadas se puede
// pasar en la variable de entorno BOVEDA_PASSWORD.

// MARK: - Utilidades de terminal

let stderrHandle = FileHandle.standardError

func imprimirError(_ mensaje: String) {
    stderrHandle.write(Data("Error: \(mensaje)\n".utf8))
}

func salirConError(_ mensaje: String) -> Never {
    imprimirError(mensaje)
    exit(1)
}

/// Lee una contraseña sin mostrarla en pantalla.
func leerContrasena(_ prompt: String) -> String {
    if let entorno = ProcessInfo.processInfo.environment["BOVEDA_PASSWORD"] {
        return entorno
    }
    stderrHandle.write(Data(prompt.utf8))

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
            stderrHandle.write(Data("\n".utf8))
        }
    }
    return readLine(strippingNewline: true) ?? ""
}

func leerContrasenaNueva() -> String {
    let primera = leerContrasena("Contraseña nueva: ")
    guard !primera.isEmpty else { salirConError("la contraseña no puede estar vacía.") }
    let segunda = leerContrasena("Repetir contraseña: ")
    guard primera == segunda else { salirConError("las contraseñas no coinciden.") }
    return primera
}

func formatearTamano(_ bytes: UInt64) -> String {
    let formateador = ByteCountFormatter()
    formateador.countStyle = .file
    return formateador.string(fromByteCount: Int64(bytes))
}

let formateadorFecha: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "es_CO")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

/// Acepta el UUID completo, un prefijo suyo, o el nombre exacto del archivo.
func buscarEntrada(_ referencia: String, en boveda: Vault) throws -> VaultEntry {
    let candidatas = boveda.entries.filter {
        $0.id.uuidString.lowercased().hasPrefix(referencia.lowercased()) || $0.name == referencia
    }
    guard let primera = candidatas.first else {
        salirConError("no hay ninguna entrada que corresponda a «\(referencia)».")
    }
    guard candidatas.count == 1 else {
        salirConError("«\(referencia)» corresponde a \(candidatas.count) entradas; usa el identificador completo.")
    }
    return primera
}

func rutaDeArgumento(_ argumento: String) -> URL {
    URL(fileURLWithPath: (argumento as NSString).expandingTildeInPath)
}

func uso() -> Never {
    let texto = """
    Bóveda — motor de cifrado (fase 1, sin interfaz)

    Uso:
      bovedacli crear <boveda>
      bovedacli agregar <boveda> <archivo> [archivo...] [--categoria <nombre>]
      bovedacli listar <boveda>
      bovedacli extraer <boveda> <id|nombre> <destino> [--sobrescribir]
      bovedacli eliminar <boveda> <id|nombre>
      bovedacli compactar <boveda>
      bovedacli cambiar-clave <boveda>
      bovedacli info <boveda>
      bovedacli carpetas <boveda>
      bovedacli mostrar-carpeta <boveda> <id|nombre>
      bovedacli esconder-carpeta <boveda> <id|nombre>
      bovedacli ocultar <boveda>      (flag hidden del Finder, como Hider 2)
      bovedacli mostrar <boveda>
      bovedacli autoprueba [carpeta]

    La contraseña se pide por terminal. Para automatizar, exporta BOVEDA_PASSWORD.
    """
    print(texto)
    exit(1)
}

// MARK: - Subcomandos

func comandoCrear(_ argumentos: [String]) throws {
    guard argumentos.count == 1 else { uso() }
    let url = rutaDeArgumento(argumentos[0])
    let contrasena = leerContrasenaNueva()

    let inicio = Date()
    let boveda = try Vault.create(at: url, password: contrasena)
    try boveda.close()
    // Nace oculta, igual que cuando se crea desde la app: no estorba en la
    // carpeta y no se borra por descuido. Se revierte con «bovedacli mostrar».
    try Vault.ocultar(url, true)
    print("Bóveda creada en \(url.path)")
    print("Oculta en el Finder (visible con Cmd+Shift+. o «bovedacli mostrar»)")
    print("Derivación de clave: \(Vault.defaultIterations) iteraciones PBKDF2-SHA256 " +
          "(\(String(format: "%.2f", Date().timeIntervalSince(inicio))) s)")
}

func comandoAgregar(_ argumentos: [String]) throws {
    guard argumentos.count >= 2 else { uso() }
    var rutas: [String] = []
    var categoria: String?
    var i = 1
    while i < argumentos.count {
        if argumentos[i] == "--categoria", i + 1 < argumentos.count {
            categoria = argumentos[i + 1]
            i += 2
        } else {
            rutas.append(argumentos[i])
            i += 1
        }
    }
    guard !rutas.isEmpty else { uso() }

    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]),
                                password: leerContrasena("Contraseña: "))
    defer { try? boveda.close() }

    for ruta in rutas {
        let url = rutaDeArgumento(ruta)
        var esCarpeta: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &esCarpeta) else {
            salirConError("no existe \(url.path)")
        }

        if esCarpeta.boolValue {
            // Una carpeta se guarda entera y desaparece del disco.
            let carpeta = try boveda.addFolder(at: url) { archivo, hecho, total in
                let porcentaje = total > 0 ? hecho * 100 / total : 0
                stderrHandle.write(Data("\r  [\(porcentaje)%] \(archivo)\u{1B}[K".utf8))
            }
            stderrHandle.write(Data("\r\u{1B}[K".utf8))
            print("Guardada  \(carpeta.name)/  \(carpeta.fileCount) archivos  " +
                  "\(formatearTamano(carpeta.totalSize))  \(carpeta.id.uuidString)")
            print("          la carpeta ya no está en \(carpeta.originalPath)")
        } else {
            let entrada = try boveda.addFile(at: url, category: categoria)
            print("Agregado  \(entrada.name)  \(formatearTamano(entrada.size))  \(entrada.id.uuidString)")
        }
    }
}

func comandoListar(_ argumentos: [String]) throws {
    guard argumentos.count == 1 else { uso() }
    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]),
                                password: leerContrasena("Contraseña: "))
    defer { try? boveda.close() }

    guard !boveda.entries.isEmpty else {
        print("La bóveda está vacía.")
        return
    }
    print("IDENTIFICADOR  TAMAÑO        AGREGADO          CATEGORÍA   NOMBRE")
    for entrada in boveda.entries.sorted(by: { $0.addedAt < $1.addedAt }) {
        let id = String(entrada.id.uuidString.prefix(8))
        let tamano = formatearTamano(entrada.size).padding(toLength: 12, withPad: " ", startingAt: 0)
        let fecha = formateadorFecha.string(from: entrada.addedAt)
        let categoria = (entrada.category ?? "—").padding(toLength: 10, withPad: " ", startingAt: 0)
        print("\(id)       \(tamano)  \(fecha)  \(categoria)  \(entrada.name)")
    }
}

func comandoExtraer(_ argumentos: [String]) throws {
    guard argumentos.count >= 3 else { uso() }
    let sobrescribir = argumentos.contains("--sobrescribir")
    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]),
                                password: leerContrasena("Contraseña: "))
    defer { try? boveda.close() }

    let entrada = try buscarEntrada(argumentos[1], en: boveda)
    var destino = rutaDeArgumento(argumentos[2])
    var esCarpeta: ObjCBool = false
    if FileManager.default.fileExists(atPath: destino.path, isDirectory: &esCarpeta), esCarpeta.boolValue {
        destino = destino.appendingPathComponent(entrada.name)
    }

    try boveda.extract(id: entrada.id, to: destino, overwrite: sobrescribir)
    print("Extraído \(entrada.name) → \(destino.path)")
    print("SHA-256 verificado: \(entrada.sha256.map { String(format: "%02x", $0) }.joined())")
}

func comandoEliminar(_ argumentos: [String]) throws {
    guard argumentos.count == 2 else { uso() }
    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]),
                                password: leerContrasena("Contraseña: "))
    defer { try? boveda.close() }

    let entrada = try buscarEntrada(argumentos[1], en: boveda)
    try boveda.remove(id: entrada.id)
    print("Eliminado \(entrada.name). Usa «compactar» para recuperar el espacio.")
}

func comandoCompactar(_ argumentos: [String]) throws {
    guard argumentos.count == 1 else { uso() }
    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]),
                                password: leerContrasena("Contraseña: "))
    defer { try? boveda.close() }

    let antes = try boveda.stats()
    try boveda.compact()
    let despues = try boveda.stats()
    print("Compactada: \(formatearTamano(antes.fileBytes)) → \(formatearTamano(despues.fileBytes))")
}

func comandoCambiarClave(_ argumentos: [String]) throws {
    guard argumentos.count == 1 else { uso() }
    let actual = leerContrasena("Contraseña actual: ")
    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]), password: actual)
    defer { try? boveda.close() }

    let nueva = leerContrasenaNueva()
    try boveda.changePassword(current: actual, new: nueva)
    print("Contraseña cambiada. El contenido no se volvió a cifrar.")
}

/// Ocultar y mostrar no piden contraseña: es una propiedad del archivo, no del
/// contenido cifrado.
func comandoOcultar(_ argumentos: [String], oculta: Bool) throws {
    guard argumentos.count == 1 else { uso() }
    let url = rutaDeArgumento(argumentos[0])
    try Vault.ocultar(url, oculta)
    if oculta {
        print("Oculta en el Finder: \(url.path)")
        print("⚠️  Sigue siendo visible con Cmd+Shift+. y con «ls -la».")
    } else {
        print("Visible de nuevo: \(url.path)")
    }
}

enum AccionDeCarpeta { case mostrar, esconder }

func comandoCarpetas(_ argumentos: [String]) throws {
    guard argumentos.count == 1 else { uso() }
    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]),
                                password: leerContrasena("Contraseña: "))
    defer { try? boveda.close() }

    guard !boveda.folders.isEmpty else {
        print("No hay carpetas guardadas en esta bóveda.")
        return
    }
    print("IDENTIFICADOR  ESTADO     ARCHIVOS  TAMAÑO        CARPETA")
    for carpeta in boveda.folders {
        let id = String(carpeta.id.uuidString.prefix(8))
        let estado = (carpeta.isDeployed ? "visible" : "guardada").padding(toLength: 9, withPad: " ", startingAt: 0)
        let archivos = String(carpeta.fileCount).padding(toLength: 8, withPad: " ", startingAt: 0)
        let tamano = formatearTamano(carpeta.totalSize).padding(toLength: 12, withPad: " ", startingAt: 0)
        print("\(id)       \(estado)  \(archivos)  \(tamano)  \(carpeta.originalPath)")
    }
}

func comandoCarpeta(_ argumentos: [String], accion: AccionDeCarpeta) throws {
    guard argumentos.count == 2 else { uso() }
    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]),
                                password: leerContrasena("Contraseña: "))
    defer { try? boveda.close() }

    let referencia = argumentos[1].lowercased()
    let candidatas = boveda.folders.filter {
        $0.id.uuidString.lowercased().hasPrefix(referencia) || $0.name.lowercased() == referencia
    }
    guard let carpeta = candidatas.first, candidatas.count == 1 else {
        salirConError("«\(argumentos[1])» no corresponde a exactamente una carpeta.")
    }

    let informar: (String, Int, Int) -> Void = { archivo, hecho, total in
        let porcentaje = total > 0 ? hecho * 100 / total : 0
        stderrHandle.write(Data("\r  [\(porcentaje)%] \(archivo)\u{1B}[K".utf8))
    }

    switch accion {
    case .mostrar:
        try boveda.deployFolder(id: carpeta.id, progress: informar)
        stderrHandle.write(Data("\r\u{1B}[K".utf8))
        print("Visible en \(carpeta.originalPath)")
    case .esconder:
        try boveda.stowFolder(id: carpeta.id, progress: informar)
        stderrHandle.write(Data("\r\u{1B}[K".utf8))
        print("Cifrada y quitada de \(carpeta.originalPath)")
    }
}

func comandoInfo(_ argumentos: [String]) throws {
    guard argumentos.count == 1 else { uso() }
    let boveda = try Vault.open(at: rutaDeArgumento(argumentos[0]),
                                password: leerContrasena("Contraseña: "))
    defer { try? boveda.close() }

    let datos = try boveda.stats()
    print("Archivo:          \(boveda.url.path)")
    print("Entradas:         \(datos.entryCount)")
    print("Contenido:        \(formatearTamano(datos.plainBytes))")
    print("Tamaño en disco:  \(formatearTamano(datos.fileBytes))")
    print("Espacio muerto:   \(formatearTamano(datos.deadBytes))")
    print("Generación:       \(datos.generation)")
}

// MARK: - Autoprueba

func sha256Hex(_ datos: Data) -> String {
    var contexto = CC_SHA256_CTX()
    CC_SHA256_Init(&contexto)
    datos.withUnsafeBytes { _ = CC_SHA256_Update(&contexto, $0.baseAddress, CC_LONG(datos.count)) }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &contexto)
    return digest.map { String(format: "%02x", $0) }.joined()
}

func comandoAutoprueba(_ argumentos: [String]) throws {
    let carpeta = argumentos.first.map(rutaDeArgumento)
        ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("boveda-autoprueba-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: carpeta) }

    let bovedaURL = carpeta.appendingPathComponent("autoprueba.boveda")
    let origen = carpeta.appendingPathComponent("secreto-de-prueba.bin")
    let destino = carpeta.appendingPathComponent("recuperado.bin")
    let contrasena = "contraseña-de-prueba-42"

    // Cinco chunks y pico, para que el troceado tenga trabajo real que hacer.
    let tamano = 5 * 1024 * 1024 + 12_345
    print("1. Generando archivo de prueba de \(formatearTamano(UInt64(tamano)))…")
    var datos = Data(count: tamano)
    datos.withUnsafeMutableBytes { buffer in
        _ = SecRandomCopyBytes(kSecRandomDefault, tamano, buffer.baseAddress!)
    }
    try datos.write(to: origen)
    let hashOriginal = sha256Hex(datos)

    print("2. Creando bóveda (\(Vault.defaultIterations) iteraciones)…")
    var reloj = Date()
    let boveda = try Vault.create(at: bovedaURL, password: contrasena)
    print("   \(String(format: "%.2f", Date().timeIntervalSince(reloj))) s")

    print("3. Cifrando y agregando…")
    reloj = Date()
    let entrada = try boveda.addFile(at: origen, category: "prueba")
    let segundos = Date().timeIntervalSince(reloj)
    print("   \(String(format: "%.2f", segundos)) s " +
          "(\(formatearTamano(UInt64(Double(tamano) / max(segundos, 0.001))))/s)")

    print("4. Extrayendo y verificando…")
    try boveda.extract(id: entrada.id, to: destino)
    let recuperado = try Data(contentsOf: destino)
    guard hashOriginal == sha256Hex(recuperado) else {
        salirConError("¡el contenido recuperado NO coincide con el original!")
    }
    print("   SHA-256 coincide: \(hashOriginal)")

    print("5. Comprobando que no se filtran los metadatos…")
    let crudo = try Data(contentsOf: bovedaURL)
    if crudo.range(of: Data("secreto-de-prueba.bin".utf8)) != nil {
        salirConError("¡el nombre del archivo aparece en claro dentro de la bóveda!")
    }
    print("   El nombre del archivo no aparece en claro.")

    print("6. Rechazando la contraseña equivocada…")
    try boveda.close()
    do {
        _ = try Vault.open(at: bovedaURL, password: "equivocada")
        salirConError("¡la bóveda se abrió con una contraseña incorrecta!")
    } catch BovedaError.contrasenaIncorrecta {
        print("   Rechazada correctamente.")
    }

    print("7. Cambiando la contraseña y reabriendo…")
    let otra = try Vault.open(at: bovedaURL, password: contrasena)
    try otra.changePassword(current: contrasena, new: "contraseña-nueva")
    try otra.close()
    let reabierta = try Vault.open(at: bovedaURL, password: "contraseña-nueva")
    guard try reabierta.extractData(id: entrada.id) == datos else {
        salirConError("¡el contenido cambió tras cambiar la contraseña!")
    }
    print("   Contenido intacto con la contraseña nueva.")

    print("8. Eliminando y compactando…")
    let antes = try reabierta.stats()
    try reabierta.remove(id: entrada.id)
    try reabierta.compact()
    let despues = try reabierta.stats()
    try reabierta.close()
    print("   \(formatearTamano(antes.fileBytes)) → \(formatearTamano(despues.fileBytes))")

    print("\nAutoprueba superada.")
}

// MARK: - Punto de entrada

let argumentos = Array(CommandLine.arguments.dropFirst())
guard let comando = argumentos.first else { uso() }
let resto = Array(argumentos.dropFirst())

do {
    switch comando {
    case "crear":          try comandoCrear(resto)
    case "agregar":        try comandoAgregar(resto)
    case "listar":         try comandoListar(resto)
    case "extraer":        try comandoExtraer(resto)
    case "eliminar":       try comandoEliminar(resto)
    case "compactar":      try comandoCompactar(resto)
    case "cambiar-clave":  try comandoCambiarClave(resto)
    case "info":           try comandoInfo(resto)
    case "carpetas":       try comandoCarpetas(resto)
    case "mostrar-carpeta": try comandoCarpeta(resto, accion: .mostrar)
    case "esconder-carpeta": try comandoCarpeta(resto, accion: .esconder)
    case "ocultar":        try comandoOcultar(resto, oculta: true)
    case "mostrar":        try comandoOcultar(resto, oculta: false)
    case "autoprueba":     try comandoAutoprueba(resto)
    case "-h", "--help", "ayuda": uso()
    default: salirConError("comando desconocido «\(comando)». Usa --help.")
    }
} catch let error as BovedaError {
    salirConError(error.errorDescription ?? "\(error)")
} catch {
    salirConError(error.localizedDescription)
}
