import Foundation

/// Dono único do motor de transcrição, partilhado pelas legendas e pela janela de teste.
///
/// Carregar um modelo Whisper ocupa centenas de MB e demora, por isso o motor é reutilizado
/// enquanto a configuração não mudar. Como o reconhecedor não é thread-safe, só um
/// utilizador de cada vez o pode ter (`acquire` / `release`).
@MainActor
final class TranscriptionEngineProvider {
    private var engine: (any TranscriptionEngine)?
    private var engineKey: String?
    private(set) var isInUse = false

    /// Devolve o motor pronto a usar, criando-o (e descarregando o modelo) se for preciso.
    /// `progress` recebe 0…1 durante o download e 1 quando começa o carregamento.
    func acquire(
        settings: AppSettings,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> any TranscriptionEngine {
        guard !isInUse else { throw TranscriptionEngineError.inUse }
        isInUse = true

        let key = settings.transcriptionEngineKey
        if let engine, engineKey == key { return engine }

        engine = nil
        engineKey = nil
        let newEngine = settings.makeTranscriptionEngine()
        do {
            try await newEngine.prepare { value in
                Task { @MainActor in progress(value) }
            }
        } catch {
            isInUse = false
            throw error
        }
        engine = newEngine
        engineKey = key
        return newEngine
    }

    func release() {
        isInUse = false
    }
}

enum TranscriptionEngineError: LocalizedError {
    case inUse

    var errorDescription: String? {
        "O motor de transcrição já está a ser usado (pelas legendas ou pela janela de teste). Para o outro primeiro."
    }
}
