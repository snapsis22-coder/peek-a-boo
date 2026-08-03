import Foundation

/// El interruptor Visible ⇄ Oculta de la bóveda entera.
///
/// «Visible» devuelve todo —carpetas y archivos sueltos— a la ruta de la que
/// salió cuando se guardó por primera vez. «Oculta» lo vuelve a cifrar y lo quita
/// del disco. El contenido cifrado **no se borra al hacerse visible**: mientras
/// está fuera sigue existiendo la copia dentro del `.peekb`, que es la red de
/// seguridad si algo le pasa a los archivos ahí fuera.
public extension Vault {

    /// Qué parte del contenido está ahora mismo fuera, en el disco.
    enum Visibilidad: Sendable, Equatable {
        /// Todo cifrado y fuera de la vista.
        case oculta
        /// Todo devuelto a sus rutas originales.
        case visible
        /// Ni una cosa ni la otra: alguna carpeta o archivo suelto se movió por separado.
        case parcial
    }

    var visibilidad: Visibilidad {
        let estados = folders.map(\.isDeployed) + looseEntries.map { $0.isDeployed ?? false }
        guard !estados.isEmpty else { return .oculta }
        if estados.allSatisfy({ $0 }) { return .visible }
        if estados.allSatisfy({ !$0 }) { return .oculta }
        return .parcial
    }

    /// Archivos sueltos que se pueden devolver a su sitio (los que recuerdan de dónde salieron).
    var looseEntriesRestaurables: [VaultEntry] {
        looseEntries.filter { $0.originalPath != nil }
    }

    // MARK: - Toda la bóveda

    /// Devuelve todo a sus rutas originales.
    func makeVisible(progress: ((String, Int, Int) -> Void)? = nil) throws {
        let carpetasPendientes = folders.filter { !$0.isDeployed }
        let sueltosPendientes = looseEntriesRestaurables.filter { !($0.isDeployed ?? false) }
        let total = carpetasPendientes.count + sueltosPendientes.count
        var hechos = 0

        for carpeta in carpetasPendientes {
            progress?(carpeta.name, hechos, total)
            try deployFolder(id: carpeta.id)
            hechos += 1
        }
        for entrada in sueltosPendientes {
            progress?(entrada.name, hechos, total)
            try deployEntry(id: entrada.id)
            hechos += 1
        }
        progress?("", total, total)
    }

    /// Vuelve a cifrar todo y lo quita del disco.
    func makeHidden(progress: ((String, Int, Int) -> Void)? = nil) throws {
        let carpetasFuera = folders.filter { $0.isDeployed }
        let sueltosFuera = looseEntries.filter { $0.isDeployed ?? false }
        let total = carpetasFuera.count + sueltosFuera.count
        var hechos = 0

        for carpeta in carpetasFuera {
            progress?(carpeta.name, hechos, total)
            try stowFolder(id: carpeta.id)
            hechos += 1
        }
        for entrada in sueltosFuera {
            progress?(entrada.name, hechos, total)
            try stowEntry(id: entrada.id)
            hechos += 1
        }
        progress?("", total, total)
    }

    // MARK: - Archivos sueltos, uno a uno

    /// Escribe el archivo en la ruta de la que salió.
    func deployEntry(id: UUID) throws {
        var entrada = try entry(id: id)
        guard let ruta = entrada.originalPath else {
            throw BovedaError.sinRutaOriginal(entrada.name)
        }
        guard !(entrada.isDeployed ?? false) else { return }

        let destino = URL(fileURLWithPath: ruta)
        if FileManager.default.fileExists(atPath: destino.path) {
            throw BovedaError.yaExiste(destino)
        }
        try FileManager.default.createDirectory(at: destino.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try extract(id: id, to: destino, overwrite: false)

        entrada.isDeployed = true
        try actualizarEntrada(entrada)
    }

    /// Vuelve a cifrar el archivo desde su ruta original y lo borra del disco.
    func stowEntry(id: UUID) throws {
        let entrada = try entry(id: id)
        guard let ruta = entrada.originalPath else {
            throw BovedaError.sinRutaOriginal(entrada.name)
        }
        guard entrada.isDeployed ?? false else { return }

        let origen = URL(fileURLWithPath: ruta)
        guard FileManager.default.fileExists(atPath: origen.path) else {
            // Lo borraron ahí fuera: la copia cifrada sigue siendo válida.
            var sinRastro = entrada
            sinRastro.isDeployed = false
            try actualizarEntrada(sinRastro)
            return
        }

        // Se re-cifra el contenido actual: puede haber cambiado mientras estaba fuera.
        let atributos = try FileManager.default.attributesOfItem(atPath: origen.path)
        let lector = try FileHandle(forReadingFrom: origen)
        var cerrado = false
        defer { if !cerrado { try? lector.close() } }

        let nueva = try add(name: entrada.name,
                            createdAt: atributos[.creationDate] as? Date ?? entrada.createdAt,
                            modifiedAt: atributos[.modificationDate] as? Date ?? Date(),
                            category: entrada.category,
                            tags: entrada.tags,
                            originalPath: ruta,
                            commitNow: false,
                            readChunk: { try lector.read(upToCount: Int(FileCipher.defaultChunkSize)) ?? Data() })
        try lector.close()
        cerrado = true

        var indice = indiceInterno
        // Fuera la versión anterior; vale la que se acaba de cifrar.
        if let vieja = indice.entries.first(where: { $0.id == id }) {
            indice.deadBytes += vieja.storedLength
        }
        indice.entries.removeAll { $0.id == id }
        if let pos = indice.entries.firstIndex(where: { $0.id == nueva.id }) {
            indice.entries[pos].isDeployed = false
        }
        indice.deadBytes += indexLengthActual
        indiceInterno = indice
        try commitPending()

        try verify(id: nueva.id)
        try FileManager.default.removeItem(at: origen)
    }

    private func actualizarEntrada(_ entrada: VaultEntry) throws {
        var indice = indiceInterno
        guard let pos = indice.entries.firstIndex(where: { $0.id == entrada.id }) else {
            throw BovedaError.entradaNoEncontrada(entrada.id)
        }
        indice.entries[pos] = entrada
        indice.deadBytes += indexLengthActual
        indiceInterno = indice
        try commitPending()
    }
}
