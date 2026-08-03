import AppKit
import BovedaKit
import SwiftUI

/// La lista de bóvedas, una por disco, con su interruptor Visible ⇄ Oculta.
///
/// Este es el centro de la app: desde aquí se devuelve todo a su sitio o se
/// vuelve a esconder, sin entrar en el detalle de cada bóveda.
public struct VistaBovedas: View {

    @Environment(VaultStore.self) private var store

    /// Bóveda que se va a recrear, mientras se confirma.
    @State private var aRecrear: ResumenBoveda?
    /// Qué contraseña se está cambiando, mientras la hoja está abierta.
    @State private var cambioAbierto: VistaCambioDeContrasena.Alcance?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(store.bovedasExistentes) { boveda in
                    fila(boveda)
                }

                if !store.volumenesSinBoveda.isEmpty {
                    Divider().padding(.vertical, 4)
                    ForEach(store.volumenesSinBoveda) { volumen in
                        filaSinBoveda(volumen)
                    }
                }
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 400)
        .toolbar {
            ToolbarItem {
                Button {
                    store.salir()
                } label: {
                    Label("Bloquear", systemImage: "lock.fill")
                }
                // Con el candado a secas no se sabía qué hacía, y es el botón que
                // te echa de la sesión: la palabra va siempre visible, no sólo en
                // el globo de ayuda.
                .labelStyle(.titleAndIcon)
                .help("Bloquear: cierra las bóvedas y olvida la contraseña de esta sesión")
            }

            ToolbarItem {
                Button {
                    cambioAbierto = .maestra
                } label: {
                    Label("Contraseña", systemImage: "key.fill")
                }
                .labelStyle(.titleAndIcon)
                .help("Cambiar la contraseña de todas las bóvedas abiertas")
                .disabled(store.ocupada || !store.bovedas.contains(where: \.abierta))
            }
        }
        .sheet(item: $cambioAbierto) { alcance in
            VistaCambioDeContrasena(alcance: alcance)
                .environment(store)
        }
        .confirmationDialog("¿Crear una bóveda nueva en «\(aRecrear?.volumen ?? "")»?",
                            isPresented: Binding(get: { aRecrear != nil },
                                                 set: { if !$0 { aRecrear = nil } }),
                            presenting: aRecrear) { boveda in
            Button("Crear una nueva") {
                store.recrear(en: boveda)
                aRecrear = nil
            }
            Button("Cancelar", role: .cancel) { aRecrear = nil }
        } message: { _ in
            Text("""
                La bóveda actual no se borra: queda apartada al lado con otro nombre, \
                por si algún día se puede abrir. La nueva empieza vacía y usa la \
                contraseña de esta sesión.
                """)
        }
    }

    // MARK: - Filas

    private func fila(_ boveda: ResumenBoveda) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: iconoDe(boveda)))
                    .resizable()
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(boveda.volumen)
                            .font(.headline)
                        if boveda.esExtraible {
                            Image(systemName: "externaldrive")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    estadoDe(boveda)
                }

                Spacer(minLength: 8)

                expulsar(boveda)

                if boveda.abierta {
                    interruptor(boveda)
                } else {
                    noAbre(boveda)
                }
            }
            .padding(12)

            if boveda.abierta {
                Divider()
                HStack {
                    Text(boveda.estaVacia
                         ? "Vacía · arrastra carpetas dentro"
                         : "\(boveda.carpetas.count) carpetas · \(boveda.sueltos.count) archivos · \(Formato.tamano(boveda.tamanoTotal))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // La bandeja llena dice «aquí dentro hay cosas» sin prometer
                    // si son carpetas o archivos, que dentro hay de las dos.
                    // En vertical y con el icono grande: es la puerta a lo que
                    // guardas, no merecía leerse como una nota al pie.
                    Button {
                        store.abrirDetalle(boveda)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "tray.full.fill")
                                .font(.system(size: 22))
                            Text("Ver contenido")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .help(boveda.ruta)
    }

    private func filaSinBoveda(_ volumen: ResumenBoveda) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: iconoDe(volumen)))
                .resizable()
                .frame(width: 30, height: 30)
                .opacity(0.55)

            VStack(alignment: .leading, spacing: 2) {
                Text(volumen.volumen)
                    .fontWeight(.medium)
                Text("Sin bóveda · \(Formato.tamano(volumen.espacioLibre)) libres")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            expulsar(volumen)

            Button("Crear aquí") { store.crear(en: volumen) }
                .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Expulsar el disco. Sólo aparece en los extraíbles.
    ///
    /// Se deja **visible pero apagado** cuando no procede, con el motivo en el
    /// globo de ayuda: esconderlo dejaría al usuario buscando un botón que a
    /// veces está y a veces no.
    @ViewBuilder
    private func expulsar(_ boveda: ResumenBoveda) -> some View {
        if boveda.esExtraible, !boveda.esArranque {
            Button {
                store.expulsar(boveda)
            } label: {
                Image(systemName: "eject.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .disabled(!boveda.sePuedeExpulsar || store.ocupada)
            .help(boveda.motivoParaNoExpulsar ?? "Expulsar «\(boveda.volumen)»")
        }
    }

    /// La bóveda está ahí pero no se abre. El motivo cambia lo que se ofrece:
    /// **«Recrear…» sólo aparece si el archivo está roto de verdad.** Con una
    /// bóveda sana de otra contraseña, ese botón sólo servía para apartarla por
    /// error; lo que hace falta ahí es la contraseña, no empezar de cero.
    @ViewBuilder
    private func noAbre(_ boveda: ResumenBoveda) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            switch boveda.motivo {
            case .otraContrasena:
                Label("Otra contraseña", systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("La bóveda está intacta, pero se creó con otra contraseña")

                // Sin esto, una bóveda con otra contraseña se quedaba aparte para
                // siempre: la única salida a mano era «Recrear…», que la aparta y
                // empieza de cero. Aquí se abre con la suya y se unifica.
                Button("Unificar…") { cambioAbierto = .una(boveda) }
                    .controlSize(.small)
                    .disabled(store.ocupada)
                    .help("Ponerle la contraseña de esta sesión para que abra con las demás")

            case .enUso:
                Label("En uso", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Otro programa tiene esta bóveda abierta")

            case .danada, .none:
                Label("Dañada", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("La cabecera no se puede leer: el archivo está dañado")

                Button("Recrear…") { aRecrear = boveda }
                    .controlSize(.small)
                    .disabled(store.ocupada)
            }
        }
    }

    /// El interruptor: una sola pulsación mueve todo el contenido.
    private func interruptor(_ boveda: ResumenBoveda) -> some View {
        VStack(spacing: 3) {
            Button {
                store.alternar(boveda)
            } label: {
                Label(boveda.visibilidad == .visible ? "Ocultar" : "Visible",
                      systemImage: boveda.visibilidad == .visible ? "eye.slash.fill" : "eye.fill")
                    .frame(width: 88)
            }
            .buttonStyle(.borderedProminent)
            .tint(boveda.visibilidad == .visible ? .orange : .accentColor)
            .disabled(boveda.estaVacia || store.ocupada)

            if boveda.visibilidad == .parcial {
                Text("a medias")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func estadoDe(_ boveda: ResumenBoveda) -> some View {
        HStack(spacing: 4) {
            switch boveda.visibilidad {
            case .visible:
                Image(systemName: "eye")
                Text("Todo visible en su sitio")
            case .oculta:
                Image(systemName: "lock.fill")
                Text(boveda.estaVacia ? "Lista para guardar" : "Todo cifrado y escondido")
            case .parcial:
                Image(systemName: "circle.lefthalf.filled")
                Text("Parte visible, parte escondida")
            }
        }
        .font(.caption)
        .foregroundStyle(boveda.visibilidad == .visible ? Color.orange : Color.secondary)
    }

    /// El icono del volumen, no el del archivo de bóveda (que está oculto).
    private func iconoDe(_ boveda: ResumenBoveda) -> String {
        boveda.esArranque ? "/" : "/Volumes/\(boveda.volumen)"
    }
}

#Preview("Bóvedas") {
    VistaBovedas()
        .environment(VaultStore.ejemploLista())
}

#Preview("Trabajando") {
    VistaBovedas()
        .environment(VaultStore.ejemploTrabajando())
}
