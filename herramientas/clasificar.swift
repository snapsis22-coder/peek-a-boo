import AVFoundation
import CryptoKit
import Foundation
import ImageIO

// Clasifica lo que recupera PhotoRec: separa lo que abre de verdad de lo que está
// truncado, quita duplicados y organiza por fecha de captura.
//
//   swift clasificar.swift <carpetaOrigen> <carpetaDestino>
//
// Validar no es mirar la extensión: cada archivo se abre con ImageIO o AVFoundation,
// que es lo mismo que hará Fotos o QuickTime cuando lo intentes ver.

setvbuf(stdout, nil, _IONBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    print("Uso: clasificar <carpetaOrigen> <carpetaDestino>")
    exit(1)
}
let origen = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
let destino = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)

let fm = FileManager.default
let formatoFecha: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return f
}()

func carpeta(_ ruta: URL) throws {
    try fm.createDirectory(at: ruta, withIntermediateDirectories: true)
}

/// Fecha de captura y dimensiones, si la imagen se puede abrir.
func revisarImagen(_ url: URL) -> (ok: Bool, fecha: Date?, pixeles: Int)? {
    guard let fuente = CGImageSourceCreateWithURL(url as CFURL, nil) else { return (false, nil, 0) }
    let estado = CGImageSourceGetStatus(fuente)
    guard estado == .statusComplete else { return (false, nil, 0) }
    guard let props = CGImageSourceCopyPropertiesAtIndex(fuente, 0, nil) as? [CFString: Any] else {
        return (false, nil, 0)
    }
    let ancho = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    let alto = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    guard ancho > 0, alto > 0 else { return (false, nil, 0) }

    // Comprobación real: decodificar. Un JPEG truncado supera lo anterior pero falla aquí.
    guard CGImageSourceCreateImageAtIndex(fuente, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
        return (false, nil, ancho * alto)
    }

    var fecha: Date?
    if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
       let texto = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
        fecha = formatoFecha.date(from: texto)
    }
    if fecha == nil, let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
       let texto = tiff[kCGImagePropertyTIFFDateTime] as? String {
        fecha = formatoFecha.date(from: texto)
    }
    return (true, fecha, ancho * alto)
}

/// Un vídeo sirve si tiene pista de imagen y duración: sin el átomo `moov` no abre.
func revisarVideo(_ url: URL) -> (ok: Bool, fecha: Date?, segundos: Double) {
    let activo = AVURLAsset(url: url)
    let duracion = CMTimeGetSeconds(activo.duration)
    let pistas = activo.tracks(withMediaType: .video)
    guard duracion.isFinite, duracion > 0.2, !pistas.isEmpty else { return (false, nil, 0) }
    return (true, activo.creationDate?.dateValue, duracion)
}

// MARK: - Recorrido

print("Revisando \(origen.path)…\n")

let salidaFotos = destino.appendingPathComponent("FOTOS")
let salidaVideos = destino.appendingPathComponent("VIDEOS")
let salidaDudosas = destino.appendingPathComponent("DAÑADOS")
try carpeta(salidaFotos); try carpeta(salidaVideos); try carpeta(salidaDudosas)

var vistos = Set<String>()          // hashes, para descartar duplicados
var fotos = 0, videos = 0, rotos = 0, duplicados = 0, miniaturas = 0
var revisados = 0

let enumerador = fm.enumerator(at: origen, includingPropertiesForKeys: [.isRegularFileKey])!
for caso in enumerador {
    guard let url = caso as? URL,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }

    let extension_ = url.pathExtension.lowercased()
    guard ["jpg", "jpeg", "png", "heic", "mov", "mp4", "m4v"].contains(extension_) else { continue }

    revisados += 1
    if revisados % 500 == 0 {
        print("  \(revisados) revisados — \(fotos) fotos, \(videos) vídeos, \(rotos) dañados, \(duplicados) duplicados")
    }

    autoreleasepool {
        // Duplicados: PhotoRec recupera la misma imagen varias veces si estaba repetida.
        guard let datos = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let huella = Data(SHA256.hash(data: datos)).map { String(format: "%02x", $0) }.joined()
        if vistos.contains(huella) { duplicados += 1; try? fm.removeItem(at: url); return }
        vistos.insert(huella)

        let esVideo = ["mov", "mp4", "m4v"].contains(extension_)
        var carpetaFinal: URL
        var fecha: Date?

        if esVideo {
            let r = revisarVideo(url)
            if r.ok { videos += 1; carpetaFinal = salidaVideos; fecha = r.fecha }
            else { rotos += 1; carpetaFinal = salidaDudosas; fecha = nil }
        } else {
            guard let r = revisarImagen(url) else { rotos += 1; return }
            if r.ok {
                // Menos de 0,2 Mpx casi siempre es una miniatura o un icono.
                if r.pixeles < 200_000 {
                    miniaturas += 1
                    carpetaFinal = salidaFotos.appendingPathComponent("miniaturas")
                } else {
                    fotos += 1
                    carpetaFinal = salidaFotos
                }
                fecha = r.fecha
            } else {
                rotos += 1
                carpetaFinal = salidaDudosas
            }
        }

        // Los que abren bien se ordenan por fecha de captura.
        if let fecha, carpetaFinal != salidaDudosas {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM"
            carpetaFinal = carpetaFinal.appendingPathComponent(f.string(from: fecha))
        } else if carpetaFinal != salidaDudosas {
            carpetaFinal = carpetaFinal.appendingPathComponent("sin fecha")
        }

        try? carpeta(carpetaFinal)
        var final = carpetaFinal.appendingPathComponent(url.lastPathComponent)
        var n = 1
        while fm.fileExists(atPath: final.path) {
            final = carpetaFinal.appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent)_\(n).\(extension_)")
            n += 1
        }
        try? fm.moveItem(at: url, to: final)
        if let fecha {
            try? fm.setAttributes([.creationDate: fecha, .modificationDate: fecha],
                                  ofItemAtPath: final.path)
        }
    }
}

print("""

╔══════════════════════════════════════════
║ RESULTADO
║   Fotos que abren      : \(fotos)
║   Vídeos que abren     : \(videos)
║   Miniaturas/iconos    : \(miniaturas)
║   Dañados              : \(rotos)
║   Duplicados quitados  : \(duplicados)
║
║   \(salidaFotos.path)
║   \(salidaVideos.path)
║   \(salidaDudosas.path)
╚══════════════════════════════════════════
""")
