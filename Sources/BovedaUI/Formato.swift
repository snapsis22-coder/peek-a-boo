import Foundation

/// Formateadores compartidos por las vistas. Se crean una sola vez: construir un
/// `DateFormatter` en el cuerpo de una vista es caro y se repite en cada redibujado.
enum Formato {

    private static let tamanos: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let fechaRelativa: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_CO")
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let fechaCompleta: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CO")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func tamano(_ bytes: UInt64) -> String {
        tamanos.string(fromByteCount: Int64(bytes))
    }

    /// «hace 2 h» para lo reciente, fecha normal para lo viejo: en una lista de
    /// archivos lo cercano se lee mejor en relativo.
    static func fecha(_ fecha: Date) -> String {
        let transcurrido = Date().timeIntervalSince(fecha)
        if transcurrido < 86_400 * 7 {
            return fechaRelativa.localizedString(for: fecha, relativeTo: Date())
        }
        return fechaCompleta.string(from: fecha)
    }

    static func fechaLarga(_ fecha: Date) -> String {
        fechaCompleta.string(from: fecha)
    }
}
