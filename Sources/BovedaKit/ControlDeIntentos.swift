import Foundation

/// Freno a la fuerza bruta desde la propia app: tras unos cuantos fallos seguidos
/// hay que esperar, y la espera crece con cada nuevo error.
///
/// ⚠️ **Alcance honesto de esto.** Es una barrera contra quien se sienta delante
/// del Mac a probar contraseñas, no contra un ataque de verdad: quien se lleve el
/// archivo `.peekb` lo ataca en su máquina sin pasar por aquí. La resistencia real
/// sigue siendo el PBKDF2 de la cabecera y, sobre todo, lo larga que sea la
/// contraseña. Esto sube el coste del ataque cómodo, no del serio.
///
/// Vive en `BovedaKit` y no en la interfaz **a propósito**: es lógica pura, y aquí
/// las pruebas la alcanzan (`bovedatests` sólo depende de este módulo).
public struct ControlDeIntentos: Sendable {

    /// Fallos que no cuestan nada. Teclear mal la contraseña un par de veces es
    /// normal; castigarlo desde el primer error sólo molesta al dueño.
    public static let intentosLibres = 3

    /// La escalera de esperas, en segundos. El último escalón es de 24 h, que es
    /// el tope: la app nunca deja a nadie fuera para siempre.
    public static let escalera: [TimeInterval] = [
        30,          // 30 s
        60,          // 1 min
        5 * 60,      // 5 min
        15 * 60,     // 15 min
        60 * 60,     // 1 h
        6 * 60 * 60, // 6 h
        24 * 60 * 60 // 24 h — y de aquí no sube
    ]

    /// Dónde se recuerda todo entre arranques.
    private let almacen: AlmacenDeIntentos

    public init(almacen: AlmacenDeIntentos) {
        self.almacen = almacen
    }

    /// Fallos seguidos acumulados.
    public var fallos: Int { almacen.fallos }

    /// Cuánto falta para poder volver a intentarlo. `0` si se puede ya.
    ///
    /// Si el reloj del sistema aparece **antes** del último fallo, se considera que
    /// alguien lo movió hacia atrás para saltarse la espera y se devuelve la espera
    /// entera. Adelantar el reloj sí saltaría el bloqueo, y no hay forma de evitarlo
    /// sin un reloj monotónico que sobreviva al reinicio; queda dicho.
    public func esperaRestante(ahora: Date = Date()) -> TimeInterval {
        guard let hasta = almacen.esperaHasta else { return 0 }
        if let ultimo = almacen.ultimoFallo, ahora < ultimo {
            return Self.esperaPara(fallos: almacen.fallos)
        }
        let restante = hasta.timeIntervalSince(ahora)
        return restante > 0 ? restante : 0
    }

    public func estaBloqueado(ahora: Date = Date()) -> Bool {
        esperaRestante(ahora: ahora) > 0
    }

    /// Apunta un intento fallido y devuelve cuánto hay que esperar ahora.
    @discardableResult
    public func registrarFallo(ahora: Date = Date()) -> TimeInterval {
        almacen.fallos += 1
        almacen.ultimoFallo = ahora
        let espera = Self.esperaPara(fallos: almacen.fallos)
        almacen.esperaHasta = espera > 0 ? ahora.addingTimeInterval(espera) : nil
        return espera
    }

    /// Contraseña correcta: se borra el historial de fallos.
    public func registrarAcierto() {
        almacen.fallos = 0
        almacen.ultimoFallo = nil
        almacen.esperaHasta = nil
    }

    /// Qué espera toca con esa cantidad de fallos seguidos.
    public static func esperaPara(fallos: Int) -> TimeInterval {
        let castigados = fallos - intentosLibres
        guard castigados > 0 else { return 0 }
        return escalera[min(castigados - 1, escalera.count - 1)]
    }

    /// La espera en palabras, para decirla en pantalla («4 min 37 s»).
    public static func enPalabras(_ segundos: TimeInterval) -> String {
        let total = Int(segundos.rounded(.up))
        let horas = total / 3600
        let minutos = (total % 3600) / 60
        let resto = total % 60
        if horas > 0 { return minutos > 0 ? "\(horas) h \(minutos) min" : "\(horas) h" }
        if minutos > 0 { return resto > 0 ? "\(minutos) min \(resto) s" : "\(minutos) min" }
        return "\(resto) s"
    }
}

/// Dónde se guardan los fallos. Es un protocolo para que las pruebas puedan usar
/// memoria pura y no ensucien los ajustes reales de la app.
public protocol AlmacenDeIntentos: AnyObject, Sendable {
    var fallos: Int { get set }
    var ultimoFallo: Date? { get set }
    var esperaHasta: Date? { get set }
}

/// El almacén de verdad: los ajustes de la app.
///
/// Se eligió `UserDefaults` sobre un archivo propio para no crear una carpeta con
/// el nombre de la app en `Application Support` — un rastro más de que aquí hay
/// algo que esconder. Aun así, quien sepa dónde mirar puede borrar el contador y
/// reiniciar la cuenta: por eso esto disuade, no protege.
public final class AjustesDeIntentos: AlmacenDeIntentos, @unchecked Sendable {
    private let defaults: UserDefaults
    private let clave: String

    public init(defaults: UserDefaults = .standard, clave: String = "intentos") {
        self.defaults = defaults
        self.clave = clave
    }

    public var fallos: Int {
        get { defaults.integer(forKey: "\(clave).fallos") }
        set { defaults.set(newValue, forKey: "\(clave).fallos") }
    }

    public var ultimoFallo: Date? {
        get { defaults.object(forKey: "\(clave).ultimo") as? Date }
        set { defaults.set(newValue, forKey: "\(clave).ultimo") }
    }

    public var esperaHasta: Date? {
        get { defaults.object(forKey: "\(clave).hasta") as? Date }
        set { defaults.set(newValue, forKey: "\(clave).hasta") }
    }
}

/// Almacén en memoria, para pruebas y para las previews.
public final class IntentosEnMemoria: AlmacenDeIntentos, @unchecked Sendable {
    public var fallos = 0
    public var ultimoFallo: Date?
    public var esperaHasta: Date?
    public init() {}
}
