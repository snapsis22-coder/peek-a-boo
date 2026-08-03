import Foundation

/// Errores del motor. Los mensajes están en español porque llegan tal cual a la UI.
public enum BovedaError: LocalizedError, Equatable {
    case archivoNoEncontrado(URL)
    case yaExiste(URL)
    case noEsUnaBoveda
    case versionNoSoportada(UInt16)
    case cabeceraCorrupta
    case contrasenaIncorrecta
    case indiceCorrupto
    case entradaNoEncontrada(UUID)
    case datosCorruptos(String)
    case bovedaEnUso
    case bovedaCerrada
    case entradaSalida(String)
    case contrasenaVacia
    case carpetaYaGestionada(String)
    case carpetaNoEncontrada(UUID)
    case sinRutaOriginal(String)
    case espacioInsuficiente(necesario: UInt64, disponible: UInt64)

    public var errorDescription: String? {
        switch self {
        case .archivoNoEncontrado(let url):
            return "No existe el archivo \(url.path)."
        case .yaExiste(let url):
            return "Ya existe un archivo en \(url.path)."
        case .noEsUnaBoveda:
            return "El archivo no es una bóveda válida."
        case .versionNoSoportada(let v):
            return "Formato de bóveda versión \(v): esta versión de Bóveda no puede abrirlo."
        case .cabeceraCorrupta:
            return "La cabecera de la bóveda está dañada."
        case .contrasenaIncorrecta:
            return "Contraseña incorrecta."
        case .indiceCorrupto:
            return "El índice de la bóveda está dañado o fue manipulado."
        case .entradaNoEncontrada(let id):
            return "No hay ninguna entrada con el identificador \(id.uuidString)."
        case .datosCorruptos(let nombre):
            return "Los datos cifrados de «\(nombre)» están dañados o fueron manipulados."
        case .bovedaEnUso:
            return "Otra aplicación tiene abierta esta bóveda."
        case .bovedaCerrada:
            return "La bóveda ya fue cerrada."
        case .entradaSalida(let detalle):
            return "Error de lectura/escritura: \(detalle)"
        case .contrasenaVacia:
            return "La contraseña no puede estar vacía."
        case .carpetaYaGestionada(let nombre):
            return "La carpeta «\(nombre)» ya está guardada en esta bóveda."
        case .carpetaNoEncontrada:
            return "Esa carpeta ya no está en la bóveda."
        case .espacioInsuficiente(let necesario, let disponible):
            let f = ByteCountFormatter()
            f.countStyle = .file
            return "No hay espacio suficiente: hacen falta \(f.string(fromByteCount: Int64(necesario))) " +
                   "y sólo quedan \(f.string(fromByteCount: Int64(disponible)))."
        case .sinRutaOriginal(let nombre):
            return "«\(nombre)» no recuerda de dónde salió, así que no se puede devolver a su sitio."
        }
    }
}
