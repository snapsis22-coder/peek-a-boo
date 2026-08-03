import BovedaKit
import Foundation

/// Estado del trabajo en curso, para pintar la barra de progreso.
public struct Progreso: Sendable, Equatable {
    public var titulo: String
    public var detalle: String
    public var actual: Int
    public var total: Int

    public var fraccion: Double {
        total > 0 ? Double(actual) / Double(total) : 0
    }
}

/// Una bóveda tal como la ve la interfaz.
public struct ResumenBoveda: Sendable, Identifiable, Equatable {
    public var id: String { ruta }

    public let ruta: String
    public let volumen: String
    public let esArranque: Bool
    public let esExtraible: Bool
    public let espacioLibre: UInt64

    /// El archivo existe en el disco.
    public let existe: Bool
    /// Se pudo abrir con la contraseña de la sesión.
    public let abierta: Bool
    /// Por qué no abrió. `nil` si abrió o si ni siquiera existe.
    ///
    /// Distinguir el motivo importa: «otra contraseña» es un archivo perfectamente
    /// sano y ofrecer ahí «Recrear…» invita a apartar una bóveda buena por un
    /// simple dedazo. Sólo una bóveda realmente rota justifica ese botón.
    public var motivo: MotivoCerrada?
    public let visibilidad: Vault.Visibilidad
    public let carpetas: [ManagedFolder]
    public let sueltos: [VaultEntry]
    public let tamanoTotal: UInt64
    /// Bytes que ocupa lo que ya se borró y que `compactar` devuelve al disco.
    public let espacioMuerto: UInt64

    public var url: URL { URL(fileURLWithPath: ruta) }
    public var estaVacia: Bool { carpetas.isEmpty && sueltos.isEmpty }

    /// La raíz del volumen. Para el disco de arranque no aplica: su bóveda vive
    /// en la carpeta personal, no en la raíz.
    public var volumenURL: URL { url.deletingLastPathComponent() }

    /// Si se puede expulsar el disco sin dejarse nada en claro encima.
    ///
    /// Con la bóveda **Visible** sus archivos están descifrados sobre ese disco:
    /// expulsarlo así se llevaría el contenido en claro fuera del Mac, que es
    /// justo lo que la app existe para evitar. Se exige que esté oculta o vacía.
    ///
    /// Cuando la bóveda no abre con la contraseña de la sesión no hay forma de
    /// saber en qué estado quedó —la visibilidad se guarda dentro— así que
    /// tampoco se ofrece. Un volumen sin bóveda se expulsa sin más.
    public var sePuedeExpulsar: Bool {
        guard esExtraible, !esArranque else { return false }
        guard existe else { return true }
        guard abierta else { return false }
        return visibilidad == .oculta || estaVacia
    }

    /// Por qué no se puede expulsar, para decírselo al usuario en vez de dejar
    /// un botón apagado sin explicación.
    public var motivoParaNoExpulsar: String? {
        guard esExtraible, !esArranque, existe, !sePuedeExpulsar else { return nil }
        guard abierta else {
            return "No se puede comprobar qué hay fuera de la bóveda: no se abre con esta contraseña."
        }
        return visibilidad == .parcial
            ? "Parte del contenido está fuera de la bóveda, en este disco. Ocúltalo antes de expulsar."
            : "El contenido está visible en este disco. Ocúltalo antes de expulsar."
    }
}

/// Por qué una bóveda que existe no se pudo abrir.
public enum MotivoCerrada: Sendable, Equatable {
    /// La cabecera está sana pero la contraseña de la sesión no abre su DEK.
    /// El contenido está intacto: no hay nada que reparar.
    case otraContrasena
    /// Otro proceso la tiene tomada (`flock`).
    case enUso
    /// Cabecera ilegible, no es una bóveda, o versión desconocida.
    case danada

    /// Traduce el error del motor. Ante la duda, NO se dice «dañada»: sólo los
    /// fallos que de verdad son de formato llevan a esa rama.
    init(_ error: Error) {
        switch error as? BovedaError {
        case .contrasenaIncorrecta: self = .otraContrasena
        case .bovedaEnUso:          self = .enUso
        default:                    self = .danada
        }
    }
}

/// Cómo fue un cambio de contraseña.
///
/// Se devuelven las dos listas porque el cambio **puede salir a medias** cuando hay
/// varias bóvedas: decir sólo «hecho» o sólo «falló» sería mentir en ese caso.
public struct CambioDeContrasena: Sendable {
    public var cambiadas: [String] = []
    public var fallidas: [FalloDeCambio] = []
    public var resumenes: [ResumenBoveda] = []

    public var salioTodoBien: Bool { fallidas.isEmpty && !cambiadas.isEmpty }
}

public struct FalloDeCambio: Sendable {
    public let volumen: String
    public let motivo: String
}

/// Dueño exclusivo de las bóvedas abiertas.
///
/// `Vault` no es seguro entre hilos, así que en vez de repartirlo se encierran
/// todos aquí: este actor es el único que los toca y la interfaz habla con él
/// mediante `await`. De paso, el cifrado ocurre fuera del hilo principal, que era
/// lo que congelaba la ventana con carpetas grandes.
///
/// Maneja **varias a la vez**: una por volumen, todas con la misma contraseña.
actor MotorBoveda {

    private var abiertas: [String: Vault] = [:]

    // MARK: - Sesión

    /// Recorre los volúmenes e intenta abrir la bóveda de cada uno con la misma
    /// contraseña. Devuelve todos los volúmenes, tengan bóveda o no.
    func abrirSesion(contrasena: String) -> [ResumenBoveda] {
        cerrarSesion()
        var resultado: [ResumenBoveda] = []

        for volumen in Ubicaciones.volumenes() {
            guard volumen.existe else {
                resultado.append(sinAbrir(volumen, existe: false))
                continue
            }
            do {
                let vault = try Vault.open(at: volumen.bovedaURL, password: contrasena)
                abiertas[volumen.bovedaURL.path] = vault
                resultado.append(resumen(de: vault, volumen: volumen))
            } catch {
                // Otra contraseña, dañada, o abierta por otro proceso: el motivo
                // se conserva para que la interfaz no los trate igual.
                resultado.append(sinAbrir(volumen, existe: true, motivo: MotivoCerrada(error)))
            }
        }
        return resultado
    }

    func cerrarSesion() {
        for vault in abiertas.values { try? vault.close() }
        abiertas.removeAll()
    }

    /// Cierra una sola bóveda y suelta su `flock`.
    ///
    /// Imprescindible antes de expulsar el disco: con el archivo abierto macOS
    /// se niega a desmontar el volumen.
    func cerrar(ruta: String) {
        if let vault = abiertas.removeValue(forKey: ruta) {
            try? vault.close()
        }
    }

    func crear(en volumen: VolumenConBoveda, contrasena: String) throws -> ResumenBoveda {
        let vault = try Vault.create(at: volumen.bovedaURL, password: contrasena)
        // Nace oculta: no estorba en la carpeta ni se borra por descuido.
        try? Vault.ocultar(volumen.bovedaURL, true)
        abiertas[volumen.bovedaURL.path] = vault
        return resumen(de: vault, volumen: volumen)
    }

    /// Empieza de cero cuando el archivo existe pero no se puede abrir (dañado, o
    /// de otra contraseña que ya no se recuerda).
    ///
    /// **El archivo viejo no se borra**: se aparta con otro nombre, también oculto.
    /// Aunque no se pueda abrir hoy, sus bytes son lo único que queda de lo que
    /// hubiera dentro, y esa decisión es del usuario, no de la app.
    /// Devuelve además dónde quedó apartado, para poder decírselo.
    func recrear(en volumen: VolumenConBoveda, contrasena: String) throws -> (ResumenBoveda, URL) {
        if let vieja = abiertas.removeValue(forKey: volumen.bovedaURL.path) {
            try? vieja.close()
        }
        let apartada = try apartar(volumen.bovedaURL)
        let resumen = try crear(en: volumen, contrasena: contrasena)
        return (resumen, apartada)
    }

    /// Renombra la bóveda a un nombre libre al lado del original.
    private func apartar(_ url: URL) throws -> URL {
        let formato = DateFormatter()
        formato.dateFormat = "yyyy-MM-dd-HHmmss"
        let base = url.deletingPathExtension().lastPathComponent
        let extension_ = url.pathExtension

        var destino = url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-dañada-\(formato.string(from: Date()))")
            .appendingPathExtension(extension_)
        var intento = 2
        while FileManager.default.fileExists(atPath: destino.path) {
            destino = destino.deletingPathExtension()
                .appendingPathExtension("\(intento)")
                .appendingPathExtension(extension_)
            intento += 1
        }

        try FileManager.default.moveItem(at: url, to: destino)
        // El flag viaja con el archivo al renombrarlo (probado), pero se reafirma
        // por si venía sin él: apartada o no, sigue sin tener que verse.
        try? Vault.ocultar(destino, true)
        return destino
    }

    // MARK: - Contraseña

    /// Cambia la contraseña **de todas las bóvedas abiertas**, que es lo que el
    /// usuario entiende por «la contraseña de la app»: siendo una sola para todas,
    /// cambiarla en una y no en las demás las dejaría marcadas «Otra contraseña».
    ///
    /// ⚠️ **No es atómico entre bóvedas y no puede serlo**: son archivos sueltos, a
    /// veces en discos distintos. Si una falla (disco lleno, de solo lectura,
    /// desconectado a media faena) las anteriores ya quedaron cambiadas. Por eso no
    /// se aborta al primer fallo: se sigue con las demás y se devuelve la lista de
    /// las que no pudieron, para poder decírselo al usuario y que reintente esa.
    /// Nada se pierde en ningún caso — cambiar la contraseña sólo vuelve a sellar
    /// la DEK, jamás toca el contenido.
    func cambiarMaestra(actual: String, nueva: String) throws -> CambioDeContrasena {
        guard !nueva.isEmpty else { throw BovedaError.contrasenaVacia }
        guard !abiertas.isEmpty else { throw BovedaError.bovedaCerrada }

        let nombres = nombresPorRuta()
        var resultado = CambioDeContrasena()

        for (ruta, vault) in abiertas {
            let nombre = nombres[ruta] ?? URL(fileURLWithPath: ruta).lastPathComponent
            do {
                try vault.changePassword(current: actual, new: nueva)
                resultado.cambiadas.append(nombre)
            } catch {
                let motivo = (error as? BovedaError)?.errorDescription ?? error.localizedDescription
                resultado.fallidas.append(FalloDeCambio(volumen: nombre, motivo: motivo))
            }
        }

        // Reabrir con la nueva deja la sesión coherente: las que se cambiaron abren,
        // y cualquiera que fallara sale marcada con su motivo en vez de mentir.
        resultado.resumenes = abrirSesion(contrasena: nueva)
        return resultado
    }

    /// Cambia la de **una sola** bóveda. Es la vía para unificar las que salen
    /// marcadas «Otra contraseña»: se abre con la suya y se le pone la de la sesión.
    ///
    /// `sesion` es la contraseña con la que se reabre todo al terminar; así la
    /// bóveda recién cambiada aparece ya abierta si ahora comparte contraseña.
    func cambiarUna(ruta: String, actual: String, nueva: String, sesion: String) throws -> CambioDeContrasena {
        guard !nueva.isEmpty else { throw BovedaError.contrasenaVacia }
        let nombre = nombresPorRuta()[ruta] ?? URL(fileURLWithPath: ruta).lastPathComponent

        if let vault = abiertas[ruta] {
            try vault.changePassword(current: actual, new: nueva)
        } else {
            // Cerrada porque tiene otra contraseña: se abre con la suya sólo para
            // esto y se vuelve a cerrar. `open` ya lanza si `actual` no es la buena.
            let vault = try Vault.open(at: URL(fileURLWithPath: ruta), password: actual)
            defer { try? vault.close() }
            try vault.changePassword(current: actual, new: nueva)
        }

        var resultado = CambioDeContrasena()
        resultado.cambiadas = [nombre]
        resultado.resumenes = abrirSesion(contrasena: sesion)
        return resultado
    }

    private func nombresPorRuta() -> [String: String] {
        Dictionary(uniqueKeysWithValues: Ubicaciones.volumenes().map { ($0.bovedaURL.path, $0.nombre) })
    }

    // MARK: - El interruptor Visible / Oculta

    func hacerVisible(_ ruta: String, progreso: @escaping @Sendable (Progreso) -> Void) throws -> ResumenBoveda {
        let vault = try exigir(ruta)
        try vault.makeVisible { nombre, hecho, total in
            progreso(Progreso(titulo: "Devolviendo a su sitio", detalle: nombre,
                              actual: hecho, total: total))
        }
        return try resumenActualizado(ruta)
    }

    func ocultar(_ ruta: String, progreso: @escaping @Sendable (Progreso) -> Void) throws -> ResumenBoveda {
        let vault = try exigir(ruta)
        try vault.makeHidden { nombre, hecho, total in
            progreso(Progreso(titulo: "Cifrando y escondiendo", detalle: nombre,
                              actual: hecho, total: total))
        }
        return try resumenActualizado(ruta)
    }

    // MARK: - Contenido

    func agregar(_ urls: [URL], a ruta: String,
                 progreso: @escaping @Sendable (Progreso) -> Void) throws -> ResumenBoveda {
        let vault = try exigir(ruta)
        for (i, url) in urls.enumerated() {
            var esCarpeta: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &esCarpeta) else { continue }
            if esCarpeta.boolValue {
                try vault.addFolder(at: url) { archivo, hecho, total in
                    progreso(Progreso(titulo: "Cifrando «\(url.lastPathComponent)»",
                                      detalle: archivo, actual: hecho, total: total))
                }
            } else {
                progreso(Progreso(titulo: "Cifrando", detalle: url.lastPathComponent,
                                  actual: i + 1, total: urls.count))
                try vault.addFile(at: url, removeOriginal: true)
            }
        }
        return try resumenActualizado(ruta)
    }

    func mostrarCarpeta(_ id: UUID, en ruta: String, nombre: String,
                        progreso: @escaping @Sendable (Progreso) -> Void) throws -> ResumenBoveda {
        let vault = try exigir(ruta)
        try vault.deployFolder(id: id) { archivo, hecho, total in
            progreso(Progreso(titulo: "Devolviendo «\(nombre)»", detalle: archivo,
                              actual: hecho, total: total))
        }
        return try resumenActualizado(ruta)
    }

    func esconderCarpeta(_ id: UUID, en ruta: String, nombre: String,
                         progreso: @escaping @Sendable (Progreso) -> Void) throws -> ResumenBoveda {
        let vault = try exigir(ruta)
        try vault.stowFolder(id: id) { archivo, hecho, total in
            progreso(Progreso(titulo: "Cifrando «\(nombre)»", detalle: archivo,
                              actual: hecho, total: total))
        }
        return try resumenActualizado(ruta)
    }

    /// Saca de la bóveda todo lo señalado, dejándolo en el disco: lo que estuviera
    /// escondido se devuelve primero a su sitio. No se pierde nada, sólo deja de
    /// gestionarse.
    ///
    /// Va en lote a propósito: la interfaz se bloquea entera mientras hay trabajo,
    /// así que llamarla una vez por elemento perdería todas menos la primera.
    func sacar(carpetas: [UUID], archivos: [UUID], en ruta: String,
               progreso: @escaping @Sendable (Progreso) -> Void) throws -> ResumenBoveda {
        let vault = try exigir(ruta)
        for id in carpetas {
            let nombre = vault.folders.first { $0.id == id }?.name ?? ""
            try vault.releaseFolder(id: id) { archivo, hecho, total in
                progreso(Progreso(titulo: "Sacando «\(nombre)»", detalle: archivo,
                                  actual: hecho, total: total))
            }
        }
        for (i, id) in archivos.enumerated() {
            let entrada = try vault.entry(id: id)
            progreso(Progreso(titulo: "Sacando", detalle: entrada.name,
                              actual: i + 1, total: archivos.count))
            if !(entrada.isDeployed ?? false) {
                try vault.deployEntry(id: id)
            }
            try vault.remove(id: id)
        }
        try compactarSiQuedoVacia(vault, progreso: progreso)
        return try resumenActualizado(ruta)
    }

    /// Borra de la bóveda lo señalado. Lo que esté desplegado en el disco se queda;
    /// lo que sólo viviera cifrado aquí dentro se pierde.
    func eliminar(carpetas: [UUID], archivos: [UUID], en ruta: String,
                  progreso: @escaping @Sendable (Progreso) -> Void) throws -> ResumenBoveda {
        let vault = try exigir(ruta)
        for id in carpetas { try vault.olvidarCarpeta(id: id) }
        for id in archivos { try vault.remove(id: id) }
        try compactarSiQuedoVacia(vault, progreso: progreso)
        return try resumenActualizado(ruta)
    }

    /// Quitar algo sólo lo borra del índice: sus bytes siguen ocupando sitio hasta
    /// que se compacta. Si ya no queda nada dentro, se compacta sola —así el
    /// archivo vuelve a pesar lo mínimo en vez de arrastrar de por vida lo que
    /// hubo antes, y lo siguiente que se guarde no se suma encima de esa basura.
    ///
    /// Sólo en el caso vacío: ahí reescribir el contenedor es instantáneo. Con
    /// contenido dentro habría que copiar gigas, y esa espera la decide el usuario
    /// con el botón «Compactar».
    private func compactarSiQuedoVacia(_ vault: Vault,
                                       progreso: @escaping @Sendable (Progreso) -> Void) throws {
        guard vault.entries.isEmpty, vault.folders.isEmpty else { return }
        progreso(Progreso(titulo: "Dejando la bóveda en limpio",
                          detalle: vault.url.lastPathComponent, actual: 1, total: 1))
        try vault.compact()
    }

    func mostrarArchivo(_ id: UUID, en ruta: String) throws -> ResumenBoveda {
        try exigir(ruta).deployEntry(id: id)
        return try resumenActualizado(ruta)
    }

    func esconderArchivo(_ id: UUID, en ruta: String) throws -> ResumenBoveda {
        try exigir(ruta).stowEntry(id: id)
        return try resumenActualizado(ruta)
    }

    func extraer(_ id: UUID, de ruta: String, a destino: URL) throws {
        try exigir(ruta).extract(id: id, to: destino, overwrite: true)
    }

    /// Varias copias de una vez, cada una con su nombre dentro de la carpeta dada.
    func extraer(_ ids: [UUID], de ruta: String, aCarpeta carpeta: URL,
                 progreso: @escaping @Sendable (Progreso) -> Void) throws {
        let vault = try exigir(ruta)
        for (i, id) in ids.enumerated() {
            let entrada = try vault.entry(id: id)
            progreso(Progreso(titulo: "Extrayendo copias", detalle: entrada.name,
                              actual: i + 1, total: ids.count))
            try vault.extract(id: id, to: carpeta.appendingPathComponent(entrada.name),
                              overwrite: true)
        }
    }

    func compactar(_ ruta: String) throws -> ResumenBoveda {
        try exigir(ruta).compact()
        return try resumenActualizado(ruta)
    }

    func alternarOcultacionDelArchivo(_ ruta: String) throws -> Bool {
        let url = URL(fileURLWithPath: ruta)
        let oculta = try Vault.estaOculta(url)
        try Vault.ocultar(url, !oculta)
        return !oculta
    }

    // MARK: - Apoyo

    private func exigir(_ ruta: String) throws -> Vault {
        guard let vault = abiertas[ruta] else { throw BovedaError.bovedaCerrada }
        return vault
    }

    private func resumenActualizado(_ ruta: String) throws -> ResumenBoveda {
        let vault = try exigir(ruta)
        let volumen = Ubicaciones.volumenes().first { $0.bovedaURL.path == ruta }
        return resumen(de: vault, volumen: volumen)
    }

    private func resumen(de vault: Vault, volumen: VolumenConBoveda?) -> ResumenBoveda {
        ResumenBoveda(ruta: vault.url.path,
                      volumen: volumen?.nombre ?? vault.url.deletingLastPathComponent().lastPathComponent,
                      esArranque: volumen?.esArranque ?? false,
                      esExtraible: volumen?.esExtraible ?? false,
                      espacioLibre: volumen?.espacioLibre ?? 0,
                      existe: true,
                      abierta: true,
                      visibilidad: vault.visibilidad,
                      carpetas: vault.folders,
                      sueltos: vault.looseEntries,
                      tamanoTotal: vault.entries.reduce(0) { $0 + $1.size },
                      espacioMuerto: (try? vault.stats())?.deadBytes ?? 0)
    }

    private func sinAbrir(_ volumen: VolumenConBoveda,
                          existe: Bool,
                          motivo: MotivoCerrada? = nil) -> ResumenBoveda {
        ResumenBoveda(ruta: volumen.bovedaURL.path,
                      volumen: volumen.nombre,
                      esArranque: volumen.esArranque,
                      esExtraible: volumen.esExtraible,
                      espacioLibre: volumen.espacioLibre,
                      existe: existe,
                      abierta: false,
                      motivo: motivo,
                      visibilidad: .oculta,
                      carpetas: [], sueltos: [], tamanoTotal: 0, espacioMuerto: 0)
    }
}
