import CryptoKit
import Foundation

/// Cifrado del contenido de los archivos, por trozos.
///
/// CryptoKit sella en memoria, así que un archivo de varios GB no se puede pasar
/// de una sola vez: el contenido se parte en chunks de 1 MiB y cada uno se sella
/// por separado con la subclave del archivo.
///
/// La AAD de cada chunk incluye el identificador de la entrada, el número de chunk
/// y si es el último. Eso hace detectable no sólo la alteración de un byte, sino
/// también el truncado del archivo o el reordenamiento de sus trozos.
enum FileCipher {

    static let defaultChunkSize: UInt32 = 1 << 20  // 1 MiB
    static let tagLength = 16
    static let nonceBaseLength = 8

    static func aad(id: UUID, chunk: UInt32, isLast: Bool) -> Data {
        var data = withUnsafeBytes(of: id.uuid) { Data($0) }
        withUnsafeBytes(of: chunk.bigEndian) { data.append(contentsOf: $0) }
        data.append(isLast ? 1 : 0)
        return data
    }

    /// Número de chunks de un contenido de `size` bytes. Un archivo vacío sigue
    /// teniendo un chunk (vacío, pero autenticado), para que no se pueda hacer
    /// pasar por "sin datos".
    static func chunkCount(size: UInt64, chunkSize: UInt32) -> UInt32 {
        guard size > 0 else { return 1 }
        return UInt32((size + UInt64(chunkSize) - 1) / UInt64(chunkSize))
    }

    static func storedLength(size: UInt64, chunkSize: UInt32) -> UInt64 {
        size + UInt64(chunkCount(size: size, chunkSize: chunkSize)) * UInt64(tagLength)
    }

    struct SealResult {
        let plainSize: UInt64
        let storedLength: UInt64
        let sha256: Data
    }

    /// Lee con `readChunk` (que devuelve datos vacíos al terminar) y entrega
    /// cada trozo ya sellado a `write`.
    static func seal(key: SymmetricKey,
                     id: UUID,
                     nonceBase: Data,
                     chunkSize: UInt32,
                     readChunk: () throws -> Data,
                     write: (Data) throws -> Void) throws -> SealResult {

        var hasher = SHA256()
        var plainSize: UInt64 = 0
        var stored: UInt64 = 0
        var index: UInt32 = 0
        var current = try readChunk()

        while true {
            // Cada vuelta va en su propio autorelease pool. Sin esto, los objetos
            // temporales de Foundation (el trozo leído, el cifrado, la
            // concatenación) se acumulan hasta que la tarea termina: con 110 GB
            // son unos 105.000 chunks, y la memoria virtual se dispara hasta
            // tumbar el sistema. Pasó de verdad el 25-jul-2026.
            let terminado: Bool = try autoreleasepool {
                // Hay que mirar un trozo por delante para saber si el actual es el último.
                let next = current.isEmpty ? Data() : try readChunk()
                let isLast = next.isEmpty

                hasher.update(data: current)
                let caja = try AES.GCM.seal(current,
                                            using: key,
                                            nonce: try AES.GCM.Nonce(data: BinaryCodec.nonce(base: nonceBase, chunk: index)),
                                            authenticating: aad(id: id, chunk: index, isLast: isLast))
                try write(caja.ciphertext + caja.tag)

                plainSize += UInt64(current.count)
                stored += UInt64(current.count + tagLength)
                index += 1

                if isLast { return true }
                current = next
                return false
            }
            if terminado { break }
        }

        return SealResult(plainSize: plainSize, storedLength: stored, sha256: Data(hasher.finalize()))
    }

    /// Descifra los `size` bytes de una entrada, entregando cada trozo en claro a
    /// `write`. Verifica al final que el contenido corresponde al SHA-256 guardado.
    static func open(key: SymmetricKey,
                     entry: VaultEntry,
                     readCipher: (Int) throws -> Data,
                     write: (Data) throws -> Void) throws -> Data {

        var hasher = SHA256()
        var restante = entry.size
        let total = chunkCount(size: entry.size, chunkSize: entry.chunkSize)

        for index in 0..<total {
            try autoreleasepool {
            let plainLength = Int(Swift.min(restante, UInt64(entry.chunkSize)))
            let bloque = try readCipher(plainLength + tagLength)
            guard bloque.count == plainLength + tagLength else {
                throw BovedaError.datosCorruptos(entry.name)
            }

            do {
                let caja = try AES.GCM.SealedBox(
                    nonce: try AES.GCM.Nonce(data: BinaryCodec.nonce(base: entry.nonceBase, chunk: index)),
                    ciphertext: bloque.prefix(plainLength),
                    tag: bloque.suffix(tagLength))
                let plano = try AES.GCM.open(caja, using: key,
                                             authenticating: aad(id: entry.id,
                                                                 chunk: index,
                                                                 isLast: index == total - 1))
                hasher.update(data: plano)
                try write(plano)
            } catch let error as BovedaError {
                throw error
            } catch {
                throw BovedaError.datosCorruptos(entry.name)
            }

            restante -= UInt64(plainLength)
            }
        }

        let digest = Data(hasher.finalize())
        guard digest == entry.sha256 else { throw BovedaError.datosCorruptos(entry.name) }
        return digest
    }
}
