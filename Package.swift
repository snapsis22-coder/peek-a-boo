// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Boveda",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BovedaKit", targets: ["BovedaKit"]),
        .library(name: "BovedaUI", targets: ["BovedaUI"]),
        .executable(name: "Boveda", targets: ["Boveda"]),
        .executable(name: "bovedacli", targets: ["bovedacli"]),
        .executable(name: "bovedatests", targets: ["bovedatests"]),
        .executable(name: "bovedarescate", targets: ["bovedarescate"]),
    ],
    targets: [
        // Motor: cifrado y formato del contenedor. Sin nada de interfaz.
        .target(name: "BovedaKit"),

        // Las vistas viven en una librería, no en el ejecutable: las previews de
        // SwiftUI no funcionan bien dentro de un `executableTarget`.
        .target(name: "BovedaUI", dependencies: ["BovedaKit"]),

        // El ejecutable sólo abre la ventana.
        .executableTarget(name: "Boveda", dependencies: ["BovedaUI"]),

        .executableTarget(name: "bovedacli", dependencies: ["BovedaKit"]),
        // Las pruebas son un ejecutable con arnés propio (`swift run bovedatests`).
        // Se escribieron así cuando este equipo no tenía Xcode; ahora que lo tiene,
        // podrían migrarse a swift-testing.
        .executableTarget(name: "bovedatests", dependencies: ["BovedaKit"]),
        // Recuperación de bóvedas borradas leyendo el disco crudo.
        .executableTarget(name: "bovedarescate", dependencies: ["BovedaKit"]),
    ]
)
