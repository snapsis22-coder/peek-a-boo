import AppKit
import BovedaKit
import SwiftUI

/// El contenido de una bóveda: sus carpetas y sus archivos sueltos, cada uno con
/// su propio interruptor. El de la bóveda entera está en la pantalla anterior.
public struct VistaDetalle: View {

    @Environment(VaultStore.self) private var store

    let boveda: ResumenBoveda

    /// Carpetas y archivos comparten tipo de identificador (`UUID`), así que la
    /// lista puede seleccionar unos y otros a la vez.
    @State private var seleccion = Set<UUID>()
    @State private var recibiendoArrastre = false
    /// Lo que se va a eliminar, mientras se confirma.
    @State private var aEliminar = Set<UUID>()

    public init(boveda: ResumenBoveda) {
        self.boveda = boveda
    }

    public var body: some View {
        Group {
                if boveda.estaVacia {
                    estadoVacio
                } else {
                    lista
                }
            }
            .toolbar { barra }
            .navigationTitle(InfoApp.nombre)
            .navigationSubtitle(boveda.volumen)
            // Arrastrar y soltar: el gesto principal. Acepta archivos y carpetas.
            .dropDestination(for: URL.self) { urls, _ in
                store.agregar(archivos: urls, a: boveda)
                return true
            } isTargeted: { activo in
                recibiendoArrastre = activo
            }
            .overlay {
                if recibiendoArrastre { capaDeArrastre }
            }
            .background { confirmacionDeEliminar }
            .frame(minWidth: 520, minHeight: 400)
        }

        // MARK: - Lista

        private var lista: some View {
            List(selection: $seleccion) {
                if !boveda.carpetas.isEmpty {
                    Section("Carpetas") {
                        ForEach(boveda.carpetas) { carpeta in
                            filaDeCarpeta(carpeta).tag(carpeta.id)
                        }
                    }
                }
                if !boveda.sueltos.isEmpty {
                    Section("Archivos") {
                        ForEach(boveda.sueltos) { entrada in
                            filaDeArchivo(entrada).tag(entrada.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: UUID.self) { ids in
                if !ids.isEmpty {
                    if let carpeta = carpetasDe(ids).first, ids.count == 1, carpeta.isDeployed {
                        Button("Mostrar en el Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([carpeta.url])
                        }
                        Divider()
                    }
                    if !sueltosDe(ids).isEmpty {
                        Button("Extraer una copia…") { extraerSeleccion(ids) }
                    }
                    Button("Sacar de la bóveda") { sacarSeleccion(ids) }
                    Divider()
                    Button("Eliminar de la bóveda", role: .destructive) { aEliminar = ids }
                }
            }
        }

        private func filaDeCarpeta(_ carpeta: ManagedFolder) -> some View {
            HStack(spacing: 10) {
                Image(systemName: carpeta.isDeployed ? "folder" : "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(carpeta.isDeployed ? Color.orange : Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(carpeta.name).lineLimit(1)
                    Text(subtituloDe(visible: carpeta.isDeployed,
                                     ruta: carpeta.originalPath,
                                     extra: "\(carpeta.fileCount) archivos · \(Formato.tamano(carpeta.totalSize))"))
                        .font(.caption)
                        .foregroundStyle(carpeta.isDeployed ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button(carpeta.isDeployed ? "Ocultar" : "Visible") {
                    carpeta.isDeployed
                        ? store.esconder(carpeta, en: boveda)
                        : store.mostrar(carpeta, en: boveda)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.ocupada)
            }
            .padding(.vertical, 3)
        }

        private func filaDeArchivo(_ entrada: VaultEntry) -> some View {
            let visible = entrada.isDeployed ?? false
            return HStack(spacing: 10) {
                Image(systemName: icono(para: entrada.name))
                    .font(.system(size: 22))
                    .foregroundStyle(visible ? Color.orange : Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entrada.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtituloDe(visible: visible,
                                     ruta: entrada.originalPath,
                                     extra: Formato.tamano(entrada.size)))
                        .font(.caption)
                        .foregroundStyle(visible ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if entrada.originalPath != nil {
                    Button(visible ? "Ocultar" : "Visible") {
                        store.alternar(entrada, en: boveda)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.ocupada)
                }
            }
            .padding(.vertical, 2)
        }

        /// «Visible en ~/Documentos · 2,4 MB» o «Cifrado · 2,4 MB»
        private func subtituloDe(visible: Bool, ruta: String?, extra: String) -> String {
            guard visible, let ruta else { return "Cifrado · \(extra)" }
            let carpeta = (ruta as NSString).deletingLastPathComponent
                .replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return "Visible en \(carpeta) · \(extra)"
        }

        private var estadoVacio: some View {
            VStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                Text("Esta bóveda está vacía")
                    .font(.title3.weight(.medium))
                Text("Arrastra una carpeta para cifrarla y quitarla del disco.\nVolverá a su sitio cuando la pongas en Visible.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private var capaDeArrastre: some View {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    Label("Soltar para cifrar", systemImage: "lock.fill")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.tint)
                }
                .padding(8)
                .allowsHitTesting(false)
        }

        // MARK: - Barra

        /// Todo en `.navigation`, o sea a la izquierda, junto al título.
        ///
        /// Antes iban al extremo derecho de la ventana: ahí el menú desplegable se
        /// abría contra el borde y tapaba los interruptores de las filas.
        @ToolbarContentBuilder
        private var barra: some ToolbarContent {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.volverALaLista()
                } label: {
                    Label("Bóvedas", systemImage: "chevron.left")
                }
                .help("Volver a la lista de bóvedas")

                Menu {
                    Button("Guardar una carpeta…") { store.elegirCarpetaParaGuardar(en: boveda) }
                    Button("Guardar archivos…") { store.elegirArchivosParaGuardar(en: boveda) }
                } label: {
                    Label("Agregar", systemImage: "plus")
                }
                .help("Guardar algo nuevo en esta bóveda")

                Button {
                    sacarSeleccion(seleccion)
                } label: {
                    Label("Sacar", systemImage: "arrow.up.forward.square")
                }
                .help("Devolver al disco lo señalado y quitarlo de la bóveda")
                .disabled(seleccion.isEmpty || store.ocupada)

                Button {
                    aEliminar = seleccion
                } label: {
                    Label("Eliminar", systemImage: "trash")
                }
                .help("Quitar de la bóveda lo señalado")
                .disabled(seleccion.isEmpty || store.ocupada)

                Button {
                    extraerSeleccion(seleccion)
                } label: {
                    Label("Extraer una copia", systemImage: "square.and.arrow.down")
                }
                .help("Guardar fuera una copia descifrada, sin sacarla de la bóveda")
                .disabled(sueltosDe(seleccion).isEmpty || store.ocupada)

                Button {
                    store.compactar(boveda)
                } label: {
                    Label("Compactar", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .help(boveda.espacioMuerto > 0
                      ? "Recuperar \(Formato.tamano(boveda.espacioMuerto)) de lo que ya se borró"
                      : "No hay espacio que recuperar")
                .disabled(boveda.espacioMuerto == 0 || store.ocupada)
            }
        }

        /// Eliminar sí puede perder datos, así que se pregunta —y se dice exactamente
        /// qué se pierde y qué no.
        private var confirmacionDeEliminar: some View {
            EmptyView()
                .confirmationDialog("¿Quitar \(descripcionDe(aEliminar)) de la bóveda?",
                                    isPresented: Binding(get: { !aEliminar.isEmpty },
                                                         set: { if !$0 { aEliminar = [] } })) {
                    Button("Eliminar de la bóveda", role: .destructive) {
                        eliminarSeleccion(aEliminar)
                        aEliminar = []
                    }
                    Button("Mejor sacarlo al disco") {
                        sacarSeleccion(aEliminar)
                        aEliminar = []
                    }
                    Button("Cancelar", role: .cancel) { aEliminar = [] }
                } message: {
                    Text(hayContenidoSoloEnLaBoveda(aEliminar)
                         ? "Parte de esto sólo existe cifrado aquí dentro: al eliminarlo se pierde y no se puede recuperar. «Sacarlo al disco» lo devuelve a su sitio antes de quitarlo de la bóveda."
                         : "Lo que está visible en el disco se queda donde está; sólo deja de gestionarse desde la bóveda.")
                }
        }

        // MARK: - Acciones

        /// Las carpetas señaladas. La lista mezcla los dos tipos, así que hay que
        /// separarlos para saber a qué acción corresponde cada identificador.
        private func carpetasDe(_ ids: Set<UUID>) -> [ManagedFolder] {
            boveda.carpetas.filter { ids.contains($0.id) }
        }

        private func sueltosDe(_ ids: Set<UUID>) -> [VaultEntry] {
            boveda.sueltos.filter { ids.contains($0.id) }
        }

        private func extraerSeleccion(_ ids: Set<UUID>) {
            store.extraer(sueltosDe(ids), de: boveda)
        }

        private func sacarSeleccion(_ ids: Set<UUID>) {
            store.sacar(carpetas: carpetasDe(ids), archivos: sueltosDe(ids), de: boveda)
            seleccion.subtract(ids)
        }

        private func eliminarSeleccion(_ ids: Set<UUID>) {
            store.eliminar(carpetas: carpetasDe(ids), archivos: sueltosDe(ids), de: boveda)
            seleccion.subtract(ids)
        }

        /// Lo que se perdería al eliminar: lo que sólo existe cifrado aquí dentro.
        private func hayContenidoSoloEnLaBoveda(_ ids: Set<UUID>) -> Bool {
            carpetasDe(ids).contains { !$0.isDeployed }
                || sueltosDe(ids).contains { !($0.isDeployed ?? false) }
        }

        private func descripcionDe(_ ids: Set<UUID>) -> String {
            let carpetas = carpetasDe(ids).count
            let archivos = sueltosDe(ids).count
            var partes: [String] = []
            if carpetas > 0 { partes.append(carpetas == 1 ? "1 carpeta" : "\(carpetas) carpetas") }
            if archivos > 0 { partes.append(archivos == 1 ? "1 archivo" : "\(archivos) archivos") }
            return partes.joined(separator: " y ")
        }

        private func icono(para nombre: String) -> String {
            switch (nombre as NSString).pathExtension.lowercased() {
            case "pdf":                               return "doc.richtext"
            case "jpg", "jpeg", "png", "heic", "gif": return "photo"
            case "mov", "mp4", "m4v", "avi":          return "film"
            case "mp3", "m4a", "wav", "aac":          return "music.note"
            case "zip", "dmg", "gz", "7z":            return "shippingbox"
            case "doc", "docx", "pages":              return "doc.text"
            case "xls", "xlsx", "numbers", "csv":     return "tablecells"
            case "txt", "md", "rtf":                  return "doc.plaintext"
            default:                                  return "doc"
            }
        }
    }

    // Con PreviewProvider y no con #Preview: la macro necesita Xcode y este proyecto
    // se compila con las herramientas de línea de comandos.
    struct Vista_Con_contenido_2: PreviewProvider {
        static var previews: some View {
            Group {
            VistaDetalle(boveda: ResumenBoveda.ejemplos[0])
                .environment(VaultStore.ejemploDetalle())
        }
        .previewDisplayName("Con contenido")
    }
}
