import SwiftUI

/// El candado de la pantalla de entrada, dibujado por código.
///
/// Sustituye al `Image(systemName: "lock.fill")` teñido de azul, que se veía
/// plano. Aquí hay volumen: degradado de cuerpo, reflejo lateral, filo biselado,
/// sombra proyectada, sombras de contacto donde el arco entra en el cuerpo y la
/// bocallave hundida. Al ser vectorial escala a cualquier tamaño; el mismo
/// criterio que `iconos/generar_iconos.swift`, que también dibuja en vez de
/// cargar imágenes.
struct Candado: View {

    /// Fase 1: el arco sube unos milímetros y libera la pata corta del cuerpo.
    var alzado: CGFloat = 0
    /// Fase 2: gira 180° sobre el eje de la pata larga, como un candado real.
    var giro: CGFloat = 0
    var lado: CGFloat = 92
    var metal: Metal = .aceroAzulado

    /// La pata corta se acorta mientras sube; pasado eso ya está fuera del cuerpo.
    private var abierto: CGFloat { alzado }

    private var cuerpoW: CGFloat { lado * 0.72 }
    private var cuerpoH: CGFloat { lado * 0.56 }
    private var arcoW: CGFloat { lado * 0.44 }
    private var grosorArco: CGFloat { lado * 0.10 }

    var body: some View {
        ZStack {
            ZStack {
                // El poste no gira: ES el eje. Además impide que el arco se
                // desvanezca al pasar por 90°, donde una figura plana queda de
                // canto y desaparece — un candado real sigue mostrando el cilindro.
                poste
                // El trazo va centrado en su trayectoria, así que el borde
                // izquierdo del marco coincide con el eje de la pata larga:
                // anclar ahí el giro equivale a pivotar sobre el poste.
                arco
                    .rotation3DEffect(.degrees(180 * giro),
                                      axis: (x: 0, y: 1, z: 0),
                                      anchor: .leading,
                                      perspective: 0.35)
            }
            .offset(y: -cuerpoH * 0.62 - lado * 0.085 * alzado)
            cuerpo
        }
        .frame(width: lado, height: lado)
    }

    /// La pata larga. Mismo degradado que el arco para que a giro 0 se funda con
    /// él y no se note que son dos piezas distintas.
    private var poste: some View {
        Capsule()
            .fill(
                LinearGradient(colors: [metal.oscuro, metal.medio, metal.claro, metal.medio, metal.oscuro],
                               startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: grosorArco, height: lado * 0.46 - arcoW / 2 + grosorArco)
            .offset(x: -arcoW / 2)
            .frame(width: arcoW, height: lado * 0.46, alignment: .bottom)
    }

    /// Dos trazos: el ancho da el metal, el fino encima es el reflejo.
    private var arco: some View {
        ZStack {
            ArcoForma(abierto: abierto)
                .stroke(
                    LinearGradient(colors: [metal.oscuro, metal.medio, metal.claro, metal.medio, metal.oscuro],
                                   startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: grosorArco, lineCap: .round))

            ArcoForma(abierto: abierto)
                .stroke(
                    LinearGradient(colors: [.clear, metal.brillo.opacity(0.9), .clear],
                                   startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: grosorArco * 0.28, lineCap: .round))
                .offset(x: -grosorArco * 0.22)
                .blur(radius: lado * 0.004)
        }
        .frame(width: arcoW, height: lado * 0.46)
        .shadow(color: .black.opacity(0.35), radius: lado * 0.02, y: lado * 0.012)
    }

    private var cuerpo: some View {
        RoundedRectangle(cornerRadius: lado * 0.11, style: .continuous)
            .fill(
                LinearGradient(stops: [
                    .init(color: metal.claro, location: 0.00),
                    .init(color: metal.medio, location: 0.42),
                    .init(color: metal.oscuro, location: 0.78),
                    .init(color: metal.medio, location: 1.00),
                ], startPoint: .top, endPoint: .bottom)
            )
            // Reflejo lateral: es lo que lo hace leer como metal curvo y no plano.
            .overlay {
                RoundedRectangle(cornerRadius: lado * 0.11, style: .continuous)
                    .fill(
                        LinearGradient(stops: [
                            .init(color: metal.brillo.opacity(0.55), location: 0.00),
                            .init(color: .clear, location: 0.28),
                            .init(color: .clear, location: 0.72),
                            .init(color: .black.opacity(0.28), location: 1.00),
                        ], startPoint: .leading, endPoint: .trailing)
                    )
                    .blendMode(.softLight)
            }
            .overlay {
                RoundedRectangle(cornerRadius: lado * 0.11, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [metal.brillo.opacity(0.7), metal.oscuro.opacity(0.55)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: lado * 0.010)
            }
            // Sombra de contacto en cada pata: sin esto las dos piezas parecen
            // pegadas en vez de ensambladas.
            .overlay(alignment: .top) {
                HStack(spacing: arcoW - grosorArco) {
                    ForEach(0..<2, id: \.self) { _ in
                        Ellipse()
                            .fill(.black.opacity(0.30))
                            .frame(width: grosorArco * 1.15, height: lado * 0.035)
                            .blur(radius: lado * 0.016)
                    }
                }
                .offset(y: lado * 0.004)
            }
            .overlay { cerradura }
            .frame(width: cuerpoW, height: cuerpoH)
            .shadow(color: .black.opacity(0.42), radius: lado * 0.05, y: lado * 0.035)
    }

    /// El hueco, con su pared de arriba en sombra y su labio de abajo iluminado:
    /// con la luz cayendo desde arriba, eso es lo que lo hace leer como hundido.
    private var cerradura: some View {
        ZStack {
            BocallaveForma()
                .fill(
                    LinearGradient(colors: [.black.opacity(0.92), .black.opacity(0.74)],
                                   startPoint: .top, endPoint: .bottom)
                )

            BocallaveForma()
                .stroke(.black.opacity(0.55), lineWidth: lado * 0.012)
                .offset(y: lado * 0.008)
                .mask(BocallaveForma().fill())
                .blur(radius: lado * 0.005)

            BocallaveForma()
                .stroke(metal.brillo.opacity(0.9), lineWidth: lado * 0.010)
                .offset(y: -lado * 0.008)
                .mask(BocallaveForma().fill())
                .blur(radius: lado * 0.002)
        }
        .frame(width: cuerpoW * 0.34, height: cuerpoH * 0.52)
        .offset(y: cuerpoH * 0.04)
    }
}

// MARK: - Formas

/// Dos patas y un semicírculo. Se traza como línea gruesa para que se lea como
/// una barra de acero doblada.
struct ArcoForma: Shape {
    var abierto: CGFloat = 0

    /// Sin esto un `Shape` no se interpola: saltaría de cerrado a abierto de golpe.
    var animatableData: CGFloat {
        get { abierto }
        set { abierto = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let radio = r.width / 2
        // La pata derecha se acorta poco: el grueso del movimiento lo pone el
        // giro del conjunto, que sí se ve desde el primer fotograma.
        let baseDer = r.maxY - r.height * 0.30 * abierto

        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radio))
        p.addArc(center: CGPoint(x: r.midX, y: r.minY + radio),
                 radius: radio,
                 startAngle: .degrees(180),
                 endAngle: .degrees(0),
                 clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: baseDer))
        return p
    }
}

/// Bocallave antigua: **un solo contorno**, no un círculo con un trapecio encima.
///
/// Dibujarla como dos figuras solapadas dejaba una costura visible, porque el
/// trazo de luz recorría también el borde interior de cada una. Aquí el arco se
/// interrumpe abajo y las paredes salen desde donde muere.
struct BocallaveForma: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let radio = r.width * 0.72 / 2
        let centro = CGPoint(x: r.midX, y: r.minY + radio)
        let mediaBase = r.width * 0.31

        // Con y hacia abajo, 270° es arriba y 90° abajo: el arco va de 125° a 55°
        // pasando por arriba y deja el hueco inferior para las paredes.
        func punto(_ grados: Double) -> CGPoint {
            CGPoint(x: centro.x + radio * cos(grados * .pi / 180),
                    y: centro.y + radio * sin(grados * .pi / 180))
        }

        p.move(to: punto(125))
        p.addArc(center: centro, radius: radio,
                 startAngle: .degrees(125), endAngle: .degrees(55 + 360), clockwise: false)
        p.addLine(to: CGPoint(x: r.midX + mediaBase, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX - mediaBase, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Acabados

/// Los cuatro tonos que definen un metal. Cambiar de acabado es cambiar esta línea.
struct Metal {
    let claro: Color
    let medio: Color
    let oscuro: Color
    let brillo: Color

    /// Conserva el parentesco con el azul que tenía el icono plano.
    static let aceroAzulado = Metal(
        claro: Color(red: 0.83, green: 0.87, blue: 0.93),
        medio: Color(red: 0.42, green: 0.50, blue: 0.62),
        oscuro: Color(red: 0.16, green: 0.21, blue: 0.30),
        brillo: Color(red: 0.96, green: 0.98, blue: 1.00))

    static let laton = Metal(
        claro: Color(red: 0.95, green: 0.85, blue: 0.55),
        medio: Color(red: 0.72, green: 0.55, blue: 0.20),
        oscuro: Color(red: 0.34, green: 0.24, blue: 0.06),
        brillo: Color(red: 1.00, green: 0.97, blue: 0.85))

    static let grafito = Metal(
        claro: Color(red: 0.74, green: 0.75, blue: 0.78),
        medio: Color(red: 0.34, green: 0.35, blue: 0.38),
        oscuro: Color(red: 0.10, green: 0.10, blue: 0.12),
        brillo: Color(red: 0.97, green: 0.97, blue: 0.99))
}

#Preview("Candado") {
    HStack(spacing: 20) {
        Candado(lado: 110)
        Candado(alzado: 1, lado: 110)
        Candado(alzado: 1, giro: 0.5, lado: 110)
        Candado(alzado: 1, giro: 1, lado: 110)
        Candado(lado: 110, metal: .laton)
        Candado(lado: 110, metal: .grafito)
    }
    .padding(30)
}
