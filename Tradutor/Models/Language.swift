import Foundation

/// Idiomas suportados pela app.
/// A variante do português (PT-PT / PT-BR) é uma definição à parte, não um caso deste enum.
enum Language: String, CaseIterable, Identifiable, Codable, Sendable {
    case portuguese = "pt"
    case english = "en"
    case spanish = "es"

    var id: String { rawValue }

    /// Nome do idioma no próprio idioma, como aparece nos menus.
    var displayName: String {
        switch self {
        case .portuguese: "Português"
        case .english: "English"
        case .spanish: "Español"
        }
    }
}

/// Variante do português. Influencia o vocabulário da transcrição (e, mais tarde, da tradução).
enum PortugueseVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    case portugal = "pt-PT"
    case brazil = "pt-BR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .portugal: "Português (Portugal)"
        case .brazil: "Português (Brasil)"
        }
    }
}

/// Idioma de origem: deteção automática ou um idioma fixo.
enum SourceLanguage: Hashable, Sendable {
    case auto
    case fixed(Language)

    static let allCases: [SourceLanguage] = [.auto] + Language.allCases.map { .fixed($0) }

    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .fixed(let language): language.displayName
        }
    }
}

extension SourceLanguage: RawRepresentable {
    init?(rawValue: String) {
        if rawValue == "auto" {
            self = .auto
        } else if let language = Language(rawValue: rawValue) {
            self = .fixed(language)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .auto: "auto"
        case .fixed(let language): language.rawValue
        }
    }
}
