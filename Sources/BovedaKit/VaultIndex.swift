import CryptoKit
import Foundation

/// Una entrada de la bóveda: un archivo guardado y cifrado.
///
/// Todo esto vive dentro del índice cifrado, así que —a diferencia de Hider 2—
/// los nombres, tamaños y rutas de origen no son visibles sin la contraseña.
public struct VaultEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// Tamaño del contenido original, en claro.
    public var size: UInt64
    public var createdAt: Date
    public var modifiedAt: Date
    public var addedAt: Date
    public var category: String?
    public var tags: [String]
    /// SHA-256 del contenido original; se verifica al extraer.
    public var sha256: Data
    /// Ruta de la que salió el archivo, para poder devolverlo a su sitio.
    public var originalPath: String?

    /// `true` = ahora mismo está en el disco, en su ruta original, descifrado.
    /// Los archivos sueltos tienen el mismo ciclo visible/oculto que las carpetas.
    public var isDeployed: Bool?

    /// Carpeta gestionada a la que pertenece, si viene de una.
    public var folderID: UUID?
    /// Su ruta dentro de esa carpeta, p. ej. «fotos/playa.jpg».
    public var relativePath: String?

    // Ubicación física dentro del contenedor. Interno: la UI no lo necesita.
    var offset: UInt64
    var storedLength: UInt64
    var chunkSize: UInt32
    var keySalt: Data
    var nonceBase: Data
}

/// Una carpeta que la bóveda gestiona entera, al estilo de Hider 2: cuando está
/// guardada no existe en el disco —su contenido vive cifrado aquí dentro— y al
/// desplegarla vuelve a aparecer en su ruta original con todo dentro.
public struct ManagedFolder: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// Dónde vive la carpeta cuando está desplegada.
    public var originalPath: String
    public var addedAt: Date
    /// `true` = ahora mismo está en el disco, descifrada y visible.
    public var isDeployed: Bool
    public var fileCount: Int
    public var totalSize: UInt64

    /// `isDirectory: true` explícito: sin él, `URL` consulta el disco y devuelve
    /// una ruta distinta según la carpeta exista o no en ese momento.
    public var url: URL { URL(fileURLWithPath: originalPath, isDirectory: true) }
}

/// Índice completo de la bóveda. Se serializa a JSON y se sella con la DEK.
struct VaultIndex: Codable {
    var generation: UInt64
    /// Bytes ocupados por blobs borrados e índices viejos; los recupera `compact()`.
    var deadBytes: UInt64
    var entries: [VaultEntry]
    var folders: [ManagedFolder]

    static var empty: VaultIndex {
        VaultIndex(generation: 0, deadBytes: 0, entries: [], folders: [])
    }

    // Decodificación tolerante: las bóvedas creadas antes de que existieran las
    // carpetas no traen la clave `folders`, y deben seguir abriéndose.
    init(generation: UInt64, deadBytes: UInt64, entries: [VaultEntry], folders: [ManagedFolder]) {
        self.generation = generation
        self.deadBytes = deadBytes
        self.entries = entries
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decode(UInt64.self, forKey: .generation)
        deadBytes = try c.decode(UInt64.self, forKey: .deadBytes)
        entries = try c.decode([VaultEntry].self, forKey: .entries)
        folders = try c.decodeIfPresent([ManagedFolder].self, forKey: .folders) ?? []
    }

    // MARK: - Cifrado

    /// Ata el índice a su posición y a su número de generación, de modo que no se
    /// pueda revertir la bóveda a un estado anterior reescribiendo sólo la cabecera.
    static func aad(generation: UInt64, offset: UInt64, length: UInt64) -> Data {
        var data = VaultHeader.magic
        BinaryCodec.append(VaultHeader.currentVersion, to: &data)
        BinaryCodec.append(generation, to: &data)
        BinaryCodec.append(offset, to: &data)
        BinaryCodec.append(length, to: &data)
        return data
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.dataEncodingStrategy = .base64
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        d.dataDecodingStrategy = .base64
        return d
    }

    /// El tamaño sellado se conoce antes de cifrar (texto + tag), y hace falta
    /// para calcular la AAD, así que se pasa el `offset` ya decidido.
    func seal(dek: SymmetricKey, offset: UInt64, nonce: Data) throws -> Data {
        let json = try Self.encoder.encode(self)
        let length = UInt64(json.count + 16)
        let caja = try AES.GCM.seal(json,
                                    using: dek,
                                    nonce: try AES.GCM.Nonce(data: nonce),
                                    authenticating: Self.aad(generation: generation,
                                                             offset: offset,
                                                             length: length))
        return caja.ciphertext + caja.tag
    }

    static func open(_ cifrado: Data, dek: SymmetricKey, header: VaultHeader) throws -> VaultIndex {
        do {
            let caja = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: header.indexNonce),
                                             ciphertext: cifrado.dropLast(16),
                                             tag: cifrado.suffix(16))
            let json = try AES.GCM.open(caja, using: dek,
                                        authenticating: aad(generation: header.generation,
                                                            offset: header.indexOffset,
                                                            length: header.indexLength))
            return try decoder.decode(VaultIndex.self, from: json)
        } catch {
            throw BovedaError.indiceCorrupto
        }
    }
}

/// Resumen del estado del contenedor, para la UI y el subcomando `info`.
public struct VaultStats: Sendable {
    public let entryCount: Int
    /// Suma de los tamaños originales de todo lo guardado.
    public let plainBytes: UInt64
    /// Tamaño del archivo `.boveda` en disco.
    public let fileBytes: UInt64
    /// Espacio recuperable con `compact()`.
    public let deadBytes: UInt64
    public let generation: UInt64
}
