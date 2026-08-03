import CryptoKit
import Foundation

/// Rescate de una bóveda borrada, leyendo directamente del disco.
///
/// Cuando el archivo `.peekb` ya no existe pero sus bytes siguen en el disco, todo
/// lo necesario está en la cabecera: el salt, la clave de datos cifrada y dónde
/// estaba el índice. Con eso y la contraseña se puede reconstruir el contenido sin
/// que exista el archivo.
///
/// Se escribió el 25-jul-2026 después de que borrara por error una bóveda con
/// 60 GB de fotos del usuario. Ojalá no haga falta otra vez.
public enum Rescate {

    /// Un archivo localizado dentro de la bóveda perdida.
    public struct Pieza: Sendable {
        public let id: UUID
        public let nombre: String
        public let tamano: UInt64
        public let rutaOriginal: String?
        /// Ruta dentro de su carpeta, si venía de una.
        public let rutaRelativa: String?
        public let carpeta: String?

        let offset: UInt64
        let storedLength: UInt64
        let chunkSize: UInt32
        let keySalt: Data
        let nonceBase: Data
        let sha256: Data
    }

    public struct Contenido: Sendable {
        public let piezas: [Pieza]
        public let generacion: UInt64
    }

    /// Lee bytes del medio: `(posiciónAbsoluta, cuántos) -> datos`.
    public typealias Lector = (UInt64, Int) throws -> Data

    // MARK: - Abrir

    /// Descifra el índice de una bóveda perdida.
    ///
    /// - Parameters:
    ///   - inicioEnDisco: posición donde empieza el archivo (la del slot A).
    ///   - contrasena: la de la bóveda.
    ///   - leer: acceso al disco.
    public static func abrir(inicioEnDisco: UInt64,
                             contrasena: String,
                             leer: Lector) throws -> Contenido {
        // Los dos slots de cabecera; gana el de generación mayor que descifre.
        var candidatos: [VaultHeader] = []
        for slot in 0..<VaultHeader.slotCount {
            let bytes = try leer(inicioEnDisco + UInt64(slot * VaultHeader.slotSize), VaultHeader.slotSize)
            if let cabecera = VaultHeader.parse(bytes) { candidatos.append(cabecera) }
        }
        guard !candidatos.isEmpty else { throw BovedaError.noEsUnaBoveda }
        candidatos.sort { $0.generation > $1.generation }

        var ultimoError: BovedaError = .contrasenaIncorrecta
        for cabecera in candidatos {
            do {
                let kek = try KeyDerivation.kek(password: contrasena,
                                                salt: cabecera.salt,
                                                iterations: cabecera.iterations)
                let dek = try cabecera.openDEK(kek: kek)

                let cifrado = try leer(inicioEnDisco + cabecera.indexOffset, Int(cabecera.indexLength))
                let indice = try VaultIndex.open(cifrado, dek: dek, header: cabecera)

                let piezas = indice.entries.map { entrada in
                    Pieza(id: entrada.id,
                          nombre: entrada.name,
                          tamano: entrada.size,
                          rutaOriginal: entrada.originalPath,
                          rutaRelativa: entrada.relativePath,
                          carpeta: entrada.folderID.flatMap { id in
                              indice.folders.first { $0.id == id }?.name
                          },
                          offset: entrada.offset,
                          storedLength: entrada.storedLength,
                          chunkSize: entrada.chunkSize,
                          keySalt: entrada.keySalt,
                          nonceBase: entrada.nonceBase,
                          sha256: entrada.sha256)
                }
                clavesRescatadas[inicioEnDisco] = dek
                return Contenido(piezas: piezas, generacion: cabecera.generation)
            } catch let error as BovedaError {
                ultimoError = error
                continue
            }
        }
        throw ultimoError
    }

    /// La DEK de cada bóveda abierta, para no derivarla en cada extracción.
    private static var clavesRescatadas: [UInt64: SymmetricKey] = [:]

    // MARK: - Extraer

    /// Saca una pieza al disco. Devuelve `true` si el contenido cuadra con su
    /// SHA-256; `false` si se pudo descifrar pero está dañado.
    @discardableResult
    public static func extraer(_ pieza: Pieza,
                               inicioEnDisco: UInt64,
                               a destino: URL,
                               leer: Lector) throws -> Bool {
        guard let dek = clavesRescatadas[inicioEnDisco] else {
            throw BovedaError.bovedaCerrada
        }
        let clave = KeyDerivation.fileKey(dek: dek, salt: pieza.keySalt, id: pieza.id)

        try FileManager.default.createDirectory(at: destino.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: destino.path, contents: nil)
        let salida = try FileHandle(forWritingTo: destino)
        defer { try? salida.close() }

        var cursor = inicioEnDisco + pieza.offset
        var restante = pieza.tamano
        var hasher = SHA256()
        let total = FileCipher.chunkCount(size: pieza.tamano, chunkSize: pieza.chunkSize)

        for indice in 0..<total {
            try autoreleasepool {
                let enClaro = Int(Swift.min(restante, UInt64(pieza.chunkSize)))
                let bloque = try leer(cursor, enClaro + FileCipher.tagLength)
                let caja = try AES.GCM.SealedBox(
                    nonce: try AES.GCM.Nonce(data: BinaryCodec.nonce(base: pieza.nonceBase, chunk: indice)),
                    ciphertext: bloque.prefix(enClaro),
                    tag: bloque.suffix(FileCipher.tagLength))
                let plano = try AES.GCM.open(caja, using: clave,
                                             authenticating: FileCipher.aad(id: pieza.id,
                                                                            chunk: indice,
                                                                            isLast: indice == total - 1))
                hasher.update(data: plano)
                try salida.write(contentsOf: plano)
                cursor += UInt64(enClaro + FileCipher.tagLength)
                restante -= UInt64(enClaro)
            }
        }
        return Data(hasher.finalize()) == pieza.sha256
    }
}
