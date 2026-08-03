import Foundation

/// Ventana de sólo lectura a las tripas del contenedor.
///
/// Existe para dos cosas: que la suite de pruebas pueda comprobar el formato sin
/// `@testable` (que no funciona en compilaciones de release), y poder inspeccionar
/// una bóveda dañada más adelante. Nada de lo que hay aquí revela contenido: son
/// posiciones y tamaños, que ya están en claro en el archivo.
public enum BovedaDiagnostico {

    // MARK: - Disposición del contenedor

    public static var tamanoDeSlot: Int { VaultHeader.slotSize }
    public static var numeroDeSlots: Int { VaultHeader.slotCount }
    public static var desplazamientoDelChecksum: Int { VaultHeader.checksumOffset }
    public static var inicioDeDatos: UInt64 { VaultHeader.dataStart }
    public static var tamanoDeChunk: UInt32 { FileCipher.defaultChunkSize }
    public static var longitudDeTag: Int { FileCipher.tagLength }

    public static func longitudAlmacenada(tamano: UInt64, chunkSize: UInt32) -> UInt64 {
        FileCipher.storedLength(size: tamano, chunkSize: chunkSize)
    }

    // MARK: - Entradas

    /// Dónde vive el blob de una entrada dentro del archivo.
    public static func ubicacion(de entrada: VaultEntry) -> (offset: UInt64, longitud: UInt64, chunkSize: UInt32) {
        (entrada.offset, entrada.storedLength, entrada.chunkSize)
    }

    // MARK: - Cabeceras

    public struct Cabecera: Sendable {
        public let slot: Int
        public let generacion: UInt64
        public let offsetDelIndice: UInt64
        public let longitudDelIndice: UInt64
    }

    /// Lee los slots de cabecera válidos sin necesidad de la contraseña.
    public static func cabeceras(de url: URL) throws -> [Cabecera] {
        let crudo = try Data(contentsOf: url)
        guard crudo.count >= Int(VaultHeader.dataStart) else { throw BovedaError.noEsUnaBoveda }
        return (0..<VaultHeader.slotCount).compactMap { slot in
            let rango = (slot * VaultHeader.slotSize)..<((slot + 1) * VaultHeader.slotSize)
            guard let cabecera = VaultHeader.parse(BinaryCodec.slice(rango, from: crudo)) else { return nil }
            return Cabecera(slot: slot,
                            generacion: cabecera.generation,
                            offsetDelIndice: cabecera.indexOffset,
                            longitudDelIndice: cabecera.indexLength)
        }
    }
}
