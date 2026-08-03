import Foundation

/// Lectura/escritura de enteros little-endian sobre buffers de bytes.
/// Todo el formato `.boveda` usa little-endian salvo los contadores de chunk,
/// que van big-endian por estar dentro de un nonce.
enum BinaryCodec {

    // MARK: - Escritura

    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    static func write<T: FixedWidthInteger>(_ value: T, at offset: Int, in data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { bytes in
            for (i, byte) in bytes.enumerated() { data[data.startIndex + offset + i] = byte }
        }
    }

    static func write(_ bytes: Data, at offset: Int, in data: inout Data) {
        for (i, byte) in bytes.enumerated() { data[data.startIndex + offset + i] = byte }
    }

    // MARK: - Lectura

    /// `offset` es relativo al inicio de la vista, no al `startIndex` del buffer de respaldo.
    static func read<T: FixedWidthInteger>(_ type: T.Type, at offset: Int, from data: Data) -> T {
        var value: T = 0
        _ = withUnsafeMutableBytes(of: &value) { dst in
            data.withUnsafeBytes { src in
                memcpy(dst.baseAddress!, src.baseAddress!.advanced(by: offset), MemoryLayout<T>.size)
            }
        }
        return T(littleEndian: value)
    }

    static func slice(_ range: Range<Int>, from data: Data) -> Data {
        Data(data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)])
    }

    /// Nonce de 12 bytes: 8 aleatorios propios del archivo + contador de chunk big-endian.
    static func nonce(base: Data, chunk: UInt32) -> Data {
        var out = base
        withUnsafeBytes(of: chunk.bigEndian) { out.append(contentsOf: $0) }
        return out
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes falló con estado \(status)")
        return Data(bytes)
    }
}
