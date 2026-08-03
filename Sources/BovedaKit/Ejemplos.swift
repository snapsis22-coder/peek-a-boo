import Foundation

// Datos de ejemplo para las previews de SwiftUI y para pruebas de interfaz.
//
// Hacen falta porque los campos de ubicación de `VaultEntry` (offset, longitud,
// salt…) son internos: sin esto, otro módulo no puede fabricar una entrada y las
// previews tendrían que abrir una bóveda de verdad, que es justo lo que no puede
// hacerse dentro del canvas de Xcode.
public extension VaultEntry {

    /// Entrada falsa, sin nada detrás en disco. No intentes extraerla.
    static func ejemplo(nombre: String,
                        tamano: UInt64,
                        categoria: String? = nil,
                        etiquetas: [String] = [],
                        agregado: Date = Date()) -> VaultEntry {
        VaultEntry(id: UUID(),
                   name: nombre,
                   size: tamano,
                   createdAt: agregado,
                   modifiedAt: agregado,
                   addedAt: agregado,
                   category: categoria,
                   tags: etiquetas,
                   sha256: Data(repeating: 0, count: 32),
                   originalPath: nil,
                   offset: 0,
                   storedLength: tamano,
                   chunkSize: 1 << 20,
                   keySalt: Data(repeating: 0, count: 32),
                   nonceBase: Data(repeating: 0, count: 8))
    }

    /// Carpetas de mentira para las previews, una guardada y otra visible.
    static var ejemplosDeCarpetas: [ManagedFolder] {
        [
            ManagedFolder(id: UUID(), name: "Documentos personales",
                          originalPath: "/Users/ejemplo/Documentos/Documentos personales",
                          addedAt: Date().addingTimeInterval(-86_400 * 30),
                          isDeployed: false, fileCount: 34, totalSize: 412_000_000),
            ManagedFolder(id: UUID(), name: "Fotos 2026",
                          originalPath: "/Users/ejemplo/Imágenes/Fotos 2026",
                          addedAt: Date().addingTimeInterval(-86_400 * 3),
                          isDeployed: true, fileCount: 128, totalSize: 2_300_000_000),
        ]
    }

    /// Un puñado de entradas variadas para llenar una lista en las previews.
    static var ejemplos: [VaultEntry] {
        let ahora = Date()
        return [
            .ejemplo(nombre: "Declaración de renta 2026.pdf", tamano: 2_400_000,
                     categoria: "Impuestos", agregado: ahora.addingTimeInterval(-86_400 * 2)),
            .ejemplo(nombre: "Cédula.jpg", tamano: 840_000,
                     categoria: "Documentos", agregado: ahora.addingTimeInterval(-86_400 * 9)),
            .ejemplo(nombre: "Contrato arriendo.docx", tamano: 61_000,
                     categoria: "Documentos", etiquetas: ["2026"], agregado: ahora.addingTimeInterval(-3_600 * 5)),
            .ejemplo(nombre: "Respaldo llaves.txt", tamano: 1_100,
                     categoria: nil, agregado: ahora.addingTimeInterval(-600)),
            .ejemplo(nombre: "Vacaciones Santa Marta.mov", tamano: 1_850_000_000,
                     categoria: "Personal", agregado: ahora.addingTimeInterval(-86_400 * 40)),
        ]
    }
}

public extension ManagedFolder {
    /// Atajo para las previews: mismas carpetas de ejemplo.
    static var ejemplos: [ManagedFolder] { VaultEntry.ejemplosDeCarpetas }
}
