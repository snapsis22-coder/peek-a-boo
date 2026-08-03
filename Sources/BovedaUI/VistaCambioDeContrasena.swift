import BovedaKit
import SwiftUI

/// Hoja para cambiar la contraseña, en sus dos formas.
///
/// - **Maestra**: se la cambia a todas las bóvedas abiertas de una vez. Es lo que
///   el usuario entiende por «la contraseña de la app», porque es una sola para
///   todas.
/// - **Una sola**: sirve para unificar una bóveda que aparece marcada «Otra
///   contraseña». Se abre con la suya y se le pone la de la sesión.
public struct VistaCambioDeContrasena: View {

    public enum Alcance: Equatable, Identifiable {
        case maestra
        case una(ResumenBoveda)

        public var id: String {
            switch self {
            case .maestra:      return "maestra"
            case .una(let bov): return bov.ruta
            }
        }
    }

    @Environment(VaultStore.self) private var store
    @Environment(\.dismiss) private var cerrar

    private let alcance: Alcance

    @State private var actual = ""
    @State private var nueva = ""
    @State private var repetida = ""
    @FocusState private var campoEnfocado: Bool

    public init(alcance: Alcance) {
        self.alcance = alcance
    }

    private var esMaestra: Bool { alcance == .maestra }

    private var titulo: String {
        switch alcance {
        case .maestra:        return "Cambiar la contraseña"
        case .una(let bov):   return "Unificar «\(bov.volumen)»"
        }
    }

    private var explicacion: String {
        switch alcance {
        case .maestra:
            return "Se cambiará en todas las bóvedas abiertas. El contenido no se vuelve a cifrar: sólo se resella la clave, así que es instantáneo aunque haya gigas dentro."
        case .una(let bov):
            return "«\(bov.volumen)» se creó con otra contraseña. Escribe la suya y ponle la de esta sesión para que abra junto con las demás."
        }
    }

    /// Con varias bóvedas el cambio puede salir a medias (un disco lleno, otro de
    /// solo lectura). Vale la pena decirlo antes, no después.
    private var avisoDeVarias: String? {
        guard esMaestra else { return nil }
        let abiertas = store.bovedas.filter(\.abierta).count
        guard abiertas > 1 else { return nil }
        return "Hay \(abiertas) bóvedas abiertas. Si alguna falla, las demás sí quedan cambiadas y te diré cuál se quedó atrás."
    }

    private var problema: String? {
        if !nueva.isEmpty, !repetida.isEmpty, nueva != repetida { return "Las contraseñas nuevas no coinciden." }
        if !nueva.isEmpty, nueva == actual { return "La nueva es igual a la actual." }
        return nil
    }

    private var puedeGuardar: Bool {
        !actual.isEmpty && !nueva.isEmpty && nueva == repetida && nueva != actual && !store.ocupada
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(titulo).font(.headline)

            Text(explicacion)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                SecureField(esMaestra ? "Contraseña actual" : "Contraseña de esta bóveda",
                            text: $actual)
                    .focused($campoEnfocado)
                SecureField("Contraseña nueva", text: $nueva)
                SecureField("Repetir la nueva", text: $repetida)
            }
            .textFieldStyle(.roundedBorder)

            // Al unificar, lo normal es querer la de la sesión: se ofrece rellenarla
            // sin enseñarla en pantalla.
            if !esMaestra, store.haySesionAbierta {
                Button("Usar la contraseña de esta sesión") {
                    if let sesion = store.contrasenaDeLaSesionParaUnificar() {
                        nueva = sesion
                        repetida = sesion
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            if let problema {
                Label(problema, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let avisoDeVarias {
                Label(avisoDeVarias, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Si olvidas la nueva, no hay forma de recuperar lo que hay dentro.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { cerrar() }
                Button("Cambiar") { guardar() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!puedeGuardar)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { campoEnfocado = true }
    }

    private func guardar() {
        switch alcance {
        case .maestra:
            store.cambiarContrasenaMaestra(actual: actual, nueva: nueva)
        case .una(let boveda):
            store.cambiarContrasenaDe(boveda, actual: actual, nueva: nueva)
        }
        cerrar()
    }
}
