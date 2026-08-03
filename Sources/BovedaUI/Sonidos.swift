import AppKit

/// Los dos clacs del candado.
///
/// Son **grabaciones reales**, no síntesis: se probó a sintetizarlos y el
/// resultado sonaba a metal golpeado, porque la fricción y los varios cuerpos
/// resonando de un cerrojo real no salen de ruido filtrado más resonancias.
///
/// Origen: Wikimedia Commons, autor SpaceJoe, **licencia CC0** (dominio público,
/// sin atribución obligatoria y sin ataduras si la app se reparte).
/// `iconos/limpiar_sonidos.py` es lo que les recortó el aire de los extremos y
/// les igualó el nivel; los originales sin tocar están en Commons.
enum Sonidos {

    static let abrir = cargar("abrir")
    static let cerrar = cargar("cerrar")

    /// Al correr por `swift run` no hay bundle y no habrá sonido: es correcto,
    /// no un fallo. Sólo la app montada los lleva dentro.
    private static func cargar(_ nombre: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: nombre, withExtension: "wav") else {
            return nil
        }
        return NSSound(contentsOf: url, byReference: true)
    }

    /// Rebobina antes de sonar: si no, una segunda pulsación rápida no suena
    /// porque el `NSSound` sigue reproduciéndose.
    static func reproducir(_ sonido: NSSound?) {
        guard let sonido else { return }
        if sonido.isPlaying { sonido.stop() }
        sonido.play()
    }
}
