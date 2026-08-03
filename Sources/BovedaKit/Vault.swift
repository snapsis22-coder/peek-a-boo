import CryptoKit
import Foundation

/// Una bóveda abierta: un único archivo `.boveda` con su contenido cifrado.
///
/// ## Cómo se escribe
/// Nada se sobrescribe nunca. Un blob nuevo y su índice se escriben *después* del
/// índice vigente y sólo al final se confirma la operación escribiendo el slot de
/// cabecera que estaba inactivo. Si el proceso muere a mitad de camino, la cabecera
/// anterior sigue apuntando al estado consistente de antes y los bytes a medio
/// escribir se descartan al reabrir. El precio es espacio muerto, que recupera
/// `compact()`.
public final class Vault {

    /// Coste del PBKDF2 con el que se crean las bóvedas nuevas.
    public static let defaultIterations = KeyDerivation.defaultIterations

    public let url: URL

    private var handle: FileHandle
    private var header: VaultHeader
    private var index: VaultIndex
    private let dek: SymmetricKey
    private var activeSlot: Int
    private var isClosed = false

    /// Al añadir una carpeta entera no se confirma cada archivo: se escriben los
    /// blobs seguidos y se confirma una sola vez al final. Este cursor lleva la
    /// cuenta de dónde va la escritura pendiente.
    private var pendingOffset: UInt64?
    private var writeCursor: UInt64 { pendingOffset ?? header.logicalEnd }

    private init(url: URL, handle: FileHandle, header: VaultHeader,
                 index: VaultIndex, dek: SymmetricKey, activeSlot: Int) {
        self.url = url
        self.handle = handle
        self.header = header
        self.index = index
        self.dek = dek
        self.activeSlot = activeSlot
    }

    deinit {
        if !isClosed { try? closeHandle() }
    }

    // MARK: - Crear y abrir

    /// Crea una bóveda vacía. El archivo se crea con permisos 0600.
    @discardableResult
    public static func create(at url: URL,
                              password: String,
                              iterations: UInt32 = Vault.defaultIterations) throws -> Vault {
        guard !password.isEmpty else { throw BovedaError.contrasenaVacia }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw BovedaError.yaExiste(url) }

        let salt = BinaryCodec.randomBytes(KeyDerivation.saltLength)
        let kek = try KeyDerivation.kek(password: password, salt: salt, iterations: iterations)
        let dek = SymmetricKey(size: .bits256)
        let staticBytes = VaultHeader.staticBytes(version: VaultHeader.currentVersion,
                                                  kdfAlgorithm: VaultHeader.kdfPBKDF2SHA256,
                                                  cipherAlgorithm: VaultHeader.cipherAESGCM,
                                                  iterations: iterations,
                                                  salt: salt)
        let header = VaultHeader(iterations: iterations,
                                 salt: salt,
                                 sealedDEK: try VaultHeader.seal(dek: dek, kek: kek, staticBytes: staticBytes),
                                 generation: 0,
                                 indexOffset: VaultHeader.dataStart,
                                 indexLength: 0,
                                 indexNonce: Data(count: VaultHeader.nonceLength))

        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw BovedaError.entradaSalida("no se pudo crear \(url.path)")
        }

        let handle = try FileHandle(forUpdatingFrom: url)
        let vault = Vault(url: url, handle: handle, header: header,
                          index: .empty, dek: dek, activeSlot: 1)
        try vault.lockFile()
        // Reserva de los dos slots de cabecera; el índice arranca justo detrás.
        try handle.write(contentsOf: Data(count: Int(VaultHeader.dataStart)))
        try vault.commit(writingIndexAt: VaultHeader.dataStart)
        return vault
    }

    /// Abre una bóveda existente. Prueba primero el slot de cabecera más reciente
    /// y cae al otro si ese no descifra (puede pasar tras un corte durante un
    /// cambio de contraseña).
    public static func open(at url: URL, password: String) throws -> Vault {
        guard !password.isEmpty else { throw BovedaError.contrasenaVacia }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BovedaError.archivoNoEncontrado(url)
        }

        let handle = try FileHandle(forUpdatingFrom: url)
        var conectado = false
        defer { if !conectado { try? handle.close() } }

        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw BovedaError.bovedaEnUso
        }

        guard let cabeceras = try handle.read(upToCount: Int(VaultHeader.dataStart)),
              cabeceras.count == Int(VaultHeader.dataStart) else {
            throw BovedaError.noEsUnaBoveda
        }

        var candidatos: [(slot: Int, header: VaultHeader)] = []
        for slot in 0..<VaultHeader.slotCount {
            let rango = (slot * VaultHeader.slotSize)..<((slot + 1) * VaultHeader.slotSize)
            if let h = VaultHeader.parse(BinaryCodec.slice(rango, from: cabeceras)) {
                candidatos.append((slot, h))
            }
        }
        guard !candidatos.isEmpty else { throw BovedaError.noEsUnaBoveda }
        candidatos.sort { $0.header.generation > $1.header.generation }

        var fallo: BovedaError = .contrasenaIncorrecta
        var kekCache: (salt: Data, iterations: UInt32, kek: SymmetricKey)?

        for candidato in candidatos {
            do {
                let h = candidato.header
                try h.validate()

                // Los dos slots comparten salt salvo durante un cambio de contraseña,
                // así que normalmente el PBKDF2 se paga una sola vez.
                let kek: SymmetricKey
                if let c = kekCache, c.salt == h.salt, c.iterations == h.iterations {
                    kek = c.kek
                } else {
                    kek = try KeyDerivation.kek(password: password, salt: h.salt, iterations: h.iterations)
                    kekCache = (h.salt, h.iterations, kek)
                }

                let dek = try h.openDEK(kek: kek)
                try handle.seek(toOffset: h.indexOffset)
                let cifrado = try handle.readExactly(Int(h.indexLength))
                let index = try VaultIndex.open(cifrado, dek: dek, header: h)

                let vault = Vault(url: url, handle: handle, header: h,
                                  index: index, dek: dek, activeSlot: candidato.slot)
                // Restos de una escritura que no llegó a confirmarse.
                try vault.truncateToLogicalEnd()
                conectado = true
                return vault
            } catch let error as BovedaError {
                // Un error de versión o formato es más informativo que "contraseña
                // incorrecta", así que se conserva para reportarlo al final.
                if case .contrasenaIncorrecta = fallo { fallo = error }
                continue
            }
        }
        throw fallo
    }

    public func close() throws {
        guard !isClosed else { return }
        try closeHandle()
    }

    private func closeHandle() throws {
        isClosed = true
        flock(handle.fileDescriptor, LOCK_UN)
        try handle.close()
    }

    private func lockFile() throws {
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw BovedaError.bovedaEnUso
        }
    }

    private func checkOpen() throws {
        if isClosed { throw BovedaError.bovedaCerrada }
    }

    private func truncateToLogicalEnd() throws {
        let size = try handle.seekToEnd()
        if size > header.logicalEnd {
            try handle.truncate(atOffset: header.logicalEnd)
        }
    }

    // MARK: - Consulta

    public var entries: [VaultEntry] {
        index.entries
    }

    /// Carpetas gestionadas por la bóveda.
    public var folders: [ManagedFolder] {
        index.folders
    }

    // Acceso interno para el módulo de carpetas.
    var indiceInterno: VaultIndex {
        get { index }
        set { index = newValue }
    }

    var claveDeDatos: SymmetricKey { dek }

    var indexLengthActual: UInt64 { header.indexLength }

    /// Aborta antes de empezar si no cabe. Sin esto, cifrar algo enorme llenaba el
    /// disco y dejaba la bóveda con gigas de escritura sin confirmar.
    func comprobarEspacio(para bytes: UInt64) throws {
        // `volumeAvailableCapacityForImportantUsage` es lo más fiable en APFS
        // porque cuenta lo que el sistema puede liberar, pero en **exFAT devuelve
        // cero** — y ahí es justo donde viven los discos externos. De ahí el
        // segundo intento con la capacidad normal.
        let valores = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeAvailableCapacityKey])
        let importante = valores?.volumeAvailableCapacityForImportantUsage ?? 0
        let normal = Int64(valores?.volumeAvailableCapacity ?? 0)
        let libre = importante > 0 ? importante : normal
        // Si no se pudo averiguar, no se bloquea: mejor intentarlo que impedirlo.
        guard libre > 0 else { return }
        // Margen del 3% para el índice, los tags y el respiro del sistema.
        let necesario = bytes + bytes / 32 + 50_000_000
        guard UInt64(libre) >= necesario else {
            throw BovedaError.espacioInsuficiente(necesario: necesario, disponible: UInt64(max(0, libre)))
        }
    }

    /// Marca si el archivo está ahora mismo fuera, en su ruta original.
    func marcarDesplegada(_ id: UUID, _ desplegada: Bool) throws {
        guard let pos = index.entries.firstIndex(where: { $0.id == id }) else { return }
        index.entries[pos].isDeployed = desplegada
        index.deadBytes += header.indexLength
        try commitPending()
    }

    func seekTo(_ offset: UInt64) throws {
        try handle.seek(toOffset: offset)
    }

    func readCipher(_ count: Int) throws -> Data {
        try handle.readExactly(count)
    }

    public func entry(id: UUID) throws -> VaultEntry {
        guard let entrada = index.entries.first(where: { $0.id == id }) else {
            throw BovedaError.entradaNoEncontrada(id)
        }
        return entrada
    }

    public func stats() throws -> VaultStats {
        try checkOpen()
        let atributos = try? FileManager.default.attributesOfItem(atPath: url.path)
        let tamano = (atributos?[.size] as? NSNumber)?.uint64Value ?? 0
        return VaultStats(entryCount: index.entries.count,
                          plainBytes: index.entries.reduce(0) { $0 + $1.size },
                          fileBytes: tamano,
                          deadBytes: index.deadBytes,
                          generation: header.generation)
    }

    // MARK: - Agregar

    /// Cifra un archivo del disco y lo guarda en la bóveda.
    ///
    /// Con `removeOriginal` el archivo desaparece del disco, igual que ocurre con
    /// las carpetas: lo que entra en la bóveda deja de estar fuera. El borrado
    /// sólo ocurre tras confirmar la escritura y verificar que se puede descifrar.
    @discardableResult
    public func addFile(at fileURL: URL,
                        category: String? = nil,
                        tags: [String] = [],
                        recordOriginalPath: Bool = true,
                        removeOriginal: Bool = false) throws -> VaultEntry {
        try checkOpen()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw BovedaError.archivoNoEncontrado(fileURL)
        }

        let atributos = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        try comprobarEspacio(para: (atributos[.size] as? NSNumber)?.uint64Value ?? 0)

        let entrada = try FileHandle(forReadingFrom: fileURL)
        defer { try? entrada.close() }   // cerrar dos veces es inocuo con try?

        let guardada = try add(name: fileURL.lastPathComponent,
                               createdAt: atributos[.creationDate] as? Date ?? Date(),
                               modifiedAt: atributos[.modificationDate] as? Date ?? Date(),
                               category: category,
                               tags: tags,
                               originalPath: recordOriginalPath ? fileURL.path : nil,
                               readChunk: { try entrada.read(upToCount: Int(FileCipher.defaultChunkSize)) ?? Data() })

        if removeOriginal {
            try entrada.close()
            try verify(id: guardada.id)   // no se borra nada sin poder recuperarlo
            try FileManager.default.removeItem(at: fileURL)
            try marcarDesplegada(guardada.id, false)
        } else {
            try marcarDesplegada(guardada.id, true)
        }
        return try entry(id: guardada.id)
    }

    /// Guarda datos en memoria como si fueran un archivo (útil para notas y para pruebas).
    @discardableResult
    public func addData(_ data: Data,
                        name: String,
                        category: String? = nil,
                        tags: [String] = []) throws -> VaultEntry {
        try checkOpen()
        var restante = data
        return try add(name: name,
                       createdAt: Date(),
                       modifiedAt: Date(),
                       category: category,
                       tags: tags,
                       originalPath: nil,
                       readChunk: {
                           let trozo = restante.prefix(Int(FileCipher.defaultChunkSize))
                           restante = restante.dropFirst(trozo.count)
                           return Data(trozo)
                       })
    }

    func add(name: String,
             createdAt: Date,
             modifiedAt: Date,
             category: String?,
             tags: [String],
             originalPath: String?,
             folderID: UUID? = nil,
             relativePath: String? = nil,
             commitNow: Bool = true,
             readChunk: () throws -> Data) throws -> VaultEntry {

        let id = UUID()
        let keySalt = BinaryCodec.randomBytes(KeyDerivation.saltLength)
        let nonceBase = BinaryCodec.randomBytes(FileCipher.nonceBaseLength)
        let key = KeyDerivation.fileKey(dek: dek, salt: keySalt, id: id)

        // Se escribe detrás del índice vigente: así el estado anterior sigue intacto
        // hasta que la cabecera nueva confirme la operación.
        let offset = writeCursor
        try handle.seek(toOffset: offset)
        let resultado = try FileCipher.seal(key: key,
                                            id: id,
                                            nonceBase: nonceBase,
                                            chunkSize: FileCipher.defaultChunkSize,
                                            readChunk: readChunk,
                                            write: { try self.handle.write(contentsOf: $0) })
        try handle.synchronize()

        let entrada = VaultEntry(id: id,
                                 name: name,
                                 size: resultado.plainSize,
                                 createdAt: createdAt,
                                 modifiedAt: modifiedAt,
                                 addedAt: Date(),
                                 category: category,
                                 tags: tags,
                                 sha256: resultado.sha256,
                                 originalPath: originalPath,
                                 folderID: folderID,
                                 relativePath: relativePath,
                                 offset: offset,
                                 storedLength: resultado.storedLength,
                                 chunkSize: FileCipher.defaultChunkSize,
                                 keySalt: keySalt,
                                 nonceBase: nonceBase)

        index.entries.append(entrada)
        pendingOffset = offset + resultado.storedLength
        if commitNow {
            index.deadBytes += header.indexLength  // el índice anterior queda obsoleto
            try commitPending()
        }
        return entrada
    }

    // MARK: - Extraer

    /// Extrae una entrada a disco. Escribe primero en un temporal y sólo mueve el
    /// resultado si el descifrado y el hash cuadran: nunca deja un archivo a medias.
    public func extract(id: UUID, to destino: URL, overwrite: Bool = false) throws {
        try checkOpen()
        let entrada = try entry(id: id)

        if FileManager.default.fileExists(atPath: destino.path) && !overwrite {
            throw BovedaError.yaExiste(destino)
        }

        let temporal = destino.deletingLastPathComponent()
            .appendingPathComponent(".boveda-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporal.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw BovedaError.entradaSalida("no se pudo crear el temporal en \(temporal.path)")
        }

        let salida = try FileHandle(forWritingTo: temporal)
        var completado = false
        defer {
            try? salida.close()
            if !completado { try? FileManager.default.removeItem(at: temporal) }
        }

        try handle.seek(toOffset: entrada.offset)
        _ = try FileCipher.open(key: KeyDerivation.fileKey(dek: dek, salt: entrada.keySalt, id: entrada.id),
                                entry: entrada,
                                readCipher: { try self.handle.readExactly($0) },
                                write: { try salida.write(contentsOf: $0) })
        try salida.close()
        completado = true

        if FileManager.default.fileExists(atPath: destino.path) {
            _ = try FileManager.default.replaceItemAt(destino, withItemAt: temporal)
        } else {
            try FileManager.default.moveItem(at: temporal, to: destino)
        }
        try? FileManager.default.setAttributes([.creationDate: entrada.createdAt,
                                                .modificationDate: entrada.modifiedAt],
                                               ofItemAtPath: destino.path)
    }

    public func extractData(id: UUID) throws -> Data {
        try checkOpen()
        let entrada = try entry(id: id)
        var salida = Data()
        salida.reserveCapacity(Int(entrada.size))
        try handle.seek(toOffset: entrada.offset)
        _ = try FileCipher.open(key: KeyDerivation.fileKey(dek: dek, salt: entrada.keySalt, id: entrada.id),
                                entry: entrada,
                                readCipher: { try self.handle.readExactly($0) },
                                write: { salida.append($0) })
        return salida
    }

    // MARK: - Eliminar y compactar

    /// Quita la entrada del índice. Los bytes cifrados siguen en el archivo hasta
    /// que se llame a `compact()`, pero ya no hay forma de llegar a ellos.
    public func remove(id: UUID) throws {
        try checkOpen()
        let entrada = try entry(id: id)
        index.entries.removeAll { $0.id == id }
        index.deadBytes += entrada.storedLength + header.indexLength
        try commit(writingIndexAt: header.logicalEnd)
    }

    /// Reescribe el contenedor sin espacio muerto y reemplaza el archivo de forma
    /// atómica. Los blobs se copian tal cual, sin descifrar.
    public func compact() throws {
        try checkOpen()

        // Compactar sustituye el archivo por otro recién creado, y los flags no
        // viajan con el contenido: sin esto, cada compactación dejaba la bóveda
        // a la vista en el Finder.
        let estabaOculta = (try? Vault.estaOculta(url)) ?? false

        let temporal = url.deletingLastPathComponent()
            .appendingPathComponent(".boveda-compact-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporal.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw BovedaError.entradaSalida("no se pudo crear el temporal en \(temporal.path)")
        }

        var listo = false
        defer { if !listo { try? FileManager.default.removeItem(at: temporal) } }

        let salida = try FileHandle(forUpdatingFrom: temporal)
        try salida.write(contentsOf: Data(count: Int(VaultHeader.dataStart)))

        var nuevas = index.entries
        var cursor = VaultHeader.dataStart
        for i in nuevas.indices {
            try handle.seek(toOffset: nuevas[i].offset)
            var restante = nuevas[i].storedLength
            while restante > 0 {
                try autoreleasepool {
                    let trozo = try handle.readExactly(Int(min(restante, UInt64(FileCipher.defaultChunkSize))))
                    try salida.write(contentsOf: trozo)
                    restante -= UInt64(trozo.count)
                }
            }
            nuevas[i].offset = cursor
            cursor += nuevas[i].storedLength
        }

        let nuevoIndice = VaultIndex(generation: header.generation + 1, deadBytes: 0,
                                     entries: nuevas, folders: index.folders)
        let nonce = BinaryCodec.randomBytes(VaultHeader.nonceLength)
        let cifrado = try nuevoIndice.seal(dek: dek, offset: cursor, nonce: nonce)
        try salida.write(contentsOf: cifrado)

        var nuevaCabecera = header
        nuevaCabecera.generation = nuevoIndice.generation
        nuevaCabecera.indexOffset = cursor
        nuevaCabecera.indexLength = UInt64(cifrado.count)
        nuevaCabecera.indexNonce = nonce
        let slot = nuevaCabecera.serialize()
        for i in 0..<VaultHeader.slotCount {
            try salida.seek(toOffset: UInt64(i * VaultHeader.slotSize))
            try salida.write(contentsOf: slot)
        }
        try salida.synchronize()
        try salida.close()

        // El handle viejo apunta al inodo anterior: hay que soltarlo antes de sustituir.
        try closeHandle()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporal)
        listo = true
        if estabaOculta { try? Vault.ocultar(url, true) }

        handle = try FileHandle(forUpdatingFrom: url)
        isClosed = false
        try lockFile()
        header = nuevaCabecera
        index = nuevoIndice
        activeSlot = VaultHeader.slotCount - 1
    }

    // MARK: - Contraseña

    /// Vuelve a sellar la DEK con una clave derivada de la contraseña nueva. El
    /// contenido no se re-cifra, así que es instantáneo por muy grande que sea la bóveda.
    public func changePassword(current: String, new: String) throws {
        try checkOpen()
        guard !new.isEmpty else { throw BovedaError.contrasenaVacia }

        let kekActual = try KeyDerivation.kek(password: current, salt: header.salt, iterations: header.iterations)
        _ = try header.openDEK(kek: kekActual)  // lanza .contrasenaIncorrecta si no cuadra

        let salt = BinaryCodec.randomBytes(KeyDerivation.saltLength)
        let staticBytes = VaultHeader.staticBytes(version: header.version,
                                                  kdfAlgorithm: header.kdfAlgorithm,
                                                  cipherAlgorithm: header.cipherAlgorithm,
                                                  iterations: header.iterations,
                                                  salt: salt)
        let kek = try KeyDerivation.kek(password: new, salt: salt, iterations: header.iterations)

        var base = header
        base.salt = salt
        base.sealedDEK = try VaultHeader.seal(dek: dek, kek: kek, staticBytes: staticBytes)

        index.deadBytes += header.indexLength
        // Ambos slots, porque la parte estática cambió y los dos deben poder abrirse
        // con la contraseña nueva.
        try commit(writingIndexAt: header.logicalEnd, base: base, allSlots: true)
    }

    // MARK: - Confirmación

    /// Escribe el índice y confirma la operación con la cabecera. El orden importa:
    /// primero los datos con `fsync`, después la cabecera. Hasta esa última escritura
    /// la bóveda sigue en su estado anterior.
    private func commit(writingIndexAt offset: UInt64,
                        base: VaultHeader? = nil,
                        allSlots: Bool = false) throws {
        var nueva = base ?? header
        index.generation = header.generation + 1

        let nonce = BinaryCodec.randomBytes(VaultHeader.nonceLength)
        let cifrado = try index.seal(dek: dek, offset: offset, nonce: nonce)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: cifrado)
        try handle.synchronize()

        nueva.generation = index.generation
        nueva.indexOffset = offset
        nueva.indexLength = UInt64(cifrado.count)
        nueva.indexNonce = nonce

        let inactivo = (activeSlot + 1) % VaultHeader.slotCount
        try writeSlot(nueva, at: inactivo)
        if allSlots {
            try writeSlot(nueva, at: activeSlot)
        }
        header = nueva
        activeSlot = inactivo
        pendingOffset = nil
    }

    /// Confirma lo que haya escrito pendiente de commit.
    func commitPending() throws {
        try commit(writingIndexAt: writeCursor)
    }

    private func writeSlot(_ cabecera: VaultHeader, at slot: Int) throws {
        try handle.seek(toOffset: UInt64(slot * VaultHeader.slotSize))
        try handle.write(contentsOf: cabecera.serialize())
        try handle.synchronize()
    }
}

// MARK: - Utilidades de FileHandle

extension FileHandle {
    convenience init(forUpdatingFrom url: URL) throws {
        do {
            try self.init(forUpdating: url)
        } catch {
            throw BovedaError.entradaSalida("no se pudo abrir \(url.path): \(error.localizedDescription)")
        }
    }

    /// `read(upToCount:)` puede devolver menos bytes de los pedidos; aquí siempre
    /// se devuelven `count` o se falla.
    func readExactly(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var datos = Data()
        datos.reserveCapacity(count)
        while datos.count < count {
            guard let trozo = try read(upToCount: count - datos.count), !trozo.isEmpty else {
                throw BovedaError.entradaSalida("fin de archivo inesperado (faltan \(count - datos.count) bytes)")
            }
            datos.append(trozo)
        }
        return datos
    }
}
