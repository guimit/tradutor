/// Estabiliza o idioma detetado janela a janela, para a legenda não saltar de idioma
/// por causa de uma deteção isolada errada (comum em janelas curtas ou com ruído).
///
/// Regras:
/// - A primeira deteção suportada é adotada logo (não há idioma anterior a proteger).
/// - Depois disso, só se muda de idioma quando `requiredAgreement` janelas consecutivas
///   concordam no mesmo idioma novo.
/// - Uma deteção não suportada (`nil`, ex.: francês) não muda nada e interrompe a sequência.
struct LanguageStabilizer: Sendable {
    let requiredAgreement: Int
    private(set) var current: Language?
    private var candidate: Language?
    private var streak = 0

    init(requiredAgreement: Int = 2, initial: Language? = nil) {
        precondition(requiredAgreement >= 1)
        self.requiredAgreement = requiredAgreement
        self.current = initial
    }

    /// Regista a deteção de uma janela e devolve o idioma estável atual.
    @discardableResult
    mutating func observe(_ detected: Language?) -> Language? {
        guard let detected, detected != current else {
            resetCandidate()
            return current
        }
        guard current != nil else {
            current = detected
            return current
        }

        if detected == candidate {
            streak += 1
        } else {
            candidate = detected
            streak = 1
        }
        if streak >= requiredAgreement {
            current = detected
            resetCandidate()
        }
        return current
    }

    private mutating func resetCandidate() {
        candidate = nil
        streak = 0
    }
}
