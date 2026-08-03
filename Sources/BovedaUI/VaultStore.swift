import AppKit
import BovedaKit
import Observation
import SwiftUI

/// Estado de la aplicación.
///
/// El flujo es: contraseña → lista de bóvedas → (opcional) detalle de una.
/// La contraseña es una sola para todas: al escribirla se intenta abrir con ella
/// la bóveda de cada volumen conectado.
@Observable
@MainActor
public final class VaultStore {

    public enum Estado: Equatable {
        /// Primer arranque en este Mac: no hay ni una bóveda. Se pide contraseña
        /// nueva y se crea la del disco del sistema.
        case primeraVez
        /// Nada más abrir: la contraseña, antes de mostrar qué hay.
        case contrasena
        /// Las bóvedas de cada volumen, con su interruptor.
        case lista
        /// Dentro de una, viendo su contenido.
        case detalle(String)
    }

    public private(set) var estado: Estado = .contrasena
    public private(set) var bovedas: [ResumenBoveda] = []
    public private(set) var ocupada = false
    /// Si el trabajo en curso merece tapar la ventana.
    ///
    /// Comprobar la contraseña también «ocupa», pero dura un suspiro: sacar ahí la
    /// capa sólo producía un parpadeo de «Trabajando…» que ensuciaba el cambio de
    /// pantalla, y aparecía incluso cuando la contraseña era incorrecta.
    public private(set) var muestraCapaDeProgreso = false
    /// Trabajo en curso, para la barra de progreso. `nil` si no hay nada corriendo.
    public private(set) var progreso: Progreso?
    public var mensajeDeError: String?
    /// Algo que salió bien pero que conviene contar. No es un fallo.
    public var aviso: String?
    /// Fallo al entrar. Va en línea bajo el campo, no en un alert: el alert
    /// obligaba a estar ya dentro para poder mostrarlo.
    public var errorDeContrasena: String?
    /// La contraseña era correcta y el candado se está abriendo. Dura lo que la
    /// animación; después se pasa a la lista.
    public private(set) var desbloqueada = false
    /// Se acaba de cerrar sesión: la pantalla de entrada aparece con el candado
    /// abierto y lo cierra. Es la apertura al revés.
    public private(set) var bloqueando = false

    /// La contraseña de la sesión. Sólo en memoria y sólo mientras está abierta.
    private var contrasenaDeSesion: String?
    private let motor = MotorBoveda()
    /// El freno a la fuerza bruta. Recuerda los fallos entre arranques, así que
    /// cerrar y volver a abrir la app no borra la espera.
    private let intentos: ControlDeIntentos
    /// La que hace bajar la cuenta atrás segundo a segundo.
    private var tareaDeEspera: Task<Void, Never>?
    /// En las previews no hay nada en disco: las acciones se quedan en nada.
    private let esEjemplo: Bool

    /// La sesión viva, para que el delegado de la app pueda consultarla al
    /// cerrarse.
    ///
    /// ⚠️ **Referencia fuerte a propósito.** Siendo débil se perdía al cerrar la
    /// ventana con la ⓧ: eso destruye la vista y con ella su `@State`, así que un
    /// Cmd+Q posterior no encontraba sesión y cerraba sin avisar. Cerrar la
    /// ventana no es salir de la app, y lo que haya desplegado en disco sigue
    /// desplegado: la sesión tiene que sobrevivir a la ventana.
    public private(set) static var enUso: VaultStore?

    /// La sesión de la app, creándola sólo la primera vez.
    ///
    /// La vista tiene que pedirla por aquí y **no** construir un `VaultStore`
    /// suyo: al cerrar la ventana con la ⓧ y cancelar el cierre, SwiftUI levanta
    /// una `VistaRaiz` nueva, y con un `@State = VaultStore()` esa vista nacía con
    /// una sesión virgen — volvías a la pantalla de contraseña aunque nunca
    /// hubieras salido. Cerrar la ventana no es cerrar la sesión.
    public static func compartida() -> VaultStore {
        if let existente = enUso { return existente }
        let nueva = VaultStore()
        enUso = nueva
        return nueva
    }

    /// Marca esta instancia como la sesión de verdad.
    ///
    /// ⚠️ Se llama **desde la vista, nunca desde `init`**. Con
    /// `@State private var store = VaultStore()` el inicializador se evalúa cada
    /// vez que se construye la estructura de la vista; SwiftUI conserva la
    /// primera instancia y tira las demás, pero sus `init` ya corrieron. Hacer el
    /// registro ahí dejaba `enUso` apuntando a una copia descartada, con la lista
    /// de bóvedas vacía, y el aviso al cerrar no saltaba nunca.
    public func registrarSesion() {
        VaultStore.enUso = self
    }

    public init() {
        esEjemplo = false
        intentos = ControlDeIntentos(almacen: AjustesDeIntentos())
        // Si no hay ninguna bóveda todavía, lo primero es configurarla.
        let hayAlguna = Ubicaciones.volumenes().contains { $0.existe }
        estado = hayAlguna ? .contrasena : .primeraVez
        observarVolumenes()
        // Si quedaba espera pendiente de la sesión anterior, que se vea desde el
        // primer momento en vez de al fallar otra vez.
        refrescarEspera()
        if esperaDeIntentos > 0 { errorDeContrasena = mensajeDeEspera() }
    }

    private init(bovedasDeEjemplo: [ResumenBoveda], estadoInicial: Estado) {
        esEjemplo = true
        // Las previews no tocan los ajustes reales.
        intentos = ControlDeIntentos(almacen: IntentosEnMemoria())
        bovedas = bovedasDeEjemplo
        estado = estadoInicial
    }

    // MARK: - Para las previews

    public static func ejemploLista() -> VaultStore {
        VaultStore(bovedasDeEjemplo: ResumenBoveda.ejemplos, estadoInicial: .lista)
    }

    public static func ejemploContrasena() -> VaultStore {
        VaultStore(bovedasDeEjemplo: [], estadoInicial: .contrasena)
    }

    public static func ejemploPrimeraVez() -> VaultStore {
        VaultStore(bovedasDeEjemplo: [], estadoInicial: .primeraVez)
    }

    public static func ejemploDetalle() -> VaultStore {
        let ejemplos = ResumenBoveda.ejemplos
        return VaultStore(bovedasDeEjemplo: ejemplos, estadoInicial: .detalle(ejemplos[0].ruta))
    }

    public static func ejemploTrabajando() -> VaultStore {
        let store = VaultStore(bovedasDeEjemplo: ResumenBoveda.ejemplos, estadoInicial: .lista)
        store.ocupada = true
        store.muestraCapaDeProgreso = true
        store.progreso = Progreso(titulo: "Devolviendo a su sitio",
                                  detalle: "Fotos 2026", actual: 1, total: 3)
        return store
    }

    // MARK: - Datos derivados

    public var bovedaActual: ResumenBoveda? {
        guard case .detalle(let ruta) = estado else { return nil }
        return bovedas.first { $0.ruta == ruta }
    }

    public var bovedasExistentes: [ResumenBoveda] {
        bovedas.filter(\.existe)
    }

    /// Bóvedas con contenido descifrado ahora mismo sobre el disco.
    ///
    /// Es lo que hay que avisar antes de cerrar la app: mientras algo está
    /// Visible, sus archivos existen en claro fuera de la bóveda, y al salir se
    /// quedan así. Una vacía nunca cuenta, aunque su `visibilidad` sea `.oculta`
    /// por definición.
    public var bovedasDestapadas: [ResumenBoveda] {
        bovedas.filter {
            $0.abierta && !$0.estaVacia
                && ($0.visibilidad == .visible || $0.visibilidad == .parcial)
        }
    }

    /// Volúmenes donde todavía no hay bóveda.
    public var volumenesSinBoveda: [ResumenBoveda] {
        bovedas.filter { !$0.existe }
    }

    // MARK: - Sesión

    /// Abre con esa contraseña todas las bóvedas que la acepten.
    ///
    /// **Si no abre ninguna, no se entra.** La contraseña es una sola para todas,
    /// así que fallar en todas significa que la contraseña no es. Dejar pasar
    /// revelaba qué volúmenes tienen bóveda y, peor, dejaba la contraseña errónea
    /// como la de la sesión: «Recrear…» habría apartado una bóveda sana.
    /// Que abra **una sola** basta para entrar; las demás se marcan con su motivo.
    public func entrar(contrasena: String) {
        guard !contrasena.isEmpty else { return }
        // Con la espera corriendo no se prueba nada: ni se deriva la clave, ni se
        // toca el disco. Si no, cada intento seguiría dando información por el
        // tiempo que tarda.
        refrescarEspera()
        guard esperaDeIntentos <= 0 else {
            errorDeContrasena = mensajeDeEspera()
            return
        }
        errorDeContrasena = nil
        // Sin capa: el cambio a la lista tiene que verse limpio, y si la contraseña
        // falla no se ha de asomar nada.
        trabajar(conCapa: false) { _ in
            await self.motor.abrirSesion(contrasena: contrasena)
        } alTerminar: {
            let existentes = self.bovedas.filter(\.existe)
            // Sin bóvedas existentes no hay nada que proteger ni que filtrar
            // (p. ej. el disco con la única bóveda está desconectado).
            guard existentes.isEmpty || existentes.contains(where: \.abierta) else {
                self.intentos.registrarFallo()
                self.refrescarEspera()
                self.rechazarContrasena()
                return
            }
            self.intentos.registrarAcierto()
            self.refrescarEspera()
            self.contrasenaDeSesion = contrasena
            self.abrirElCandadoYEntrar()
        }
    }

    // MARK: - Intentos fallidos

    /// Cuánto falta para poder volver a intentarlo. `0` = se puede ya.
    ///
    /// Se refresca sola cada segundo mientras corre, para que la cuenta atrás de la
    /// pantalla de entrada baje a la vista sin que la vista tenga que saber nada.
    public private(set) var esperaDeIntentos: TimeInterval = 0
    /// Fallos seguidos, para poder avisar antes de que empiece el castigo.
    public var fallosSeguidos: Int { intentos.fallos }

    private func refrescarEspera() {
        esperaDeIntentos = intentos.esperaRestante()
        tareaDeEspera?.cancel()
        tareaDeEspera = nil
        guard esperaDeIntentos > 0 else { return }

        tareaDeEspera = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.esperaDeIntentos = self.intentos.esperaRestante()
                if self.esperaDeIntentos <= 0 {
                    // Al cumplirse la espera se limpia el aviso: dejar ahí un
                    // «espera 30 s» cuando ya se puede entrar confunde.
                    if self.errorDeContrasena != nil { self.errorDeContrasena = nil }
                    return
                }
            }
        }
    }

    private func mensajeDeEspera() -> String {
        "Demasiados intentos fallidos. Vuelve a intentarlo en \(ControlDeIntentos.enPalabras(esperaDeIntentos))."
    }

    // MARK: - Cambiar la contraseña

    /// Resultado del último cambio, para poder contarlo al terminar.
    private var ultimoCambio: CambioDeContrasena?

    /// Cambia la contraseña maestra en **todas las bóvedas abiertas**.
    ///
    /// Se pide también la actual aunque la sesión ya la tenga: si no, cualquiera
    /// que encuentre el Mac desatendido con la app abierta podría cambiarla sin
    /// saber la vieja y dejar al dueño fuera.
    public func cambiarContrasenaMaestra(actual: String, nueva: String) {
        guard let sesion = contrasenaDeSesion else { return }
        guard actual == sesion else {
            mensajeDeError = "La contraseña actual no es correcta."
            return
        }
        guard !nueva.isEmpty else {
            mensajeDeError = "La contraseña nueva no puede estar vacía."
            return
        }
        guard nueva != actual else {
            mensajeDeError = "La contraseña nueva es igual a la actual."
            return
        }

        trabajar { _ in
            let cambio = try await self.motor.cambiarMaestra(actual: actual, nueva: nueva)
            await MainActor.run { self.ultimoCambio = cambio }
            return cambio.resumenes
        } alTerminar: {
            // La sesión pasa a la nueva aunque alguna bóveda haya fallado: las que
            // sí cambiaron sólo abren con ésta, y la que falló ya se marca sola.
            self.contrasenaDeSesion = nueva
            self.contarElCambio()
        }
    }

    /// Cambia la contraseña de **una sola** bóveda. Es la vía para unificar una que
    /// aparece marcada «Otra contraseña»: se le pone la de la sesión y a partir de
    /// ahí abre con las demás.
    public func cambiarContrasenaDe(_ boveda: ResumenBoveda, actual: String, nueva: String) {
        guard let sesion = contrasenaDeSesion else { return }
        guard !nueva.isEmpty else {
            mensajeDeError = "La contraseña nueva no puede estar vacía."
            return
        }
        let ruta = boveda.ruta

        trabajar { _ in
            let cambio = try await self.motor.cambiarUna(ruta: ruta, actual: actual,
                                                         nueva: nueva, sesion: sesion)
            await MainActor.run { self.ultimoCambio = cambio }
            return cambio.resumenes
        } alTerminar: {
            self.contarElCambio()
        }
    }

    /// La contraseña de la sesión, para ofrecerla como destino al unificar una
    /// bóveda suelta. No se enseña nunca: sólo sirve para rellenarla desde el botón
    /// «Usar la de la sesión».
    public var haySesionAbierta: Bool { contrasenaDeSesion != nil }

    public func contrasenaDeLaSesionParaUnificar() -> String? { contrasenaDeSesion }

    private func contarElCambio() {
        guard let cambio = ultimoCambio else { return }
        ultimoCambio = nil

        if cambio.fallidas.isEmpty {
            aviso = cambio.cambiadas.count == 1
                ? "Contraseña cambiada en «\(cambio.cambiadas[0])»."
                : "Contraseña cambiada en \(cambio.cambiadas.count) bóvedas."
        } else {
            // Salió a medias: hay que decir exactamente en cuáles sí y en cuáles no,
            // o el usuario se queda sin saber con qué contraseña abre cada una.
            let fallos = cambio.fallidas
                .map { "«\($0.volumen)» (\($0.motivo))" }
                .joined(separator: ", ")
            mensajeDeError = cambio.cambiadas.isEmpty
                ? "No se pudo cambiar la contraseña: \(fallos)"
                : "Cambiada en \(cambio.cambiadas.count), pero falló en \(fallos). Esas siguen con la contraseña anterior."
        }
    }

    /// Deja que el candado termine de abrirse antes de cambiar de pantalla.
    ///
    /// La espera es deliberada: sin ella la lista aparecería encima de la
    /// animación y no se vería. Tiene que cubrir las dos fases de
    /// `VistaContrasena` — subir (0,24 s) y girar (0,20 de retardo + 0,40).
    private func abrirElCandadoYEntrar() {
        desbloqueada = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(640))
            self.estado = .lista
            self.desbloqueada = false
        }
    }

    /// Deshace todo rastro del intento fallido y se queda en la pantalla de entrada.
    private func rechazarContrasena() {
        bovedas = []
        contrasenaDeSesion = nil
        estado = .contrasena
        // Si el fallo ya activó la espera, eso es lo que hay que contar: un
        // «Contraseña incorrecta» a secas dejaría al usuario dándole al botón sin
        // entender por qué no pasa nada.
        errorDeContrasena = esperaDeIntentos > 0 ? mensajeDeEspera() : "Contraseña incorrecta."
        Task { await motor.cerrarSesion() }
    }

    /// Primer arranque: fija la contraseña maestra y crea la bóveda del disco
    /// del sistema, para que haya dónde guardar desde el minuto uno.
    public func configurarPorPrimeraVez(contrasena: String) {
        guard !contrasena.isEmpty else { return }
        guard let arranque = Ubicaciones.volumenes().first(where: \.esArranque) else {
            mensajeDeError = "No se encontró el disco del sistema."
            return
        }
        trabajar(conCapa: false) { _ in
            _ = try await self.motor.crear(en: arranque, contrasena: contrasena)
            return await self.motor.abrirSesion(contrasena: contrasena)
        } alTerminar: {
            self.contrasenaDeSesion = contrasena
            self.abrirElCandadoYEntrar()
        }
    }

    public func salir() {
        contrasenaDeSesion = nil
        desbloqueada = false
        bovedas = []
        estado = Ubicaciones.volumenes().contains { $0.existe } ? .contrasena : .primeraVez
        Task { await motor.cerrarSesion() }

        // En `primeraVez` el candado se queda abierto a propósito, así que ahí no
        // hay cierre que animar.
        guard estado == .contrasena else { return }
        bloqueando = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            self.bloqueando = false
        }
    }

    /// Expulsa el disco de una bóveda, cerrándola antes.
    ///
    /// La comprobación se repite aquí aunque la interfaz ya desactive el botón:
    /// es la regla que impide llevarse el contenido en claro fuera del Mac, y no
    /// puede depender de que ninguna vista se olvide de mirarla.
    public func expulsar(_ boveda: ResumenBoveda) {
        guard boveda.sePuedeExpulsar else {
            mensajeDeError = boveda.motivoParaNoExpulsar
                ?? "Este disco no se puede expulsar ahora."
            return
        }
        let ruta = boveda.ruta
        let volumen = boveda.volumenURL
        let nombre = boveda.volumen

        trabajar(conCapa: false) { _ in
            // Sin cerrar la bóveda el `flock` sigue puesto y macOS se niega a
            // desmontar: el error sería «disco en uso» y parecería un fallo ajeno.
            await self.motor.cerrar(ruta: ruta)
            try NSWorkspace.shared.unmountAndEjectDevice(at: volumen)
            return nil
        } alTerminar: {
            self.aviso = "«\(nombre)» ya se puede desconectar."
            // La lista se rehace sola al desmontarse el volumen (`observarVolumenes`),
            // así que aquí no hace falta tocarla.
        }
    }

    public func abrirDetalle(_ boveda: ResumenBoveda) {
        estado = .detalle(boveda.ruta)
    }

    public func volverALaLista() {
        estado = .lista
    }

    /// Crea la bóveda que falta en ese volumen, con la contraseña de la sesión.
    public func crear(en boveda: ResumenBoveda) {
        guard let contrasena = contrasenaDeSesion else { return }
        let volumen = volumenDe(boveda)
        trabajarSobreUna(boveda.ruta) { _ in
            try await self.motor.crear(en: volumen, contrasena: contrasena)
        }
    }

    /// Vuelve a empezar en un volumen cuya bóveda existe pero no se puede abrir.
    /// La vieja no se borra: se aparta con otro nombre y se dice dónde quedó.
    public func recrear(en boveda: ResumenBoveda) {
        guard let contrasena = contrasenaDeSesion else { return }
        let volumen = volumenDe(boveda)
        let actuales = bovedas
        trabajar { _ in
            let (resumen, apartada) = try await self.motor.recrear(en: volumen, contrasena: contrasena)
            await self.avisarDeLaApartada(apartada, volumen: boveda.volumen)
            var copia = actuales
            if let pos = copia.firstIndex(where: { $0.ruta == boveda.ruta }) {
                copia[pos] = resumen
            } else {
                copia.append(resumen)
            }
            return copia
        }
    }

    private func avisarDeLaApartada(_ apartada: URL, volumen: String) {
        let ruta = apartada.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        aviso = """
            Se creó una bóveda nueva y vacía en «\(volumen)».

            La anterior no se borró: quedó apartada en \(ruta), oculta. \
            Si algún día recuerdas su contraseña, todavía se puede abrir.
            """
    }

    private func volumenDe(_ boveda: ResumenBoveda) -> VolumenConBoveda {
        VolumenConBoveda(nombre: boveda.volumen,
                         volumenURL: boveda.url.deletingLastPathComponent(),
                         bovedaURL: boveda.url,
                         existe: boveda.existe,
                         esArranque: boveda.esArranque,
                         esExtraible: boveda.esExtraible,
                         espacioLibre: boveda.espacioLibre)
    }

    private func observarVolumenes() {
        let centro = NSWorkspace.shared.notificationCenter
        for aviso in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            centro.addObserver(forName: aviso, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recargarSesion() }
            }
        }
    }

    /// Conectar o expulsar un disco cambia la lista: se rehace la sesión.
    private func recargarSesion() {
        guard let contrasena = contrasenaDeSesion, !ocupada else { return }
        trabajar { _ in
            await self.motor.abrirSesion(contrasena: contrasena)
        }
    }

    // MARK: - El interruptor Visible / Oculta

    public func hacerVisible(_ boveda: ResumenBoveda) {
        trabajarSobreUna(boveda.ruta) { reportar in
            try await self.motor.hacerVisible(boveda.ruta, progreso: reportar)
        }
    }

    public func ocultar(_ boveda: ResumenBoveda) {
        trabajarSobreUna(boveda.ruta) { reportar in
            try await self.motor.ocultar(boveda.ruta, progreso: reportar)
        }
    }

    public func alternar(_ boveda: ResumenBoveda) {
        switch boveda.visibilidad {
        case .visible:            ocultar(boveda)
        case .oculta, .parcial:   hacerVisible(boveda)
        }
    }

    // MARK: - Contenido de una bóveda

    public func agregar(archivos urls: [URL], a boveda: ResumenBoveda) {
        guard !urls.isEmpty else { return }
        trabajarSobreUna(boveda.ruta) { reportar in
            try await self.motor.agregar(urls, a: boveda.ruta, progreso: reportar)
        }
    }

    public func elegirCarpetaParaGuardar(en boveda: ResumenBoveda) {
        let panel = NSOpenPanel()
        panel.title = "Guardar una carpeta"
        panel.prompt = "Guardar"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        agregar(archivos: [url], a: boveda)
    }

    public func elegirArchivosParaGuardar(en boveda: ResumenBoveda) {
        let panel = NSOpenPanel()
        panel.title = "Guardar archivos"
        panel.prompt = "Guardar"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        agregar(archivos: panel.urls, a: boveda)
    }

    public func mostrar(_ carpeta: ManagedFolder, en boveda: ResumenBoveda) {
        trabajarSobreUna(boveda.ruta) { reportar in
            try await self.motor.mostrarCarpeta(carpeta.id, en: boveda.ruta,
                                                nombre: carpeta.name, progreso: reportar)
        }
    }

    public func esconder(_ carpeta: ManagedFolder, en boveda: ResumenBoveda) {
        trabajarSobreUna(boveda.ruta) { reportar in
            try await self.motor.esconderCarpeta(carpeta.id, en: boveda.ruta,
                                                 nombre: carpeta.name, progreso: reportar)
        }
    }

    /// Devuelve al disco lo señalado y deja de gestionarlo. No borra nada.
    public func sacar(carpetas: [ManagedFolder], archivos: [VaultEntry],
                      de boveda: ResumenBoveda) {
        guard !carpetas.isEmpty || !archivos.isEmpty else { return }
        let idsCarpetas = carpetas.map(\.id)
        let idsArchivos = archivos.map(\.id)
        trabajarSobreUna(boveda.ruta) { reportar in
            try await self.motor.sacar(carpetas: idsCarpetas, archivos: idsArchivos,
                                       en: boveda.ruta, progreso: reportar)
        }
    }

    /// Borra de la bóveda lo señalado. Destructivo con lo que esté escondido.
    public func eliminar(carpetas: [ManagedFolder], archivos: [VaultEntry],
                         de boveda: ResumenBoveda) {
        guard !carpetas.isEmpty || !archivos.isEmpty else { return }
        let idsCarpetas = carpetas.map(\.id)
        let idsArchivos = archivos.map(\.id)
        trabajarSobreUna(boveda.ruta) { reportar in
            try await self.motor.eliminar(carpetas: idsCarpetas, archivos: idsArchivos,
                                          en: boveda.ruta, progreso: reportar)
        }
    }

    public func alternar(_ entrada: VaultEntry, en boveda: ResumenBoveda) {
        let visible = entrada.isDeployed ?? false
        trabajarSobreUna(boveda.ruta) { _ in
            visible
                ? try await self.motor.esconderArchivo(entrada.id, en: boveda.ruta)
                : try await self.motor.mostrarArchivo(entrada.id, en: boveda.ruta)
        }
    }

    /// Una copia descifrada fuera de la bóveda, sin tocar lo que hay dentro.
    /// Con varios archivos se pide una carpeta y se dejan todos ahí.
    public func extraer(_ entradas: [VaultEntry], de boveda: ResumenBoveda) {
        guard !entradas.isEmpty else { return }

        if entradas.count == 1, let entrada = entradas.first {
            let panel = NSSavePanel()
            panel.title = "Extraer «\(entrada.name)»"
            panel.prompt = "Extraer"
            panel.nameFieldStringValue = entrada.name
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let destino = panel.url else { return }
            trabajar { _ in
                try await self.motor.extraer(entrada.id, de: boveda.ruta, a: destino)
                return nil   // extraer no cambia el estado de la bóveda
            }
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Extraer \(entradas.count) archivos"
        panel.prompt = "Extraer aquí"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let carpeta = panel.url else { return }

        let ids = entradas.map(\.id)
        trabajar { reportar in
            try await self.motor.extraer(ids, de: boveda.ruta, aCarpeta: carpeta,
                                         progreso: reportar)
            return nil
        }
    }

    public func compactar(_ boveda: ResumenBoveda) {
        trabajarSobreUna(boveda.ruta) { _ in
            try await self.motor.compactar(boveda.ruta)
        }
    }

    // MARK: - Ejecución

    /// Trabajo que devuelve la lista completa de bóvedas (o `nil` si no la cambia).
    private func trabajar(conCapa: Bool = true,
                          _ cuerpo: @escaping @Sendable (@escaping @Sendable (Progreso) -> Void) async throws -> [ResumenBoveda]?,
                          alTerminar: (() -> Void)? = nil) {
        guard !esEjemplo, !ocupada else { return }
        ocupada = true
        muestraCapaDeProgreso = conCapa
        progreso = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let nuevas = try await cuerpo { reporte in
                    Task { @MainActor [weak self] in self?.progreso = reporte }
                }
                if let nuevas { self.bovedas = nuevas }
                alTerminar?()
            } catch let error as BovedaError {
                self.mensajeDeError = error.errorDescription
            } catch {
                self.mensajeDeError = error.localizedDescription
            }
            self.ocupada = false
            self.muestraCapaDeProgreso = false
            self.progreso = nil
        }
    }

    /// Trabajo sobre una sola bóveda: se reemplaza su fila en la lista.
    private func trabajarSobreUna(_ ruta: String,
                                  _ cuerpo: @escaping @Sendable (@escaping @Sendable (Progreso) -> Void) async throws -> ResumenBoveda) {
        let actuales = bovedas
        trabajar { reportar in
            let actualizada = try await cuerpo(reportar)
            var copia = actuales
            if let pos = copia.firstIndex(where: { $0.ruta == ruta }) {
                copia[pos] = actualizada
            } else {
                copia.append(actualizada)
            }
            return copia
        }
    }
}
