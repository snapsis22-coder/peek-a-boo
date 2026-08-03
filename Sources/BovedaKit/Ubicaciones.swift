import Foundation

/// Un volumen montado y la bóveda que le corresponde.
public struct VolumenConBoveda: Identifiable, Sendable, Equatable {
    public var id: String { volumenURL.path }

    public let nombre: String
    public let volumenURL: URL
    /// Dónde va la bóveda de este volumen. Siempre la misma ruta.
    public let bovedaURL: URL
    public let existe: Bool
    /// El volumen donde arranca el sistema.
    public let esArranque: Bool
    /// Disco externo, USB, tarjeta… lo que se puede desconectar.
    public let esExtraible: Bool
    public let espacioLibre: UInt64

    public init(nombre: String, volumenURL: URL, bovedaURL: URL, existe: Bool,
                esArranque: Bool, esExtraible: Bool, espacioLibre: UInt64) {
        self.nombre = nombre
        self.volumenURL = volumenURL
        self.bovedaURL = bovedaURL
        self.existe = existe
        self.esArranque = esArranque
        self.esExtraible = esExtraible
        self.espacioLibre = espacioLibre
    }
}

/// Dónde vive la bóveda de cada volumen.
///
/// Una por partición y siempre en el mismo sitio: así no hay que recordar rutas
/// —ni escribirlas en las preferencias, que era un rastro— y basta con recorrer
/// los volúmenes montados para saber qué hay disponible.
public enum Ubicaciones {

    /// Igual que el `MyVault.hvault` de Hider 2, pero con lo nuestro.
    public static let nombreDeArchivo = "MyVault.peekb"

    /// En el disco de arranque va a la carpeta personal: la raíz `/` no es
    /// escribible y además está protegida por el sistema.
    public static func bovedaURL(volumenURL: URL, esArranque: Bool) -> URL {
        let base = esArranque ? FileManager.default.homeDirectoryForCurrentUser : volumenURL
        return base.appendingPathComponent(nombreDeArchivo)
    }

    /// Volúmenes montados donde tiene sentido guardar una bóveda: se descartan
    /// los de sólo lectura (imágenes de disco de apps, instantáneas del sistema).
    public static func volumenes() -> [VolumenConBoveda] {
        let claves: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsRemovableKey,
            .volumeIsEjectableKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey,
            .volumeAvailableCapacityKey,
        ]
        let montados = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: claves,
            options: [.skipHiddenVolumes]) ?? []

        var resultado: [VolumenConBoveda] = []
        for url in montados {
            guard let v = try? url.resourceValues(forKeys: Set(claves)),
                  v.volumeIsBrowsable == true,
                  v.volumeIsReadOnly != true else { continue }

            let esArranque = v.volumeIsRootFileSystem == true
            let boveda = bovedaURL(volumenURL: url, esArranque: esArranque)
            resultado.append(VolumenConBoveda(
                nombre: v.volumeName ?? url.lastPathComponent,
                volumenURL: url,
                bovedaURL: boveda,
                existe: FileManager.default.fileExists(atPath: boveda.path),
                esArranque: esArranque,
                esExtraible: (v.volumeIsRemovable == true) || (v.volumeIsEjectable == true),
                espacioLibre: UInt64(max(0, v.volumeAvailableCapacity ?? 0))))
        }

        // El de arranque primero; los demás por nombre.
        return resultado.sorted {
            if $0.esArranque != $1.esArranque { return $0.esArranque }
            return $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending
        }
    }
}
