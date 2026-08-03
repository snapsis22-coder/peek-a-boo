import Foundation
import BovedaKit

// Suite del motor. Se ejecuta con `swift run bovedatests`.
//
// El coste del PBKDF2 se baja a propósito: lo que se verifica aquí es el formato
// y la integridad del contenedor, no la dureza de la derivación de clave.

let arnes = Arnes()

/// Desenvuelve un opcional o falla la prueba con un mensaje claro.
func desenvolver<T>(_ valor: T?) throws -> T {
    guard let valor else { throw FalloDePrueba(description: "se esperaba un valor y no había ninguno") }
    return valor
}
let iteracionesDePrueba: UInt32 = 1_000
let claveDePrueba = "contraseña-de-prueba"

// MARK: - Utilidades

let raiz = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("boveda-pruebas-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: raiz) }

/// Cada caso trabaja en su propia carpeta, para que un fallo no arrastre al siguiente.
func carpetaNueva(_ nombre: String) throws -> URL {
    let url = raiz.appendingPathComponent("\(nombre)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func datosAleatorios(_ contador: Int) -> Data {
    var datos = Data(count: contador)
    datos.withUnsafeMutableBytes { buffer in
        _ = SecRandomCopyBytes(kSecRandomDefault, contador, buffer.baseAddress!)
    }
    return datos
}

func tamanoEnDisco(_ url: URL) throws -> UInt64 {
    let atributos = try FileManager.default.attributesOfItem(atPath: url.path)
    return (atributos[.size] as? NSNumber)?.uint64Value ?? 0
}

/// Invierte un byte del archivo en disco. La bóveda debe estar cerrada.
func alterarByte(en offset: UInt64, de url: URL) throws {
    var crudo = try Data(contentsOf: url)
    crudo[Int(offset)] ^= 0xFF
    try crudo.write(to: url)
}

func cabeceras(de url: URL) throws -> [BovedaDiagnostico.Cabecera] {
    try BovedaDiagnostico.cabeceras(de: url)
}

/// Crea una bóveda nueva en una carpeta limpia y devuelve ambas cosas.
func bovedaNueva(_ nombre: String) throws -> (vault: Vault, url: URL, carpeta: URL) {
    let carpeta = try carpetaNueva(nombre)
    let url = carpeta.appendingPathComponent("prueba.boveda")
    let vault = try Vault.create(at: url, password: claveDePrueba, iterations: iteracionesDePrueba)
    return (vault, url, carpeta)
}

// MARK: - Round-trip

arnes.seccion("Round-trip")

arnes.probar("Un archivo entra y sale idéntico") {
    let (boveda, _, carpeta) = try bovedaNueva("roundtrip")
    let contenido = Data("Contenido secreto de prueba, con acentos: ñáéíóú.".utf8)
    let origen = carpeta.appendingPathComponent("nota.txt")
    try contenido.write(to: origen)

    let entrada = try boveda.addFile(at: origen)
    try esperarIgual(entrada.name, "nota.txt", "el nombre de la entrada")
    try esperarIgual(entrada.size, UInt64(contenido.count), "el tamaño de la entrada")

    let destino = carpeta.appendingPathComponent("recuperado.txt")
    try boveda.extract(id: entrada.id, to: destino)
    try esperarIgual(try Data(contentsOf: destino), contenido, "el contenido recuperado")
    try boveda.close()
}

arnes.probar("Contenido de varios chunks, con un resto que no cuadra en el límite") {
    let (boveda, _, _) = try bovedaNueva("multichunk")
    let contenido = datosAleatorios(Int(BovedaDiagnostico.tamanoDeChunk) * 2 + 7_777)
    let entrada = try boveda.addData(contenido, name: "grande.bin")

    try esperarIgual(BovedaDiagnostico.ubicacion(de: entrada).longitud,
                     BovedaDiagnostico.longitudAlmacenada(tamano: entrada.size,
                                                          chunkSize: BovedaDiagnostico.ubicacion(de: entrada).chunkSize),
                     "el tamaño almacenado")
    try esperarIgual(try boveda.extractData(id: entrada.id), contenido, "el contenido recuperado")
    try boveda.close()
}

arnes.probar("Un archivo vacío se guarda y se recupera") {
    let (boveda, _, _) = try bovedaNueva("vacio")
    let entrada = try boveda.addData(Data(), name: "vacio.txt")
    try esperarIgual(entrada.size, 0, "el tamaño")
    try esperarIgual(try boveda.extractData(id: entrada.id), Data(), "el contenido")
    try boveda.close()
}

arnes.probar("El contenido y los metadatos sobreviven al cierre") {
    let (boveda, url, _) = try bovedaNueva("persistencia")
    let uno = datosAleatorios(3_000)
    let dos = datosAleatorios(50_000)
    let a = try boveda.addData(uno, name: "uno.bin", category: "documentos")
    let b = try boveda.addData(dos, name: "dos.bin", tags: ["personal", "2026"])
    try boveda.close()

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperarIgual(reabierta.entries.count, 2, "el número de entradas")
    try esperarIgual(try reabierta.extractData(id: a.id), uno, "el contenido de la primera")
    try esperarIgual(try reabierta.extractData(id: b.id), dos, "el contenido de la segunda")
    try esperarIgual(try reabierta.entry(id: a.id).category, "documentos", "la categoría")
    try esperarIgual(try reabierta.entry(id: b.id).tags, ["personal", "2026"], "las etiquetas")
    try reabierta.close()
}

// MARK: - Contraseña

arnes.seccion("Contraseña")

arnes.probar("Una contraseña equivocada no abre la bóveda") {
    let (boveda, url, _) = try bovedaNueva("clave-mala")
    try boveda.addData(datosAleatorios(1_000), name: "x.bin")
    try boveda.close()

    try esperarError(.contrasenaIncorrecta, "al abrir con otra contraseña") {
        _ = try Vault.open(at: url, password: "otra-cosa")
    }
}

arnes.probar("No se puede crear una bóveda sin contraseña") {
    let carpeta = try carpetaNueva("sin-clave")
    try esperarError(.contrasenaVacia, "al crear sin contraseña") {
        _ = try Vault.create(at: carpeta.appendingPathComponent("x.boveda"), password: "")
    }
}

arnes.probar("Cambiar la contraseña conserva el contenido") {
    let (boveda, url, _) = try bovedaNueva("cambio-clave")
    let contenido = datosAleatorios(200_000)
    let entrada = try boveda.addData(contenido, name: "secreto.bin")
    try boveda.changePassword(current: claveDePrueba, new: "clave-nueva")
    try boveda.close()

    try esperarError(.contrasenaIncorrecta, "al abrir con la contraseña vieja") {
        _ = try Vault.open(at: url, password: claveDePrueba)
    }

    let reabierta = try Vault.open(at: url, password: "clave-nueva")
    try esperarIgual(try reabierta.extractData(id: entrada.id), contenido, "el contenido")
    try reabierta.close()
}

arnes.probar("Cambiar la contraseña exige acertar la actual") {
    let (boveda, _, _) = try bovedaNueva("cambio-clave-mala")
    try esperarError(.contrasenaIncorrecta, "al cambiar con la contraseña actual equivocada") {
        try boveda.changePassword(current: "no-es", new: "otra")
    }
    try boveda.close()
}

// MARK: - Integridad

arnes.seccion("Integridad")

arnes.probar("Un archivo cualquiera no se confunde con una bóveda") {
    let carpeta = try carpetaNueva("no-boveda")
    let url = carpeta.appendingPathComponent("falsa.boveda")
    try Data("esto no es una bóveda, es texto suelto".utf8).write(to: url)
    try esperarError(.noEsUnaBoveda, "al abrir un archivo cualquiera") {
        _ = try Vault.open(at: url, password: claveDePrueba)
    }
}

arnes.probar("Alterar un byte del contenido cifrado se detecta") {
    let (boveda, url, _) = try bovedaNueva("blob-alterado")
    let entrada = try boveda.addData(datosAleatorios(10_000), name: "importante.bin")
    try boveda.close()

    try alterarByte(en: BovedaDiagnostico.ubicacion(de: entrada).offset + 100, de: url)

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperarError(.datosCorruptos("importante.bin"), "al extraer contenido manipulado") {
        _ = try reabierta.extractData(id: entrada.id)
    }
    try reabierta.close()
}

arnes.probar("Alterar el índice más reciente hace caer al estado anterior") {
    // El índice viejo sigue en el archivo y su cabecera sigue siendo válida, así
    // que manipular el más nuevo cuesta la última operación, no la bóveda.
    let (boveda, url, _) = try bovedaNueva("indice-alterado")
    try boveda.addData(datosAleatorios(5_000), name: "algo.bin")
    try boveda.close()

    guard let activa = try cabeceras(de: url).max(by: { $0.generacion < $1.generacion }) else {
        throw FalloDePrueba(description: "no se pudo leer ninguna cabecera")
    }
    try alterarByte(en: activa.offsetDelIndice + 10, de: url)

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperarIgual(reabierta.entries.count, 0, "debe volver a la bóveda vacía anterior")
    try reabierta.close()
}

arnes.probar("Si ningún índice descifra, la apertura falla en vez de mentir") {
    // Tras cambiar la contraseña los dos slots apuntan al mismo índice, así que
    // manipularlo deja la bóveda sin ninguna copia válida a la que caer.
    let (boveda, url, _) = try bovedaNueva("indice-sin-respaldo")
    try boveda.addData(datosAleatorios(5_000), name: "algo.bin")
    try boveda.changePassword(current: claveDePrueba, new: "clave-nueva")
    try boveda.close()

    let todas = try cabeceras(de: url)
    try esperarIgual(todas.count, 2, "el número de slots válidos")
    try esperar(todas[0].offsetDelIndice == todas[1].offsetDelIndice,
                "los dos slots deberían apuntar al mismo índice tras cambiar la contraseña")
    try alterarByte(en: todas[0].offsetDelIndice + 10, de: url)

    try esperarError(.indiceCorrupto, "al abrir sin ningún índice válido") {
        _ = try Vault.open(at: url, password: "clave-nueva")
    }
}

arnes.probar("Reordenar los chunks de un archivo se detecta") {
    // Cada chunk se autentica con su número de orden, así que intercambiar dos
    // trozos se detecta aunque ninguno de los dos haya sido alterado.
    let (boveda, url, _) = try bovedaNueva("chunks-reordenados")
    let bloque = Int(BovedaDiagnostico.tamanoDeChunk)
    let entrada = try boveda.addData(datosAleatorios(bloque * 2), name: "dos-chunks.bin")
    try boveda.close()

    let sellado = bloque + BovedaDiagnostico.longitudDeTag
    var crudo = try Data(contentsOf: url)
    let inicio = Int(BovedaDiagnostico.ubicacion(de: entrada).offset)
    let primero = Data(crudo[inicio..<(inicio + sellado)])
    let segundo = Data(crudo[(inicio + sellado)..<(inicio + sellado * 2)])
    crudo.replaceSubrange(inicio..<(inicio + sellado), with: segundo)
    crudo.replaceSubrange((inicio + sellado)..<(inicio + sellado * 2), with: primero)
    try crudo.write(to: url)

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperarError(.datosCorruptos("dos-chunks.bin"), "al extraer con los chunks intercambiados") {
        _ = try reabierta.extractData(id: entrada.id)
    }
    try reabierta.close()
}

arnes.probar("Los nombres y categorías no quedan en claro en el archivo") {
    // El defecto de Hider 2 que este formato arregla.
    let (boveda, url, _) = try bovedaNueva("sin-fugas")
    try boveda.addData(datosAleatorios(4_000),
                       name: "declaracion-de-renta-2026.pdf",
                       category: "impuestos")
    try boveda.close()

    let crudo = try Data(contentsOf: url)
    try esperar(crudo.range(of: Data("declaracion-de-renta-2026.pdf".utf8)) == nil,
                "el nombre del archivo aparece en claro dentro de la bóveda")
    try esperar(crudo.range(of: Data("impuestos".utf8)) == nil,
                "la categoría aparece en claro dentro de la bóveda")
}

// MARK: - Borrado y compactación

arnes.seccion("Borrado y compactación")

arnes.probar("Eliminar y compactar recupera el espacio sin tocar lo demás") {
    let (boveda, url, _) = try bovedaNueva("compactar")
    let a = try boveda.addData(datosAleatorios(300_000), name: "a.bin")
    let contenidoB = datosAleatorios(120_000)
    let b = try boveda.addData(contenidoB, name: "b.bin")

    let antes = try boveda.stats()
    try boveda.remove(id: a.id)
    try esperarIgual(boveda.entries.count, 1, "el número de entradas tras eliminar")
    try esperarError(.entradaNoEncontrada(a.id), "al extraer lo eliminado") {
        _ = try boveda.extractData(id: a.id)
    }

    try boveda.compact()
    let despues = try boveda.stats()
    try esperar(despues.fileBytes < antes.fileBytes,
                "el archivo no encogió: \(antes.fileBytes) → \(despues.fileBytes)")
    try esperarIgual(despues.deadBytes, 0, "el espacio muerto tras compactar")

    // Lo que quedó sigue siendo legible, ya en su posición nueva.
    try esperarIgual(try boveda.extractData(id: b.id), contenidoB, "el contenido superviviente")
    try boveda.close()

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperarIgual(reabierta.entries.count, 1, "el número de entradas al reabrir")
    try esperarIgual(try reabierta.extractData(id: b.id), contenidoB, "el contenido al reabrir")
    try reabierta.close()
}

arnes.probar("Compactar no deja la bóveda a la vista") {
    let (boveda, url, _) = try bovedaNueva("compactar-oculta")
    let a = try boveda.addData(datosAleatorios(50_000), name: "a.bin")
    try Vault.ocultar(url, true)
    try esperar(try Vault.estaOculta(url), "la bóveda no quedó oculta antes de compactar")

    // Compactar sustituye el archivo entero: el flag se perdía en el cambiazo.
    try boveda.remove(id: a.id)
    try boveda.compact()
    try esperar(try Vault.estaOculta(url), "compactar dejó la bóveda a la vista")
    try boveda.close()
}

arnes.probar("Una bóveda visible sigue visible tras compactar") {
    let (boveda, url, _) = try bovedaNueva("compactar-visible")
    let a = try boveda.addData(datosAleatorios(50_000), name: "a.bin")
    try esperar(!(try Vault.estaOculta(url)), "la bóveda no debería nacer oculta aquí")

    try boveda.remove(id: a.id)
    try boveda.compact()
    try esperar(!(try Vault.estaOculta(url)), "compactar ocultó una bóveda que estaba visible")
    try boveda.close()
}

// MARK: - Robustez del contenedor

arnes.seccion("Robustez del contenedor")

arnes.probar("Una escritura a medias se descarta al abrir") {
    // Bytes sueltos al final: un blob que se quedó a medias sin llegar a confirmarse.
    let (boveda, url, _) = try bovedaNueva("escritura-a-medias")
    let contenido = datosAleatorios(9_000)
    let entrada = try boveda.addData(contenido, name: "bueno.bin")
    try boveda.close()

    let tamanoBueno = try tamanoEnDisco(url)
    let manejador = try FileHandle(forUpdating: url)
    try manejador.seekToEnd()
    try manejador.write(contentsOf: datosAleatorios(50_000))
    try manejador.close()

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperarIgual(reabierta.entries.count, 1, "el número de entradas")
    try esperarIgual(try reabierta.extractData(id: entrada.id), contenido, "el contenido")
    try reabierta.close()
    try esperarIgual(try tamanoEnDisco(url), tamanoBueno, "el tamaño del archivo tras descartar la basura")
}

arnes.probar("Un slot de cabecera dañado cae al anterior") {
    // Se pierde la última operación, no el archivo entero.
    let (boveda, url, _) = try bovedaNueva("cabecera-danada")
    let contenidoA = datosAleatorios(4_000)
    let a = try boveda.addData(contenidoA, name: "a.bin")
    let b = try boveda.addData(datosAleatorios(4_000), name: "b.bin")
    try boveda.close()

    let todas = try cabeceras(de: url)
    try esperarIgual(todas.count, 2, "el número de slots de cabecera válidos")
    guard let reciente = todas.max(by: { $0.generacion < $1.generacion }) else {
        throw FalloDePrueba(description: "no se pudo identificar el slot más reciente")
    }

    try alterarByte(en: UInt64(reciente.slot * BovedaDiagnostico.tamanoDeSlot + BovedaDiagnostico.desplazamientoDelChecksum), de: url)

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperarIgual(reabierta.entries.count, 1, "debe volver al estado anterior")
    try esperarIgual(try reabierta.extractData(id: a.id), contenidoA, "el contenido que sí se confirmó")
    try esperarError(.entradaNoEncontrada(b.id), "la última operación debe haberse perdido") {
        _ = try reabierta.extractData(id: b.id)
    }
    try reabierta.close()
}

// Estas dos sostienen una decisión de la interfaz: «otra contraseña» y «dañada»
// no pueden confundirse. Si se confundieran, se le ofrecería «Recrear…» a una
// bóveda sana y bastaría un dedazo para apartar el contenido bueno.
arnes.probar("Una contraseña errónea se reporta como tal, no como daño") {
    let (boveda, url, _) = try bovedaNueva("contrasena-mala")
    _ = try boveda.addData(datosAleatorios(2_000), name: "algo.bin")
    try boveda.close()

    try esperarError(.contrasenaIncorrecta, "al abrir con otra contraseña") {
        _ = try Vault.open(at: url, password: claveDePrueba + "-no-es")
    }
}

arnes.probar("Una cabecera destrozada NO se confunde con contraseña errónea") {
    let (boveda, url, _) = try bovedaNueva("cabecera-destrozada")
    _ = try boveda.addData(datosAleatorios(2_000), name: "algo.bin")
    try boveda.close()

    // Los dos slots a la basura: ya no hay ninguna cabecera válida a la que caer.
    let manejador = try FileHandle(forUpdating: url)
    try manejador.seek(toOffset: 0)
    try manejador.write(contentsOf: datosAleatorios(2 * BovedaDiagnostico.tamanoDeSlot))
    try manejador.close()

    do {
        _ = try Vault.open(at: url, password: claveDePrueba)
        throw FalloDePrueba(description: "una bóveda sin cabecera válida no debería abrirse")
    } catch let fallo as FalloDePrueba {
        throw fallo
    } catch let error as BovedaError {
        try esperar(error != .contrasenaIncorrecta,
                    "un archivo roto se reportó como contraseña incorrecta: la interfaz lo trataría como bóveda sana")
    }
}

arnes.probar("Dos procesos no pueden abrir la misma bóveda a la vez") {
    let (boveda, url, _) = try bovedaNueva("bloqueo")
    defer { try? boveda.close() }
    try esperarError(.bovedaEnUso, "al abrir por segunda vez") {
        _ = try Vault.open(at: url, password: claveDePrueba)
    }
}

arnes.probar("Crear no pisa una bóveda existente") {
    let (boveda, url, _) = try bovedaNueva("no-pisar")
    try boveda.close()
    try esperarError(.yaExiste(url), "al crear encima de otra bóveda") {
        _ = try Vault.create(at: url, password: claveDePrueba, iterations: iteracionesDePrueba)
    }
}

arnes.probar("Operar sobre una bóveda cerrada falla claramente") {
    let (boveda, _, _) = try bovedaNueva("cerrada")
    try boveda.close()
    try esperarError(.bovedaCerrada, "al agregar en una bóveda cerrada") {
        _ = try boveda.addData(Data([1, 2, 3]), name: "x")
    }
}

// MARK: - Carpetas gestionadas (el modelo de Hider 2)

arnes.seccion("Carpetas gestionadas")

/// Crea una carpeta con subcarpetas y contenido conocido.
func carpetaDePrueba(_ base: URL) throws -> (url: URL, contenido: [String: Data]) {
    let carpeta = base.appendingPathComponent("Privado")
    try FileManager.default.createDirectory(at: carpeta.appendingPathComponent("fotos"),
                                            withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: carpeta.appendingPathComponent("docs/2026"),
                                            withIntermediateDirectories: true)
    var contenido: [String: Data] = [
        "nota.txt": Data("texto en la raíz".utf8),
        "fotos/playa.jpg": datosAleatorios(40_000),
        "docs/2026/renta.pdf": datosAleatorios(120_000),
    ]
    contenido["video.mov"] = datosAleatorios(Int(BovedaDiagnostico.tamanoDeChunk) + 5_000)
    for (relativa, datos) in contenido {
        try datos.write(to: carpeta.appendingPathComponent(relativa))
    }
    return (carpeta, contenido)
}

func leerCarpeta(_ carpeta: URL) throws -> [String: Data] {
    var resultado: [String: Data] = [:]
    let prefijo = carpeta.standardizedFileURL.path
    guard let e = FileManager.default.enumerator(at: carpeta,
                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles]) else { return [:] }
    for caso in e {
        guard let url = caso as? URL,
              (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
        let completa = url.standardizedFileURL.path
        resultado[String(completa.dropFirst(prefijo.count + 1))] = try Data(contentsOf: url)
    }
    return resultado
}

arnes.probar("Guardar una carpeta la hace desaparecer del disco") {
    let (boveda, _, base) = try bovedaNueva("carpeta-guardar")
    let (carpeta, contenido) = try carpetaDePrueba(base)

    let registro = try boveda.addFolder(at: carpeta)
    try esperarIgual(registro.fileCount, contenido.count, "el número de archivos guardados")
    try esperar(!FileManager.default.fileExists(atPath: carpeta.path),
                "la carpeta debería haber desaparecido del disco")
    try esperar(!registro.isDeployed, "debería quedar marcada como guardada")
    try esperarIgual(boveda.folders.count, 1, "las carpetas gestionadas")
    try boveda.close()
}

arnes.probar("Desplegarla la devuelve intacta a su ruta original") {
    let (boveda, url, base) = try bovedaNueva("carpeta-desplegar")
    let (carpeta, contenido) = try carpetaDePrueba(base)
    let registro = try boveda.addFolder(at: carpeta)
    try boveda.close()

    // Se reabre para comprobar que el estado sobrevive al cierre.
    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try reabierta.deployFolder(id: registro.id)
    try esperar(FileManager.default.fileExists(atPath: carpeta.path),
                "la carpeta debería haber vuelto a existir")

    let recuperado = try leerCarpeta(carpeta)
    try esperarIgual(recuperado.count, contenido.count, "el número de archivos restaurados")
    for (relativa, datos) in contenido {
        try esperarIgual(recuperado[relativa], datos, "el contenido de \(relativa)")
    }
    try esperar(reabierta.folders[0].isDeployed, "debería quedar marcada como desplegada")
    try reabierta.close()
}

arnes.probar("Volver a guardarla recoge los cambios hechos mientras estaba visible") {
    let (boveda, _, base) = try bovedaNueva("carpeta-cambios")
    let (carpeta, _) = try carpetaDePrueba(base)
    let registro = try boveda.addFolder(at: carpeta)
    try boveda.deployFolder(id: registro.id)

    // El usuario trabaja con la carpeta abierta: añade, cambia y borra.
    let nuevo = Data("archivo nuevo mientras estaba abierta".utf8)
    try nuevo.write(to: carpeta.appendingPathComponent("agregado.txt"))
    try FileManager.default.removeItem(at: carpeta.appendingPathComponent("nota.txt"))
    let cambiado = datosAleatorios(9_000)
    try cambiado.write(to: carpeta.appendingPathComponent("fotos/playa.jpg"))

    try boveda.stowFolder(id: registro.id)
    try esperar(!FileManager.default.fileExists(atPath: carpeta.path),
                "debería volver a desaparecer del disco")

    try boveda.deployFolder(id: registro.id)
    let recuperado = try leerCarpeta(carpeta)
    try esperarIgual(recuperado["agregado.txt"], nuevo, "el archivo añadido")
    try esperarIgual(recuperado["fotos/playa.jpg"], cambiado, "el archivo modificado")
    try esperar(recuperado["nota.txt"] == nil, "el archivo borrado no debería volver")
    try boveda.close()
}

arnes.probar("Liberarla la deja visible y fuera de la bóveda") {
    let (boveda, _, base) = try bovedaNueva("carpeta-liberar")
    let (carpeta, contenido) = try carpetaDePrueba(base)
    let registro = try boveda.addFolder(at: carpeta)

    try boveda.releaseFolder(id: registro.id)
    try esperar(FileManager.default.fileExists(atPath: carpeta.path),
                "la carpeta debería quedar en el disco")
    try esperarIgual(try leerCarpeta(carpeta).count, contenido.count, "los archivos que quedan fuera")
    try esperarIgual(boveda.folders.count, 0, "no debería quedar gestionada")
    try esperarIgual(boveda.entries.count, 0, "no debería quedar contenido cifrado suyo")
    try boveda.close()
}

arnes.probar("Los archivos sueltos no se mezclan con los de carpetas") {
    let (boveda, _, base) = try bovedaNueva("carpeta-sueltos")
    let (carpeta, _) = try carpetaDePrueba(base)
    try boveda.addData(datosAleatorios(1_000), name: "suelto.bin")
    let registro = try boveda.addFolder(at: carpeta)

    try esperarIgual(boveda.looseEntries.count, 1, "los archivos sueltos")
    try esperarIgual(boveda.entries(inFolder: registro.id).count, 4, "los archivos de la carpeta")
    try boveda.close()
}

arnes.probar("No se puede guardar dos veces la misma carpeta") {
    let (boveda, _, base) = try bovedaNueva("carpeta-duplicada")
    let (carpeta, _) = try carpetaDePrueba(base)
    let registro = try boveda.addFolder(at: carpeta, removeOriginal: false)
    _ = registro
    try esperarError(.carpetaYaGestionada("Privado"), "al añadir la misma carpeta otra vez") {
        _ = try boveda.addFolder(at: carpeta)
    }
    try boveda.close()
}

arnes.probar("Desplegar no pisa una carpeta que ya exista en esa ruta") {
    let (boveda, _, base) = try bovedaNueva("carpeta-colision")
    let (carpeta, _) = try carpetaDePrueba(base)
    let registro = try boveda.addFolder(at: carpeta)

    // Alguien creó algo con el mismo nombre mientras estaba guardada.
    try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    try Data("no me pises".utf8).write(to: carpeta.appendingPathComponent("importante.txt"))

    let comoLaVeLaBoveda = URL(fileURLWithPath: carpeta.path, isDirectory: true)
    try esperarError(.yaExiste(comoLaVeLaBoveda), "al desplegar sobre algo existente") {
        try boveda.deployFolder(id: registro.id)
    }
    try esperarIgual(try Data(contentsOf: carpeta.appendingPathComponent("importante.txt")),
                     Data("no me pises".utf8), "el archivo ajeno debe seguir intacto")
    try boveda.close()
}

arnes.probar("Un archivo suelto también desaparece del disco al guardarlo") {
    // Lo que entra en la bóveda deja de estar fuera, sean carpetas o archivos.
    let (boveda, _, base) = try bovedaNueva("archivo-se-mueve")
    let suelto = base.appendingPathComponent("documento.dmg")
    let contenido = datosAleatorios(40_000)
    try contenido.write(to: suelto)

    let entrada = try boveda.addFile(at: suelto, removeOriginal: true)
    try esperar(!FileManager.default.fileExists(atPath: suelto.path),
                "el archivo original debería haber desaparecido")
    try esperarIgual(try boveda.extractData(id: entrada.id), contenido,
                     "el contenido guardado")
    try boveda.close()
}

arnes.probar("Sin removeOriginal el archivo se queda donde está") {
    let (boveda, _, base) = try bovedaNueva("archivo-se-copia")
    let suelto = base.appendingPathComponent("copia.txt")
    try Data("no me muevas".utf8).write(to: suelto)

    try boveda.addFile(at: suelto)
    try esperar(FileManager.default.fileExists(atPath: suelto.path),
                "el original debería seguir en su sitio")
    try boveda.close()
}

// MARK: - El interruptor Visible / Oculta

arnes.seccion("Interruptor de la bóveda")

arnes.probar("Visible devuelve TODO a su ruta original, carpetas y archivos") {
    let (boveda, _, base) = try bovedaNueva("interruptor")
    let (carpeta, contenidoCarpeta) = try carpetaDePrueba(base)
    let suelto = base.appendingPathComponent("factura.pdf")
    let contenidoSuelto = datosAleatorios(30_000)
    try contenidoSuelto.write(to: suelto)

    try boveda.addFolder(at: carpeta)
    try boveda.addFile(at: suelto, removeOriginal: true)

    // Todo escondido: ni la carpeta ni el archivo existen en el disco.
    try esperar(boveda.visibilidad == .oculta, "la bóveda debería estar oculta")
    try esperar(!FileManager.default.fileExists(atPath: carpeta.path), "la carpeta no debería estar")
    try esperar(!FileManager.default.fileExists(atPath: suelto.path), "el archivo no debería estar")

    try boveda.makeVisible()
    try esperar(boveda.visibilidad == .visible, "la bóveda debería estar visible")
    try esperarIgual(try Data(contentsOf: suelto), contenidoSuelto, "el archivo devuelto a su ruta")
    let recuperado = try leerCarpeta(carpeta)
    for (relativa, datos) in contenidoCarpeta {
        try esperarIgual(recuperado[relativa], datos, "el contenido de \(relativa)")
    }
    try boveda.close()
}

arnes.probar("Al hacerse visible, la copia cifrada sigue dentro") {
    let (boveda, url, base) = try bovedaNueva("copia-se-queda")
    let suelto = base.appendingPathComponent("importante.txt")
    let contenido = Data("esto no se puede perder".utf8)
    try contenido.write(to: suelto)
    let entrada = try boveda.addFile(at: suelto, removeOriginal: true)

    try boveda.makeVisible()
    // Alguien borra el archivo de fuera mientras está visible.
    try FileManager.default.removeItem(at: suelto)
    // La copia cifrada debe seguir siendo recuperable.
    try esperarIgual(try boveda.extractData(id: entrada.id), contenido,
                     "la copia dentro de la bóveda")
    try boveda.close()

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperarIgual(try reabierta.extractData(id: entrada.id), contenido,
                     "la copia tras reabrir")
    try reabierta.close()
}

arnes.probar("Ocultar recoge los cambios hechos mientras estaba visible") {
    let (boveda, _, base) = try bovedaNueva("ocultar-cambios")
    let suelto = base.appendingPathComponent("notas.txt")
    try Data("versión uno".utf8).write(to: suelto)
    let entrada = try boveda.addFile(at: suelto, removeOriginal: true)

    try boveda.makeVisible()
    try Data("versión dos, editada fuera".utf8).write(to: suelto)
    try boveda.makeHidden()

    try esperar(!FileManager.default.fileExists(atPath: suelto.path),
                "el archivo debería haber desaparecido otra vez")
    try esperar(boveda.visibilidad == .oculta, "la bóveda debería estar oculta")

    // La entrada se reemplazó por la versión nueva.
    let actual = try desenvolver(boveda.looseEntries.first)
    try esperarIgual(try boveda.extractData(id: actual.id),
                     Data("versión dos, editada fuera".utf8), "el contenido actualizado")
    _ = entrada
    try boveda.close()
}

arnes.probar("El estado del interruptor sobrevive al cierre") {
    let (boveda, url, base) = try bovedaNueva("estado-persiste")
    let (carpeta, _) = try carpetaDePrueba(base)
    try boveda.addFolder(at: carpeta)
    try boveda.makeVisible()
    try boveda.close()

    let reabierta = try Vault.open(at: url, password: claveDePrueba)
    try esperar(reabierta.visibilidad == .visible, "debería seguir visible tras reabrir")
    try reabierta.makeHidden()
    try esperar(reabierta.visibilidad == .oculta, "y poder volver a ocultarse")
    try esperar(!FileManager.default.fileExists(atPath: carpeta.path), "la carpeta se fue del disco")
    try reabierta.close()
}

// MARK: - Freno a los intentos fallidos

arnes.seccion("Intentos fallidos")

arnes.probar("Los primeros fallos no hacen esperar") {
    let control = ControlDeIntentos(almacen: IntentosEnMemoria())
    let ahora = Date()
    for _ in 1...ControlDeIntentos.intentosLibres {
        try esperarIgual(control.registrarFallo(ahora: ahora), 0, "todavía sin castigo")
    }
    try esperar(!control.estaBloqueado(ahora: ahora), "no debería estar bloqueado aún")
}

arnes.probar("Pasado el margen, la espera crece con cada fallo") {
    let control = ControlDeIntentos(almacen: IntentosEnMemoria())
    let ahora = Date()
    for _ in 1...ControlDeIntentos.intentosLibres { control.registrarFallo(ahora: ahora) }

    var anterior: TimeInterval = 0
    for escalon in ControlDeIntentos.escalera {
        let espera = control.registrarFallo(ahora: ahora)
        try esperarIgual(espera, escalon, "el escalón que toca")
        try esperar(espera > anterior, "cada espera tiene que ser mayor que la de antes")
        anterior = espera
    }
}

arnes.probar("La última espera es de 24 h y no sube de ahí") {
    let control = ControlDeIntentos(almacen: IntentosEnMemoria())
    let ahora = Date()
    // Muchos fallos de más: la escalera se queda en su último escalón.
    for _ in 1...50 { control.registrarFallo(ahora: ahora) }
    try esperarIgual(ControlDeIntentos.esperaPara(fallos: 50), 24 * 60 * 60, "el tope son 24 h")
    try esperarIgual(control.esperaRestante(ahora: ahora), 24 * 60 * 60, "y es lo que queda por esperar")
}

arnes.probar("Cumplida la espera se puede volver a intentar") {
    let control = ControlDeIntentos(almacen: IntentosEnMemoria())
    let ahora = Date()
    for _ in 1...(ControlDeIntentos.intentosLibres + 1) { control.registrarFallo(ahora: ahora) }
    try esperar(control.estaBloqueado(ahora: ahora), "recién fallado, bloqueado")

    let despues = ahora.addingTimeInterval(ControlDeIntentos.escalera[0] + 1)
    try esperar(!control.estaBloqueado(ahora: despues), "pasada la espera, libre")
    try esperarIgual(control.esperaRestante(ahora: despues), 0, "sin nada que esperar")
}

arnes.probar("Acertar borra los fallos acumulados") {
    let control = ControlDeIntentos(almacen: IntentosEnMemoria())
    let ahora = Date()
    for _ in 1...5 { control.registrarFallo(ahora: ahora) }
    try esperar(control.estaBloqueado(ahora: ahora), "bloqueado antes de acertar")

    control.registrarAcierto()
    try esperarIgual(control.fallos, 0, "el contador vuelve a cero")
    try esperar(!control.estaBloqueado(ahora: ahora), "y se puede entrar")
}

arnes.probar("Atrasar el reloj no salta la espera") {
    let control = ControlDeIntentos(almacen: IntentosEnMemoria())
    let ahora = Date()
    for _ in 1...(ControlDeIntentos.intentosLibres + 3) { control.registrarFallo(ahora: ahora) }
    let bloqueoNormal = control.esperaRestante(ahora: ahora)

    // Alguien mueve el reloj del sistema una semana atrás para saltarse el castigo.
    let enElPasado = ahora.addingTimeInterval(-7 * 24 * 60 * 60)
    try esperar(control.estaBloqueado(ahora: enElPasado), "sigue bloqueado con el reloj atrasado")
    try esperarIgual(control.esperaRestante(ahora: enElPasado), bloqueoNormal,
                     "y le toca la espera entera, no menos")
}

arnes.probar("La espera se cuenta en palabras que se entienden") {
    try esperarIgual(ControlDeIntentos.enPalabras(30), "30 s", "segundos")
    try esperarIgual(ControlDeIntentos.enPalabras(60), "1 min", "un minuto justo")
    try esperarIgual(ControlDeIntentos.enPalabras(277), "4 min 37 s", "minutos y segundos")
    try esperarIgual(ControlDeIntentos.enPalabras(3600), "1 h", "una hora justa")
    try esperarIgual(ControlDeIntentos.enPalabras(24 * 3600), "24 h", "el tope")
}

arnes.probar("Los fallos sobreviven a cerrar la app") {
    // El mismo almacén que usaría la app, pero en un dominio suyo para no tocar
    // los ajustes de verdad.
    let dominio = "pruebas-intentos-\(UUID().uuidString)"
    let defaults = try desenvolver(UserDefaults(suiteName: dominio))
    defer { defaults.removePersistentDomain(forName: dominio) }

    let ahora = Date()
    let primera = ControlDeIntentos(almacen: AjustesDeIntentos(defaults: defaults))
    for _ in 1...(ControlDeIntentos.intentosLibres + 2) { primera.registrarFallo(ahora: ahora) }

    // Una instancia nueva, como al reabrir la app: la espera sigue ahí.
    let segunda = ControlDeIntentos(almacen: AjustesDeIntentos(defaults: defaults))
    try esperarIgual(segunda.fallos, ControlDeIntentos.intentosLibres + 2, "los fallos se recuerdan")
    try esperar(segunda.estaBloqueado(ahora: ahora), "y la espera también")
}

exit(arnes.resumen())
