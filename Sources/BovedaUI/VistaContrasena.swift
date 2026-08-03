import BovedaKit
import SwiftUI

/// Lo primero que se ve al abrir la app.
///
/// En el primer arranque de un Mac —cuando no hay ni una bóveda— pide contraseña
/// nueva y crea la del disco del sistema. El resto de las veces sólo la pide para
/// abrir con ella las bóvedas que encuentre.
public struct VistaContrasena: View {

    @Environment(VaultStore.self) private var store

    private let esPrimeraVez: Bool

    @State private var contrasena = ""
    @State private var repetida = ""
    @FocusState private var campoEnfocado: Bool
    /// Las dos fases del candado. Van separadas porque se encadenan: primero
    /// sube, y sólo cuando la pata corta ha salido del cuerpo empieza el giro.
    @State private var alzado: CGFloat = 0
    @State private var giro: CGFloat = 0

    public init(esPrimeraVez: Bool) {
        self.esPrimeraVez = esPrimeraVez
    }

    private var puedeContinuar: Bool {
        guard !contrasena.isEmpty else { return false }
        return esPrimeraVez ? contrasena == repetida : true
    }

    private var aviso: String? {
        guard esPrimeraVez, !repetida.isEmpty, contrasena != repetida else { return nil }
        return "Las contraseñas no coinciden."
    }

    public var body: some View {
        VStack(spacing: 18) {
            // En el primer arranque nace abierto: todavía no hay nada que guardar.
            Candado(alzado: alzado, giro: giro, lado: 96)

            VStack(spacing: 6) {
                Text(InfoApp.nombre)
                    .font(.title2.weight(.semibold))
                Text(esPrimeraVez
                     ? "Elige tu contraseña. Es la única que necesitarás, y protege todo lo que guardes."
                     : "Introduce tu contraseña.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 320)
            }

            VStack(spacing: 8) {
                SecureField("Contraseña", text: $contrasena)
                    .textFieldStyle(.roundedBorder)
                    .focused($campoEnfocado)
                    .onSubmit(continuar)

                if esPrimeraVez {
                    SecureField("Repetir contraseña", text: $repetida)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(continuar)
                }

                if let aviso {
                    Text(aviso)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // La espera manda sobre el «contraseña incorrecta»: es lo que
                // explica por qué el botón no responde. El texto se recalcula solo
                // cada segundo porque `esperaDeIntentos` es observable.
                if store.esperaDeIntentos > 0 {
                    Label("Demasiados intentos. Puedes volver a intentarlo en \(ControlDeIntentos.enPalabras(store.esperaDeIntentos)).",
                          systemImage: "clock.badge.exclamationmark.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let fallo = store.errorDeContrasena {
                    Label(fallo, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 300)

            if esPrimeraVez {
                Label("Si la olvidas, el contenido se pierde: no hay forma de recuperarlo.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 300, alignment: .leading)
            }

            // Aquí vivía un botón «Usar Touch ID» con el cuerpo vacío: se veía en
            // los Mac con lector y no hacía nada al pulsarlo. Sin Team ID la clave
            // no puede quedar protegida por hardware, así que no hay botón.
            // El indicador va dentro del botón y en un ZStack: sin capa que tape la
            // ventana y sin que nada cambie de tamaño al aparecer.
            Button(action: continuar) {
                ZStack {
                    Text(esPrimeraVez ? "Crear mi bóveda" : "Entrar")
                        .opacity(store.ocupada || store.desbloqueada ? 0 : 1)
                    if store.ocupada {
                        ProgressView().controlSize(.small)
                    }
                    // Acierto: el visto sustituye al texto mientras el candado se
                    // abre. Dura lo que la animación, no hace esperar de más.
                    if store.desbloqueada {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // El botón se pone verde al acertar: refuerza el visto sin añadir
            // otro elemento a una pantalla que ya tiene bastante ocurriendo.
            .tint(store.desbloqueada ? .green : .accentColor)
            .disabled(!puedeContinuar || store.ocupada || store.desbloqueada
                      || store.esperaDeIntentos > 0)
            .controlSize(.large)
            .frame(width: 300)
            .animation(.spring(response: 0.28, dampingFraction: 0.7),
                       value: store.desbloqueada)
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 420)
        // Se puede escribir la contraseña nada más abrir, sin pinchar el campo.
        // Hacen falta las dos cosas: `defaultFocus` es la vía buena, pero al
        // arrancar en frío la ventana todavía no es la activa y el foco se
        // pierde, así que se vuelve a pedir cuando ya lo es.
        .defaultFocus($campoEnfocado, true)
        .onAppear {
            enfocarElCampo()
            // Sin bóvedas todavía, el candado ya está abierto de entrada.
            if esPrimeraVez {
                alzado = 1
                giro = 1
            } else if store.bloqueando {
                cerrarElCandado()
            }
        }
        // Al corregir, el error de antes deja de aplicar.
        .onChange(of: contrasena) { store.errorDeContrasena = nil }
        .onChange(of: store.desbloqueada) { _, seAbrio in
            guard seAbrio else { alzado = 0; giro = 0; return }
            // El clac va con el salto del arco, que es cuando cede el pestillo.
            Sonidos.reproducir(Sonidos.abrir)
            withAnimation(.spring(response: 0.24, dampingFraction: 0.55)) {
                alzado = 1
            }
            withAnimation(.easeInOut(duration: 0.40).delay(0.20)) {
                giro = 1
            }
        }
    }

    /// Pide el foco varias veces durante el primer medio segundo.
    ///
    /// Con una sola vez no basta: al abrir la app en frío la ventana tarda un
    /// momento en volverse la activa, y una petición de foco anterior a eso se
    /// descarta sin más. En cuanto una prende, las siguientes no molestan.
    private func enfocarElCampo() {
        campoEnfocado = true
        Task { @MainActor in
            for espera in [60, 180, 400] {
                try? await Task.sleep(for: .milliseconds(espera))
                guard !campoEnfocado else { return }
                campoEnfocado = true
            }
        }
    }

    /// El cierre es la apertura al revés: primero deshace el giro, y sólo cuando
    /// el arco vuelve a estar en el plano lo deja caer sobre el cuerpo.
    private func cerrarElCandado() {
        alzado = 1
        giro = 1
        // El salto de fotograma es necesario: puestos y animados en la misma
        // pasada, SwiftUI vería un único valor final y no habría transición.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            withAnimation(.easeInOut(duration: 0.38)) { giro = 0 }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72).delay(0.32)) { alzado = 0 }
            // El clac va cuando el arco cae sobre el cuerpo, no al empezar.
            try? await Task.sleep(for: .milliseconds(320))
            Sonidos.reproducir(Sonidos.cerrar)
        }
    }

    private func continuar() {
        guard puedeContinuar else { return }
        if esPrimeraVez {
            store.configurarPorPrimeraVez(contrasena: contrasena)
        } else {
            store.entrar(contrasena: contrasena)
        }
        contrasena = ""
        repetida = ""
    }
}

#Preview("Entrar") {
    VistaContrasena(esPrimeraVez: false)
        .environment(VaultStore.ejemploContrasena())
}

#Preview("Primer arranque") {
    VistaContrasena(esPrimeraVez: true)
        .environment(VaultStore.ejemploPrimeraVez())
}
