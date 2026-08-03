import CommonCrypto
import CryptoKit
import Foundation

/// Derivación de claves.
///
/// - KEK (clave que envuelve): PBKDF2-SHA256 sobre la contraseña maestra.
/// - DEK (clave de datos): 256 bits aleatorios, sellada con la KEK. Cambiar la
///   contraseña sólo vuelve a sellar la DEK; no re-cifra nada del contenido.
/// - Subclave por archivo: HKDF-SHA256 de la DEK, con salt propio de cada entrada.
enum KeyDerivation {

    /// Coste del PBKDF2. Recomendación OWASP 2023 para PBKDF2-SHA256.
    static let defaultIterations: UInt32 = 600_000
    static let saltLength = 32
    static let keyLength = 32

    static func kek(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        guard !password.isEmpty else { throw BovedaError.contrasenaVacia }
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)

        let status: Int32 = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else {
            throw BovedaError.entradaSalida("PBKDF2 falló con estado \(status)")
        }
        defer { derived.resetBytes(in: 0..<derived.count) }
        return SymmetricKey(data: Data(derived))
    }

    /// Subclave única por archivo. El `id` entra en el `info` para que dos entradas
    /// con el mismo salt (imposible en la práctica) sigan sin compartir clave.
    static func fileKey(dek: SymmetricKey, salt: Data, id: UUID) -> SymmetricKey {
        var info = Data("boveda-archivo-v1".utf8)
        info.append(contentsOf: withUnsafeBytes(of: id.uuid) { Data($0) })
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: dek,
            salt: salt,
            info: info,
            outputByteCount: keyLength
        )
    }
}

private extension Array where Element == UInt8 {
    mutating func resetBytes(in range: Range<Int>) {
        for i in range { self[i] = 0 }
    }
}
