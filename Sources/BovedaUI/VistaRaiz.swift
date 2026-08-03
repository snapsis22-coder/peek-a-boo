import BovedaKit
import SwiftUI

/// Decide qué pantalla toca: contraseña → lista de bóvedas → detalle de una.
public struct VistaRaiz: View {

    // Compartida, no propia: si la ventana se cierra y se vuelve a abrir, hay que
    // seguir en la misma sesión. Ver `VaultStore.compartida()`.
    @State private var store = VaultStore.compartida()
    @Environment(\.openWindow) private var abrirVentana

    public init() {}

    public var body: some View {
        @Bindable var store = store

        Group {
            switch store.estado {
            case .primeraVez:
                VistaContrasena(esPrimeraVez: true)
            case .contrasena:
                VistaContrasena(esPrimeraVez: false)
            case .lista:
                VistaBovedas()
            case .detalle:
                if let actual = store.bovedaActual {
                    VistaDetalle(boveda: actual)
                } else {
                    // La bóveda desapareció (disco expulsado, por ejemplo).
                    VistaBovedas()
                }
            }
        }
        .environment(store)
        // Desde aquí, con la instancia que SwiftUI conservó de verdad: hacerlo
        // en `VaultStore.init` registraba copias que se descartan.
        .onAppear {
            store.registrarSesion()
            // El delegado no tiene acceso al entorno de SwiftUI: se le deja aquí
            // la forma de recuperar la ventana si se cancela el cierre.
            VentanaPrincipal.reabrir = { abrirVentana(id: VentanaPrincipal.id) }
        }
        .animation(.easeInOut(duration: 0.2), value: store.estado)
        // La capa de progreso cubre todas las pantallas: cifrar y descifrar puede
        // ocurrir tanto desde la lista como desde el detalle.
        .overlay {
            if store.muestraCapaDeProgreso { CapaDeProgreso(progreso: store.progreso) }
        }
        .alert("No se pudo completar la operación",
               isPresented: Binding(get: { store.mensajeDeError != nil },
                                    set: { if !$0 { store.mensajeDeError = nil } })) {
            Button("Entendido", role: .cancel) { store.mensajeDeError = nil }
        } message: {
            Text(store.mensajeDeError ?? "")
        }
        .alert("Listo",
               isPresented: Binding(get: { store.aviso != nil },
                                    set: { if !$0 { store.aviso = nil } })) {
            Button("Entendido", role: .cancel) { store.aviso = nil }
        } message: {
            Text(store.aviso ?? "")
        }
    }
}

/// Tapa la ventana mientras se cifra o descifra. Además de informar, evita que se
/// toque nada a mitad de una operación que está moviendo archivos de verdad.
struct CapaDeProgreso: View {
    let progreso: Progreso?

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)

            VStack(spacing: 14) {
                if let progreso {
                    Text(progreso.titulo)
                        .font(.headline)

                    ProgressView(value: progreso.fraccion)
                        .progressViewStyle(.linear)
                        .frame(width: 280)

                    VStack(spacing: 4) {
                        Text(progreso.detalle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(progreso.actual) de \(progreso.total)")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 280)
                } else {
                    ProgressView()
                    Text("Trabajando…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
        .transition(.opacity)
    }
}

#Preview("Raíz") {
    VistaRaiz()
}
