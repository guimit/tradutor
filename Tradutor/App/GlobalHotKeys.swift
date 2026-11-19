import Carbon.HIToolbox
import Observation

/// Atalhos de teclado globais (funcionam com outra app ativa).
///
/// Usa `RegisterEventHotKey` do Carbon: continua a ser a forma suportada de registar uma
/// combinação de teclas global sem pedir a permissão de Acessibilidade ou de Monitorização
/// de Input (que um `NSEvent.addGlobalMonitorForEvents` exigiria). O sistema entrega o
/// evento `kEventHotKeyPressed` à app na thread principal, mesmo sem a app estar ativa.
@MainActor
@Observable
final class GlobalHotKeys {
    enum Action: UInt32, CaseIterable, Sendable {
        case toggleCaptions = 1
        case cycleDisplayMode = 2
    }

    /// Atalhos que não foi possível registar (ex.: o mesmo atalho para as duas ações).
    private(set) var failed: Set<Action> = []

    /// Enquanto se grava um atalho nas Definições, os globais ficam desligados: senão,
    /// premir o atalho atual disparava a ação em vez de chegar ao gravador.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { reregister() } }
    }

    @ObservationIgnored private var hotKeys: [Action: HotKey] = [:]
    @ObservationIgnored private var refs: [Action: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private let onAction: @MainActor (Action) -> Void

    /// O callback C do Carbon não captura contexto; encontra a instância por aqui.
    private static weak var current: GlobalHotKeys?
    /// Assinatura dos nossos atalhos ('TRDT'), para distinguir de outros na mesma app.
    private static let signature: OSType = 0x5452_4454

    init(onAction: @escaping @MainActor (Action) -> Void) {
        self.onAction = onAction
        Self.current = self

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            // Os eventos Carbon da app chegam pelo run loop principal.
            MainActor.assumeIsolated {
                if let action = Action(rawValue: id.id) { GlobalHotKeys.current?.onAction(action) }
            }
            return noErr
        }, 1, &eventType, nil, &handler)
    }

    isolated deinit {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Define (ou remove, com `nil`) o atalho de uma ação.
    func set(_ hotKey: HotKey?, for action: Action) {
        guard hotKeys[action] != hotKey else { return }
        hotKeys[action] = hotKey
        reregister()
    }

    private func reregister() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        var failed: Set<Action> = []
        if !isSuspended {
            for action in Action.allCases {
                guard let hotKey = hotKeys[action] else { continue }
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(
                    hotKey.keyCode, hotKey.modifiers,
                    EventHotKeyID(signature: Self.signature, id: action.rawValue),
                    GetApplicationEventTarget(), 0, &ref
                )
                if status == noErr, let ref { refs[action] = ref } else { failed.insert(action) }
            }
        }
        self.failed = failed
    }
}
