import BovedaKit
import Foundation

/// Arnés mínimo de pruebas: registra cada caso, atrapa lo que falle y devuelve
/// un código de salida distinto de cero si algo no cuadra.
struct FalloDePrueba: Error, CustomStringConvertible {
    let description: String
}

func esperar(_ condicion: Bool, _ mensaje: String) throws {
    guard condicion else { throw FalloDePrueba(description: mensaje) }
}

func esperarIgual<T: Equatable>(_ obtenido: T, _ esperado: T, _ mensaje: String) throws {
    guard obtenido == esperado else {
        throw FalloDePrueba(description: "\(mensaje) — se obtuvo «\(obtenido)», se esperaba «\(esperado)»")
    }
}

/// Comprueba que el bloque lanza exactamente el error esperado.
func esperarError(_ esperado: BovedaError, _ mensaje: String, _ cuerpo: () throws -> Void) throws {
    do {
        try cuerpo()
        throw FalloDePrueba(description: "\(mensaje) — no lanzó ningún error; se esperaba «\(esperado)»")
    } catch let fallo as FalloDePrueba {
        throw fallo
    } catch {
        guard let obtenido = error as? BovedaError, obtenido == esperado else {
            throw FalloDePrueba(description: "\(mensaje) — lanzó «\(error)», se esperaba «\(esperado)»")
        }
    }
}

final class Arnes {
    private var pasadas = 0
    private var fallidas: [(nombre: String, motivo: String)] = []
    private let verde = "\u{1B}[32m", rojo = "\u{1B}[31m", gris = "\u{1B}[90m", normal = "\u{1B}[0m"

    func probar(_ nombre: String, _ cuerpo: () throws -> Void) {
        let inicio = Date()
        do {
            try cuerpo()
            pasadas += 1
            let ms = Int(Date().timeIntervalSince(inicio) * 1000)
            print("  \(verde)✓\(normal) \(nombre) \(gris)(\(ms) ms)\(normal)")
        } catch {
            let motivo = (error as? FalloDePrueba)?.description ?? "\(error)"
            fallidas.append((nombre, motivo))
            print("  \(rojo)✗ \(nombre)\(normal)")
            print("      \(motivo)")
        }
    }

    func seccion(_ titulo: String) {
        print("\n\(titulo)")
    }

    func resumen() -> Int32 {
        print("")
        if fallidas.isEmpty {
            print("\(verde)\(pasadas) pruebas superadas.\(normal)")
            return 0
        }
        print("\(rojo)\(fallidas.count) de \(pasadas + fallidas.count) pruebas fallaron:\(normal)")
        for fallo in fallidas {
            print("  • \(fallo.nombre): \(fallo.motivo)")
        }
        return 1
    }
}
