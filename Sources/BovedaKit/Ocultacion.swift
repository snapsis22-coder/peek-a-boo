import Foundation

/// Ocultar la bóveda en el Finder, como hacía Hider 2.
///
/// Usa el flag `UF_HIDDEN` del sistema de archivos. Probado en APFS y en **exFAT**,
/// donde macOS lo mapea al bit «hidden» heredado de DOS y sobrevive a desmontar el
/// disco — que es lo que permite tener la bóveda oculta en un disco externo.
///
/// ⚠️ Alcance real: oculta del Finder en uso normal, **no** de `Cmd+Shift+.` ni de
/// `ls -la` (comprobado el 25-jul-2026: con los ocultos activados se ven tanto los
/// archivos con punto como los que llevan este flag). La protección de verdad es el
/// cifrado; esto sólo evita que el archivo estorbe o llame la atención.
///
/// Hider 2 no podía hacer esto en exFAT: su vault era un bundle-carpeta con una base
/// SQLite/Core Data dentro (`tabula`, `-wal`, `-shm`), y SQLite necesita bloqueo de
/// archivos y semántica POSIX que exFAT no da de forma fiable. Un solo archivo, sin
/// base de datos y sin depender de permisos POSIX, es lo que nos deja funcionar ahí.
public extension Vault {

    static func estaOculta(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BovedaError.archivoNoEncontrado(url)
        }
        let valores = try url.resourceValues(forKeys: [.isHiddenKey])
        return valores.isHidden ?? false
    }

    /// Aplica o quita el flag. No necesita la contraseña: es una propiedad del
    /// archivo, no de su contenido.
    static func ocultar(_ url: URL, _ oculta: Bool) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BovedaError.archivoNoEncontrado(url)
        }
        var objetivo = url
        var valores = URLResourceValues()
        valores.isHidden = oculta
        do {
            try objetivo.setResourceValues(valores)
        } catch {
            throw BovedaError.entradaSalida(
                "no se pudo \(oculta ? "ocultar" : "mostrar") el archivo: \(error.localizedDescription)")
        }
    }
}
