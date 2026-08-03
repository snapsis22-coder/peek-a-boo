import CryptoKit
import Foundation

/// Cabecera del contenedor `.boveda`.
///
/// El archivo empieza con **dos slots** de 512 bytes (A en 0, B en 512) y los datos
/// arrancan en 1024. Cada commit escribe el slot que *no* está activo, así que una
/// escritura interrumpida nunca deja la bóveda ilegible: al abrir gana el slot con
/// `generation` mayor cuyo checksum cuadre, y si ese no sirve se cae al otro.
///
/// Los bytes 0..<48 (magic, versión, algoritmos, iteraciones, salt) son la **parte
/// estática** y se usan como AAD al sellar la DEK: alterar los parámetros del KDF
/// rompe el desbloqueo en vez de debilitarlo en silencio.
struct VaultHeader {

    static let magic = Data("BOVEDA".utf8)
    static let slotSize = 512
    static let slotCount = 2
    static let dataStart = UInt64(slotSize * slotCount)
    static let currentVersion: UInt16 = 1
    static let staticLength = 48
    static let checksumOffset = 480
    static let sealedDEKLength = 12 + 32 + 16  // nonce + clave cifrada + tag
    static let nonceLength = 12

    static let kdfPBKDF2SHA256: UInt8 = 1
    static let cipherAESGCM: UInt8 = 1

    var version: UInt16 = currentVersion
    var kdfAlgorithm: UInt8 = kdfPBKDF2SHA256
    var cipherAlgorithm: UInt8 = cipherAESGCM
    var iterations: UInt32
    var salt: Data
    var sealedDEK: Data
    var generation: UInt64
    var indexOffset: UInt64
    var indexLength: UInt64
    var indexNonce: Data

    /// Fin lógico del contenido: todo lo que haya después son restos de una
    /// escritura que no llegó a confirmarse.
    var logicalEnd: UInt64 { indexOffset + indexLength }

    // MARK: - Serialización

    /// Bytes 0..<48. Se construyen aparte porque hay que autenticarlos *antes*
    /// de que exista la DEK sellada que va justo después.
    static func staticBytes(version: UInt16, kdfAlgorithm: UInt8, cipherAlgorithm: UInt8,
                            iterations: UInt32, salt: Data) -> Data {
        var data = Data()
        data.append(magic)
        BinaryCodec.append(version, to: &data)
        data.append(kdfAlgorithm)
        data.append(cipherAlgorithm)
        data.append(contentsOf: [0, 0])              // reservado
        BinaryCodec.append(iterations, to: &data)
        data.append(salt)
        precondition(data.count == staticLength)
        return data
    }

    var staticBytes: Data {
        Self.staticBytes(version: version, kdfAlgorithm: kdfAlgorithm,
                         cipherAlgorithm: cipherAlgorithm, iterations: iterations, salt: salt)
    }

    func serialize() -> Data {
        var slot = Data(count: Self.slotSize)
        BinaryCodec.write(staticBytes, at: 0, in: &slot)
        BinaryCodec.write(sealedDEK, at: 48, in: &slot)
        BinaryCodec.write(generation, at: 112, in: &slot)
        BinaryCodec.write(indexOffset, at: 120, in: &slot)
        BinaryCodec.write(indexLength, at: 128, in: &slot)
        BinaryCodec.write(indexNonce, at: 136, in: &slot)
        let checksum = Data(SHA256.hash(data: slot.prefix(Self.checksumOffset)))
        BinaryCodec.write(checksum, at: Self.checksumOffset, in: &slot)
        return slot
    }

    /// Devuelve `nil` si el slot está vacío, dañado o no es una bóveda: quien llama
    /// debe poder intentar con el otro slot antes de darse por vencido.
    static func parse(_ slot: Data) -> VaultHeader? {
        guard slot.count == slotSize else { return nil }
        guard BinaryCodec.slice(0..<magic.count, from: slot) == magic else { return nil }

        let esperado = Data(SHA256.hash(data: slot.prefix(checksumOffset)))
        guard BinaryCodec.slice(checksumOffset..<(checksumOffset + 32), from: slot) == esperado else {
            return nil
        }

        return VaultHeader(
            version: BinaryCodec.read(UInt16.self, at: 6, from: slot),
            kdfAlgorithm: slot[slot.startIndex + 8],
            cipherAlgorithm: slot[slot.startIndex + 9],
            iterations: BinaryCodec.read(UInt32.self, at: 12, from: slot),
            salt: BinaryCodec.slice(16..<48, from: slot),
            sealedDEK: BinaryCodec.slice(48..<(48 + sealedDEKLength), from: slot),
            generation: BinaryCodec.read(UInt64.self, at: 112, from: slot),
            indexOffset: BinaryCodec.read(UInt64.self, at: 120, from: slot),
            indexLength: BinaryCodec.read(UInt64.self, at: 128, from: slot),
            indexNonce: BinaryCodec.slice(136..<(136 + nonceLength), from: slot)
        )
    }

    /// Comprobaciones que sí deben abortar la apertura (el archivo es una bóveda,
    /// pero de una versión o con algoritmos que este binario no entiende).
    func validate() throws {
        guard version <= Self.currentVersion else { throw BovedaError.versionNoSoportada(version) }
        guard kdfAlgorithm == Self.kdfPBKDF2SHA256,
              cipherAlgorithm == Self.cipherAESGCM,
              salt.count == KeyDerivation.saltLength,
              sealedDEK.count == Self.sealedDEKLength,
              indexNonce.count == Self.nonceLength,
              indexOffset >= Self.dataStart
        else { throw BovedaError.cabeceraCorrupta }
    }

    // MARK: - DEK

    static func seal(dek: SymmetricKey, kek: SymmetricKey, staticBytes: Data) throws -> Data {
        let caja = try AES.GCM.seal(dek.withUnsafeBytes { Data($0) },
                                    using: kek,
                                    authenticating: staticBytes)
        return caja.nonce.withUnsafeBytes { Data($0) } + caja.ciphertext + caja.tag
    }

    func openDEK(kek: SymmetricKey) throws -> SymmetricKey {
        do {
            let nonce = try AES.GCM.Nonce(data: sealedDEK.prefix(Self.nonceLength))
            let cuerpo = sealedDEK.dropFirst(Self.nonceLength)
            let caja = try AES.GCM.SealedBox(nonce: nonce,
                                             ciphertext: cuerpo.dropLast(16),
                                             tag: cuerpo.suffix(16))
            return SymmetricKey(data: try AES.GCM.open(caja, using: kek, authenticating: staticBytes))
        } catch {
            throw BovedaError.contrasenaIncorrecta
        }
    }
}
