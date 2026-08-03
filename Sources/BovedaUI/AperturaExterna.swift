import AppKit
import Foundation

/// Canal para las bóvedas que llegan de fuera de la app: doble clic en el Finder,
/// «Abrir con», o soltar el archivo sobre el icono del Dock.
///
/// Sin esto, el tipo de documento declarado en `Info.plist` sería decorativo: el
/// doble clic abriría la app pero se quedaría en la pantalla de bienvenida.
/// La ventana principal, para poder recuperarla desde AppKit.
///
/// Hace falta porque cancelar el cierre después de pulsar la ⓧ dejaba la app viva
/// **sin ninguna ventana**, y esa es precisamente la condición que vuelve a pedir
/// el cierre: el aviso salía una y otra vez sin nada que mirar detrás.
@MainActor
public enum VentanaPrincipal {
    public static let id = "principal"

    /// Cómo volver a abrirla. La registra la vista, que es quien tiene acceso al
    /// entorno de SwiftUI; desde el delegado no hay forma de pedirlo.
    public static var reabrir: (() -> Void)?

    /// Cuándo se canceló el último cierre. Si llega otra petición pegada a la
    /// anterior, se rechaza sin preguntar: red de seguridad por si reabrir la
    /// ventana fallara, para que nunca se vea el aviso en bucle.
    public static var ultimaCancelacion: Date = .distantPast
}

public enum AperturaExterna {
    public static let notificacion = Notification.Name("com.snapsis.peekaboo.abrirBoveda")

    static func pedir(_ url: URL) {
        NotificationCenter.default.post(name: notificacion, object: nil, userInfo: ["url": url])
    }
}

/// Recibe de macOS los archivos con los que se lanzó o invocó la app.
public final class DelegadoDeApp: NSObject, NSApplicationDelegate {
    public func application(_ application: NSApplication, open urls: [URL]) {
        // Sólo tiene sentido una: la app maneja una bóveda a la vez.
        guard let url = urls.first else { return }
        AperturaExterna.pedir(url)
    }

    /// Cerrar la ventana cierra la app.
    ///
    /// Por defecto macOS deja el programa vivo en el Dock sin ventanas, pero aquí
    /// la ⓧ es lo que la gente usa para «cerrar el programa». Además así la
    /// advertencia de contenido descifrado sale también por esa vía, que es la
    /// que de verdad se usa.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Avisa antes de cerrar si queda contenido descifrado en el disco.
    ///
    /// Cerrar la app **no oculta nada**: lo que esté Visible se queda en claro
    /// donde está. Es fácil olvidarlo justo cuando toca —al apagar el Mac o al
    /// desconectar un disco— y es exactamente cuando más importa.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            // Si se acaba de cancelar, no se vuelve a preguntar: sin esto una
            // petición encadenada repetiría el aviso sin que nadie lo pidiera.
            guard Date().timeIntervalSince(VentanaPrincipal.ultimaCancelacion) > 1.5 else {
                return .terminateCancel
            }
            guard let store = VaultStore.enUso else { return .terminateNow }
            let destapadas = store.bovedasDestapadas
            guard !destapadas.isEmpty else { return .terminateNow }

            let donde = destapadas.map(\.volumen).joined(separator: ", ")
            let alerta = NSAlert()
            alerta.alertStyle = .warning
            alerta.messageText = destapadas.count == 1
                ? "«\(donde)» tiene contenido fuera de la bóveda"
                : "Hay contenido fuera de la bóveda en \(destapadas.count) discos"
            alerta.informativeText = """
                Sus archivos están descifrados en \(donde) y ahí seguirán al cerrar \
                \(InfoApp.nombre): cerrar la app no los oculta.

                Para dejarlos a salvo, cancela y pon esas bóvedas en «Oculta».
                """
            // El botón por defecto es el que no arriesga nada: un Intro de más
            // no debería dejarte los archivos al aire.
            alerta.addButton(withTitle: "Cancelar")
            alerta.addButton(withTitle: "Salir de todos modos")

            guard alerta.runModal() == .alertFirstButtonReturn else { return .terminateNow }

            // Cancelado. Si se llegó aquí desde la ⓧ la ventana ya no existe, y
            // quedarse sin ninguna es lo que reabría el aviso en bucle. Además,
            // cancelar es para ir a ocultar el contenido: hace falta la ventana.
            VentanaPrincipal.ultimaCancelacion = Date()
            if NSApp.windows.allSatisfy({ !$0.isVisible }) {
                VentanaPrincipal.reabrir?()
            }
            return .terminateCancel
        }
    }
}
