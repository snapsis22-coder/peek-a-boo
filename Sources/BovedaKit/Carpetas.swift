import Foundation

/// Carpetas gestionadas: el modelo de Hider 2.
///
/// Una carpeta guardada **no existe en el disco**: su contenido vive cifrado dentro
/// del `.boveda` y su ruta original queda anotada. Al desplegarla vuelve a aparecer
/// ahí mismo, descifrada y usable con cualquier app. Al guardarla otra vez se
/// vuelve a cifrar lo que haya y se borra del disco.
///
/// Ahí está la invisibilidad de verdad: no hay flag que ocultar porque no hay nada
/// que ver — ni con `Cmd+Shift+.` ni con `ls -la`.
public extension Vault {

    // MARK: - Verificación

    /// Descifra una entrada sin escribir nada, sólo para comprobar que se puede
    /// recuperar y que el SHA-256 cuadra. Es lo que permite borrar los originales
    /// con la conciencia tranquila.
    func verify(id: UUID) throws {
        let entrada = try entry(id: id)
        try seekTo(entrada.offset)
        _ = try FileCipher.open(key: KeyDerivation.fileKey(dek: claveDeDatos, salt: entrada.keySalt, id: entrada.id),
                                entry: entrada,
                                readCipher: { try self.readCipher($0) },
                                write: { _ in })
    }

    // MARK: - Añadir una carpeta

    /// Cifra una carpeta entera y (por omisión) la borra del disco.
    ///
    /// El borrado sólo ocurre **después** de cifrar todo, confirmar la escritura y
    /// verificar archivo por archivo que se puede descifrar. Si algo falla, no se
    /// borra nada.
    @discardableResult
    func addFolder(at carpeta: URL,
                   removeOriginal: Bool = true,
                   progress: ((String, Int, Int) -> Void)? = nil) throws -> ManagedFolder {
        var esCarpeta: ObjCBool = false
        guard FileManager.default.fileExists(atPath: carpeta.path, isDirectory: &esCarpeta),
              esCarpeta.boolValue else {
            throw BovedaError.archivoNoEncontrado(carpeta)
        }
        if folders.contains(where: { $0.originalPath == carpeta.path }) {
            throw BovedaError.carpetaYaGestionada(carpeta.lastPathComponent)
        }

        let archivos = try listarArchivos(en: carpeta)
        let peso = archivos.reduce(UInt64(0)) { suma, archivo in
            let atributos = try? FileManager.default.attributesOfItem(atPath: archivo.url.path)
            return suma + ((atributos?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
        try comprobarEspacio(para: peso)

        let folderID = UUID()
        var añadidas: [UUID] = []
        var total: UInt64 = 0

        for (indice, archivo) in archivos.enumerated() {
            progress?(archivo.relativa, indice + 1, archivos.count)
            let atributos = try FileManager.default.attributesOfItem(atPath: archivo.url.path)
            let lector = try FileHandle(forReadingFrom: archivo.url)
            defer { try? lector.close() }

            let entrada = try add(name: archivo.url.lastPathComponent,
                                  createdAt: atributos[.creationDate] as? Date ?? Date(),
                                  modifiedAt: atributos[.modificationDate] as? Date ?? Date(),
                                  category: nil,
                                  tags: [],
                                  originalPath: archivo.url.path,
                                  folderID: folderID,
                                  relativePath: archivo.relativa,
                                  commitNow: false,
                                  readChunk: { try lector.read(upToCount: Int(FileCipher.defaultChunkSize)) ?? Data() })
            añadidas.append(entrada.id)
            total += entrada.size
        }

        let registro = ManagedFolder(id: folderID,
                                     name: carpeta.lastPathComponent,
                                     originalPath: carpeta.path,
                                     addedAt: Date(),
                                     isDeployed: !removeOriginal,
                                     fileCount: archivos.count,
                                     totalSize: total)
        var indice = indiceInterno
        indice.folders.append(registro)
        indice.deadBytes += UInt64(indexLengthActual)
        indiceInterno = indice
        try commitPending()

        if removeOriginal {
            // Sólo ahora, con todo cifrado y confirmado en disco.
            try verificarTodas(añadidas)
            try FileManager.default.removeItem(at: carpeta)
        }
        return registro
    }

    // MARK: - Desplegar y volver a guardar

    /// Devuelve la carpeta a su ruta original, descifrada y visible.
    func deployFolder(id: UUID, progress: ((String, Int, Int) -> Void)? = nil) throws {
        guard var registro = folders.first(where: { $0.id == id }) else {
            throw BovedaError.carpetaNoEncontrada(id)
        }
        guard !registro.isDeployed else { return }

        let destino = registro.url
        if FileManager.default.fileExists(atPath: destino.path) {
            throw BovedaError.yaExiste(destino)
        }
        try FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)

        let suyas = entries.filter { $0.folderID == id }
        for (i, entrada) in suyas.enumerated() {
            progress?(entrada.relativePath ?? entrada.name, i + 1, suyas.count)
            let archivo = destino.appendingPathComponent(entrada.relativePath ?? entrada.name)
            try FileManager.default.createDirectory(at: archivo.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try extract(id: entrada.id, to: archivo, overwrite: true)
        }

        registro.isDeployed = true
        try actualizar(registro)
    }

    /// Vuelve a cifrar lo que haya en la carpeta y la borra del disco.
    ///
    /// Se re-cifra el contenido actual, no el de antes: si añadiste, cambiaste o
    /// borraste archivos mientras estaba desplegada, se guarda tal como está ahora.
    func stowFolder(id: UUID, progress: ((String, Int, Int) -> Void)? = nil) throws {
        guard var registro = folders.first(where: { $0.id == id }) else {
            throw BovedaError.carpetaNoEncontrada(id)
        }
        guard registro.isDeployed else { return }
        let carpeta = registro.url
        guard FileManager.default.fileExists(atPath: carpeta.path) else {
            throw BovedaError.archivoNoEncontrado(carpeta)
        }

        // Fuera las versiones viejas: lo que vale es lo que hay ahora en el disco.
        let viejas = entries.filter { $0.folderID == id }
        var indice = indiceInterno
        for vieja in viejas {
            indice.deadBytes += vieja.storedLength
        }
        indice.entries.removeAll { $0.folderID == id }
        indiceInterno = indice

        let archivos = try listarArchivos(en: carpeta)
        var añadidas: [UUID] = []
        var total: UInt64 = 0
        for (i, archivo) in archivos.enumerated() {
            progress?(archivo.relativa, i + 1, archivos.count)
            let atributos = try FileManager.default.attributesOfItem(atPath: archivo.url.path)
            let lector = try FileHandle(forReadingFrom: archivo.url)
            defer { try? lector.close() }
            let entrada = try add(name: archivo.url.lastPathComponent,
                                  createdAt: atributos[.creationDate] as? Date ?? Date(),
                                  modifiedAt: atributos[.modificationDate] as? Date ?? Date(),
                                  category: nil,
                                  tags: [],
                                  originalPath: archivo.url.path,
                                  folderID: id,
                                  relativePath: archivo.relativa,
                                  commitNow: false,
                                  readChunk: { try lector.read(upToCount: Int(FileCipher.defaultChunkSize)) ?? Data() })
            añadidas.append(entrada.id)
            total += entrada.size
        }

        registro.isDeployed = false
        registro.fileCount = archivos.count
        registro.totalSize = total
        var indice2 = indiceInterno
        if let pos = indice2.folders.firstIndex(where: { $0.id == id }) {
            indice2.folders[pos] = registro
        }
        indice2.deadBytes += UInt64(indexLengthActual)
        indiceInterno = indice2
        try commitPending()

        try verificarTodas(añadidas)
        try FileManager.default.removeItem(at: carpeta)
    }

    /// Deja la carpeta visible y sin cifrar, y la saca de la bóveda.
    /// Es la opción «dejarla tal cual» al bloquear.
    func releaseFolder(id: UUID, progress: ((String, Int, Int) -> Void)? = nil) throws {
        guard let registro = folders.first(where: { $0.id == id }) else {
            throw BovedaError.carpetaNoEncontrada(id)
        }
        if !registro.isDeployed {
            try deployFolder(id: id, progress: progress)
        }
        try olvidarCarpeta(id: id)
    }

    /// Borra la carpeta de la bóveda. Si está desplegada en el disco, esos archivos
    /// se quedan donde están: sólo se deja de gestionarlos.
    func olvidarCarpeta(id: UUID) throws {
        guard folders.contains(where: { $0.id == id }) else {
            throw BovedaError.carpetaNoEncontrada(id)
        }
        var indice = indiceInterno
        for entrada in indice.entries where entrada.folderID == id {
            indice.deadBytes += entrada.storedLength
        }
        indice.entries.removeAll { $0.folderID == id }
        indice.folders.removeAll { $0.id == id }
        indice.deadBytes += UInt64(indexLengthActual)
        indiceInterno = indice
        try commitPending()
    }

    /// Archivos sueltos, los que no pertenecen a ninguna carpeta gestionada.
    var looseEntries: [VaultEntry] {
        entries.filter { $0.folderID == nil }
    }

    func entries(inFolder id: UUID) -> [VaultEntry] {
        entries.filter { $0.folderID == id }
            .sorted { ($0.relativePath ?? $0.name) < ($1.relativePath ?? $1.name) }
    }

    // MARK: - Apoyo

    private func verificarTodas(_ ids: [UUID]) throws {
        for id in ids {
            try verify(id: id)
        }
    }

    private func actualizar(_ registro: ManagedFolder) throws {
        var indice = indiceInterno
        guard let pos = indice.folders.firstIndex(where: { $0.id == registro.id }) else {
            throw BovedaError.carpetaNoEncontrada(registro.id)
        }
        indice.folders[pos] = registro
        indice.deadBytes += UInt64(indexLengthActual)
        indiceInterno = indice
        try commitPending()
    }

    /// Recorre la carpeta y devuelve sus archivos con la ruta relativa a la raíz.
    /// Se salta enlaces simbólicos y `.DS_Store`.
    private func listarArchivos(en raiz: URL) throws -> [(url: URL, relativa: String)] {
        let prefijo = raiz.standardizedFileURL.path
        guard let enumerador = FileManager.default.enumerator(
            at: raiz,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) else {
            throw BovedaError.entradaSalida("no se pudo recorrer \(raiz.path)")
        }

        var resultado: [(URL, String)] = []
        for caso in enumerador {
            guard let url = caso as? URL else { continue }
            let valores = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard valores.isRegularFile == true, valores.isSymbolicLink != true else { continue }
            if url.lastPathComponent == ".DS_Store" { continue }

            let completa = url.standardizedFileURL.path
            guard completa.hasPrefix(prefijo + "/") else { continue }
            resultado.append((url, String(completa.dropFirst(prefijo.count + 1))))
        }
        return resultado.sorted { $0.1 < $1.1 }
    }
}
