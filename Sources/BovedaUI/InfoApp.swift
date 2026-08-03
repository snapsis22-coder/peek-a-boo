import Foundation

/// Datos de identidad de la app.
///
/// El nombre se lee del bundle y no se escribe a mano en ninguna vista: al
/// renombrar la app en `Info.plist` y `build_app.sh`, la interfaz se entera sola.
/// (Ya pasó una vez: la app se llamaba «Peek a Boo» y la pantalla de inicio
/// seguía diciendo «Bóveda».)
enum InfoApp {

    static var nombre: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Peek a Boo"  // en las previews de Xcode no hay bundle de la app
    }

    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "—"
    }
}
