import BovedaKit
import Foundation

// Datos de mentira para las previews de SwiftUI: sin esto habría que abrir una
// bóveda de verdad, que es justo lo que no puede hacerse dentro del canvas.
extension ResumenBoveda {

    static var ejemplos: [ResumenBoveda] {
        [
            ResumenBoveda(ruta: "/Users/ejemplo/MyVault.peekb",
                          volumen: "Macintosh HD",
                          esArranque: true, esExtraible: false,
                          espacioLibre: 74_000_000_000,
                          existe: true, abierta: true,
                          visibilidad: .oculta,
                          carpetas: ManagedFolder.ejemplos,
                          sueltos: Array(VaultEntry.ejemplos.prefix(3)),
                          tamanoTotal: 2_712_000_000,
                          espacioMuerto: 340_000_000),

            ResumenBoveda(ruta: "/Volumes/Externo/MyVault.peekb",
                          volumen: "Externo",
                          esArranque: false, esExtraible: true,
                          espacioLibre: 1_800_000_000_000,
                          existe: true, abierta: true,
                          visibilidad: .visible,
                          carpetas: [],
                          sueltos: Array(VaultEntry.ejemplos.suffix(2)),
                          tamanoTotal: 1_851_100_000,
                          espacioMuerto: 0),

            ResumenBoveda(ruta: "/Volumes/Respaldo/MyVault.peekb",
                          volumen: "Respaldo",
                          esArranque: false, esExtraible: true,
                          espacioLibre: 420_000_000_000,
                          existe: false, abierta: false,
                          visibilidad: .oculta,
                          carpetas: [], sueltos: [], tamanoTotal: 0, espacioMuerto: 0),
        ]
    }
}
