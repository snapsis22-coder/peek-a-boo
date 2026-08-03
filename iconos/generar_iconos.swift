import AppKit
import CoreGraphics
import Foundation

// Genera los dos iconos de Peek a Boo, ambos dibujados por código:
//
//   swift generar_iconos.swift app        AppIcon_1024.png
//   swift generar_iconos.swift documento  DocIcon_1024.png
//
// El de la app es la caja fuerte gris. El del documento es la hoja de papel con
// la caja fuerte pequeña encima, que es la convención de macOS para archivos
// propios de una aplicación.

let lado = 1024.0
let modo = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app"
let salida = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "icono.png"

guard let espacio = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: Int(lado), height: Int(lado),
                          bitsPerComponent: 8, bytesPerRow: 0, space: espacio,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no se pudo crear el contexto")
}

func gris(_ v: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: v, green: v, blue: v, alpha: a)
}

func degradado(_ colores: [CGColor], _ puntos: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: espacio, colors: colores as CFArray, locations: puntos)!
}

ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

/// Dibuja la caja fuerte dentro del rectángulo dado. `detalle` baja el nivel de
/// adorno cuando va pequeña sobre el documento.
func cajaFuerte(en cuerpo: CGRect, radio: Double, detalle: Bool) {
    // Cuerpo metálico
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: cuerpo, cornerWidth: radio, cornerHeight: radio, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(degradado([gris(0.95), gris(0.86), gris(0.72), gris(0.62)],
                                     [0, 0.42, 0.78, 1]),
                           start: CGPoint(x: cuerpo.minX, y: cuerpo.maxY),
                           end: CGPoint(x: cuerpo.maxX, y: cuerpo.minY),
                           options: [])
    ctx.drawLinearGradient(degradado([gris(1, 0.42), gris(1, 0.12), gris(1, 0)], [0, 0.34, 0.62]),
                           start: CGPoint(x: cuerpo.minX, y: cuerpo.maxY),
                           end: CGPoint(x: cuerpo.midX + cuerpo.width * 0.07,
                                        y: cuerpo.midY - cuerpo.height * 0.07),
                           options: [])
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: cuerpo.insetBy(dx: 1.5, dy: 1.5),
                       cornerWidth: radio, cornerHeight: radio, transform: nil))
    ctx.setStrokeColor(gris(0.42, 0.55))
    ctx.setLineWidth(cuerpo.width * 0.004)
    ctx.strokePath()

    // Puerta interior
    let inset = cuerpo.width * 0.115
    let puerta = cuerpo.insetBy(dx: inset, dy: inset)
    let radioPuerta = radio * 0.52
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: puerta, cornerWidth: radioPuerta, cornerHeight: radioPuerta, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(degradado([gris(0.93), gris(0.80), gris(0.70)], [0, 0.55, 1]),
                           start: CGPoint(x: puerta.minX, y: puerta.maxY),
                           end: CGPoint(x: puerta.maxX, y: puerta.minY),
                           options: [])
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: puerta, cornerWidth: radioPuerta, cornerHeight: radioPuerta, transform: nil))
    ctx.setStrokeColor(gris(0.28, 0.85))
    ctx.setLineWidth(cuerpo.width * 0.013)
    ctx.strokePath()

    // Pernos
    func perno(centroY: Double) {
        let anchoBase = cuerpo.width * 0.096, altoBase = cuerpo.height * 0.151
        let base = CGRect(x: cuerpo.minX + cuerpo.width * 0.041,
                          y: centroY - altoBase / 2, width: anchoBase, height: altoBase)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: base, cornerWidth: anchoBase * 0.28,
                           cornerHeight: anchoBase * 0.28, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(degradado([gris(0.88), gris(0.55), gris(0.74)], [0, 0.55, 1]),
                               start: CGPoint(x: base.minX, y: base.maxY),
                               end: CGPoint(x: base.minX, y: base.minY), options: [])
        ctx.restoreGState()

        let vastago = CGRect(x: base.maxX - cuerpo.width * 0.007, y: centroY - cuerpo.height * 0.043,
                             width: cuerpo.width * 0.115, height: cuerpo.height * 0.086)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: vastago, cornerWidth: vastago.height * 0.28,
                           cornerHeight: vastago.height * 0.28, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(degradado([gris(0.92), gris(0.62), gris(0.78)], [0, 0.6, 1]),
                               start: CGPoint(x: vastago.minX, y: vastago.maxY),
                               end: CGPoint(x: vastago.minX, y: vastago.minY), options: [])
        ctx.restoreGState()
    }
    perno(centroY: cuerpo.minY + cuerpo.height * 0.715)
    perno(centroY: cuerpo.minY + cuerpo.height * 0.285)

    // Dial
    let centro = CGPoint(x: cuerpo.minX + cuerpo.width * 0.585,
                         y: cuerpo.minY + cuerpo.height * 0.5)
    let rExterior = cuerpo.width * 0.257
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -cuerpo.height * 0.007),
                  blur: cuerpo.width * 0.022, color: gris(0, 0.35))
    ctx.addEllipse(in: CGRect(x: centro.x - rExterior, y: centro.y - rExterior,
                              width: rExterior * 2, height: rExterior * 2))
    ctx.setFillColor(gris(0.78))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: centro.x - rExterior, y: centro.y - rExterior,
                              width: rExterior * 2, height: rExterior * 2))
    ctx.clip()
    ctx.drawLinearGradient(degradado([gris(0.97), gris(0.72), gris(0.88)], [0, 0.6, 1]),
                           start: CGPoint(x: centro.x - rExterior, y: centro.y + rExterior),
                           end: CGPoint(x: centro.x + rExterior, y: centro.y - rExterior),
                           options: [])
    ctx.restoreGState()

    let rEsfera = cuerpo.width * 0.202
    ctx.addEllipse(in: CGRect(x: centro.x - rEsfera, y: centro.y - rEsfera,
                              width: rEsfera * 2, height: rEsfera * 2))
    ctx.setFillColor(gris(0.13))
    ctx.fillPath()

    if detalle {
        ctx.saveGState()
        ctx.setStrokeColor(gris(1, 0.92))
        ctx.setLineCap(.round)
        for i in 0..<60 {
            let angulo = Double(i) / 60 * 2 * .pi
            let larga = i % 5 == 0
            let desde = rEsfera - (larga ? cuerpo.width * 0.055 : cuerpo.width * 0.031)
            let hasta = rEsfera - cuerpo.width * 0.012
            ctx.setLineWidth(larga ? cuerpo.width * 0.011 : cuerpo.width * 0.006)
            ctx.move(to: CGPoint(x: centro.x + cos(angulo) * desde, y: centro.y + sin(angulo) * desde))
            ctx.addLine(to: CGPoint(x: centro.x + cos(angulo) * hasta, y: centro.y + sin(angulo) * hasta))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    let rPerilla = cuerpo.width * 0.077
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -cuerpo.height * 0.006),
                  blur: cuerpo.width * 0.017, color: gris(0, 0.5))
    ctx.addEllipse(in: CGRect(x: centro.x - rPerilla, y: centro.y - rPerilla,
                              width: rPerilla * 2, height: rPerilla * 2))
    ctx.setFillColor(gris(0.85))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: centro.x - rPerilla, y: centro.y - rPerilla,
                              width: rPerilla * 2, height: rPerilla * 2))
    ctx.clip()
    ctx.drawLinearGradient(degradado([gris(0.99), gris(0.78), gris(0.92)], [0, 0.62, 1]),
                           start: CGPoint(x: centro.x - rPerilla, y: centro.y + rPerilla),
                           end: CGPoint(x: centro.x + rPerilla, y: centro.y - rPerilla),
                           options: [])
    ctx.restoreGState()
}

switch modo {
case "app":
    let margen = 92.0
    let cuerpo = CGRect(x: margen, y: margen, width: lado - margen * 2, height: lado - margen * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 46, color: gris(0, 0.30))
    ctx.addPath(CGPath(roundedRect: cuerpo, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setFillColor(gris(0.80))
    ctx.fillPath()
    ctx.restoreGState()
    cajaFuerte(en: cuerpo, radio: 185, detalle: true)

case "documento":
    // Hoja de papel con la esquina doblada, la convención de macOS.
    let ancho = 760.0, alto = 940.0
    let x = (lado - ancho) / 2, y = (lado - alto) / 2
    let doblez = 190.0

    let hoja = CGMutablePath()
    let r = 26.0
    hoja.move(to: CGPoint(x: x + r, y: y))
    hoja.addLine(to: CGPoint(x: x + ancho - r, y: y))
    hoja.addArc(tangent1End: CGPoint(x: x + ancho, y: y),
                tangent2End: CGPoint(x: x + ancho, y: y + r), radius: r)
    hoja.addLine(to: CGPoint(x: x + ancho, y: y + alto - doblez))
    hoja.addLine(to: CGPoint(x: x + ancho - doblez, y: y + alto))
    hoja.addLine(to: CGPoint(x: x + r, y: y + alto))
    hoja.addArc(tangent1End: CGPoint(x: x, y: y + alto),
                tangent2End: CGPoint(x: x, y: y + alto - r), radius: r)
    hoja.addLine(to: CGPoint(x: x, y: y + r))
    hoja.addArc(tangent1End: CGPoint(x: x, y: y), tangent2End: CGPoint(x: x + r, y: y), radius: r)
    hoja.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: gris(0, 0.28))
    ctx.addPath(hoja)
    ctx.setFillColor(gris(0.99))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.addPath(hoja)
    ctx.setStrokeColor(gris(0.72, 0.9))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // La esquina doblada
    let pliegue = CGMutablePath()
    pliegue.move(to: CGPoint(x: x + ancho, y: y + alto - doblez))
    pliegue.addLine(to: CGPoint(x: x + ancho - doblez, y: y + alto - doblez))
    pliegue.addLine(to: CGPoint(x: x + ancho - doblez, y: y + alto))
    pliegue.closeSubpath()
    ctx.saveGState()
    ctx.addPath(pliegue)
    ctx.clip()
    ctx.drawLinearGradient(degradado([gris(0.80), gris(0.94)], [0, 1]),
                           start: CGPoint(x: x + ancho - doblez, y: y + alto),
                           end: CGPoint(x: x + ancho, y: y + alto - doblez),
                           options: [])
    ctx.restoreGState()
    ctx.addPath(pliegue)
    ctx.setStrokeColor(gris(0.72, 0.9))
    ctx.setLineWidth(3)
    ctx.strokePath()

    // La caja fuerte, centrada en la mitad inferior de la hoja
    let ladoCaja = 470.0
    let caja = CGRect(x: x + (ancho - ladoCaja) / 2, y: y + 150, width: ladoCaja, height: ladoCaja)
    cajaFuerte(en: caja, radio: 86, detalle: false)

default:
    fatalError("modo desconocido: \(modo). Usa «app» o «documento».")
}

guard let imagen = ctx.makeImage() else { fatalError("no se pudo generar la imagen") }
let url = URL(fileURLWithPath: salida)
let destino = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destino, imagen, nil)
CGImageDestinationFinalize(destino)
print("escrito \(url.path)")
