import BovedaUI
import SwiftUI

/// El ejecutable no hace más que abrir la ventana: todo lo demás vive en
/// `BovedaUI` (para que funcionen las previews) y en `BovedaKit`.
@main
struct BovedaApp: App {
    /// Necesario para recibir los archivos abiertos desde el Finder.
    @NSApplicationDelegateAdaptor(DelegadoDeApp.self) private var delegado

    init() {
        // Cifrando o descifrando no se cierra la app a medias.
        Actualizaciones.compartido.ocupada = { VaultStore.enUso?.ocupada ?? false }
        Actualizaciones.compartido.arrancar()
    }

    var body: some Scene {
        // Con identificador para poder recuperarla desde el delegado si se
        // cancela el cierre tras pulsar la ⓧ.
        WindowGroup(id: VentanaPrincipal.id) {
            VistaRaiz()
        }
        // 440 pt de ancho dejaban sin sitio a los botones de la barra y macOS los
        // colapsaba en un «»». 600 es lo mínimo para que se vean todos.
        .defaultSize(width: 600, height: 480)
        .windowResizability(.contentMinSize)
        .commands {
            // El menú «Nuevo» por defecto no tiene sentido aquí todavía.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) { ComandosDeActualizacion() }
        }
    }
}
