import AppKit
import SwiftUI

/// Abas da janela de Definições. A aba escolhida fica guardada, e o menu pode abrir
/// a janela diretamente numa aba (ex.: Motor, quando faltam idiomas de tradução).
enum SettingsTab: String {
    case general, languages, appearance, engine, advanced

    static let storageKey = "settingsTab"

    @MainActor
    static func select(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: storageKey)
    }
}

/// Janela de Definições (⌘,).
struct SettingsView: View {
    let appState: AppState
    @Bindable var settings: AppSettings
    @AppStorage(SettingsTab.storageKey) private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            Tab("Geral", systemImage: "gearshape", value: .general) {
                GeneralSettingsView(appState: appState, settings: settings)
            }
            Tab("Idiomas", systemImage: "globe", value: .languages) {
                LanguageSettingsView(settings: settings)
            }
            Tab("Aparência", systemImage: "captions.bubble", value: .appearance) {
                AppearanceSettingsView(appState: appState, settings: settings)
            }
            Tab("Motor", systemImage: "cpu", value: SettingsTab.engine) {
                EngineSettingsView(settings: settings)
            }
            Tab("Avançado", systemImage: "wrench.and.screwdriver", value: .advanced) {
                AdvancedSettingsView(settings: settings)
            }
        }
        .frame(width: 500)
    }
}

// MARK: - Geral

private struct GeneralSettingsView: View {
    let appState: AppState
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
            }

            Section {
                hotKeyRow("Ligar/desligar legendas", hotKey: $settings.toggleCaptionsHotKey, action: .toggleCaptions)
                hotKeyRow("Alternar o que mostrar", hotKey: $settings.cycleDisplayModeHotKey, action: .cycleDisplayMode)
            } header: {
                Text("Atalhos de teclado")
            } footer: {
                SettingsNote("Funcionam em qualquer app. \"Alternar o que mostrar\" passa por Só original → Só tradução → Original e tradução.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func hotKeyRow(_ title: String, hotKey: Binding<HotKey?>, action: GlobalHotKeys.Action) -> some View {
        LabeledContent(title) {
            HotKeyRecorder(title: title, hotKey: hotKey, hotKeys: appState.hotKeys)
        }
        if appState.hotKeys.failed.contains(action) {
            SettingsNote("Não foi possível ativar este atalho: já está a ser usado (pelo outro atalho ou pelo sistema). Escolhe outro.", kind: .error)
        }
    }
}

// MARK: - Idiomas

private struct LanguageSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Idioma de origem", selection: $settings.sourceLanguage) {
                    ForEach(SourceLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if settings.transcriptionEngine == .appleSpeech, settings.sourceLanguage == .auto {
                    SettingsNote("O motor da Apple não deteta o idioma: escolhe um idioma de origem fixo (ou o WhisperKit em Motor).", kind: .warning)
                }
                Picker("Traduzir para", selection: $settings.targetLanguage) {
                    ForEach(Language.allCases) { Text($0.displayName).tag($0) }
                }
                if !settings.isTranslationNeeded {
                    SettingsNote("A origem é igual ao destino: não há tradução, mostra-se só o original.")
                }
            }

            Section {
                Picker("Variante do português", selection: $settings.portugueseVariant) {
                    ForEach(PortugueseVariant.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                SettingsNote("Afeta a tradução para português (ex.: \"autocarro\" ou \"ônibus\") e orienta a transcrição.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Aparência

private struct AppearanceSettingsView: View {
    let appState: AppState
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Mostrar", selection: $settings.overlayDisplayMode) {
                ForEach(OverlayDisplayMode.allCases) { Text($0.displayName).tag($0) }
            }

            Section("Texto") {
                Slider(value: $settings.overlayFontSize, in: AppSettings.fontSizeRange, step: 2) {
                    Text("Tamanho do texto")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .accessibilityValue("\(Int(settings.overlayFontSize)) pontos")
                SettingsValueLabel("\(Int(settings.overlayFontSize)) pt")

                Slider(value: $settings.overlayBackgroundOpacity, in: 0...1) {
                    Text("Opacidade do fundo")
                }
                .accessibilityValue("\(Int(settings.overlayBackgroundOpacity * 100)) por cento")
                SettingsValueLabel("\(Int(settings.overlayBackgroundOpacity * 100)) %")

                Stepper(value: $settings.overlayLineCount, in: AppSettings.lineCountRange) {
                    Text("Linhas: \(settings.overlayLineCount)")
                }

                Slider(value: $settings.overlayHideDelay, in: AppSettings.hideDelayRange, step: 1) {
                    Text("Esconder após silêncio")
                }
                .accessibilityValue("\(Int(settings.overlayHideDelay)) segundos")
                SettingsValueLabel("\(Int(settings.overlayHideDelay)) s")
            }

            Section("Posição") {
                Picker("Monitor", selection: $settings.overlayScreenName) {
                    Text("Monitor principal").tag(String?.none)
                    ForEach(NSScreen.screens.dropFirst(), id: \.localizedName) { screen in
                        Text(screen.localizedName).tag(Optional(screen.localizedName))
                    }
                    // Monitor guardado mas desligado: mantém-se a escolha visível.
                    if let name = settings.overlayScreenName,
                       !NSScreen.screens.dropFirst().contains(where: { $0.localizedName == name }) {
                        Text("\(name) (desligado)").tag(Optional(name))
                    }
                }
                HStack {
                    Button(appState.overlay.model.isEditing ? "Terminar ajuste" : "Ajustar posição…") {
                        appState.overlay.setEditing(!appState.overlay.model.isEditing)
                    }
                    Button("Repor posição") {
                        appState.overlay.resetPosition()
                    }
                }
                SettingsNote("No modo de ajuste, arrasta a caixa das legendas para onde quiseres. A posição fica guardada.")
            }
        }
        .formStyle(.grouped)
        .onDisappear { appState.overlay.setEditing(false) }
    }

}

// MARK: - Motor

private struct EngineSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var deepLKey = ""
    @State private var llmKey = ""

    var body: some View {
        Form {
            Section("Transcrição") {
                Picker("Motor", selection: $settings.transcriptionEngine) {
                    ForEach(TranscriptionEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.transcriptionEngine == .whisperKit {
                    Picker("Modelo", selection: $settings.whisperModel) {
                        ForEach(WhisperModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    if !WhisperModelStore.isDownloaded(settings.whisperModel) {
                        SettingsNote("Este modelo ainda não está no Mac: é descarregado (\(settings.whisperModel.approximateSize)) ao iniciar as legendas.")
                    }
                } else {
                    SettingsNote("Usa o reconhecimento de fala do macOS. O modelo de cada idioma é descarregado pelo sistema ao iniciar.")
                    if settings.sourceLanguage == .auto {
                        SettingsNote("Não deteta o idioma: escolhe um idioma de origem fixo em Idiomas.", kind: .warning)
                    }
                }
            }

            Section("Tradução") {
                Picker("Motor", selection: $settings.translationEngine) {
                    ForEach(TranslationEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.translationEngine.isCloud {
                    SettingsNote("Este motor envia o texto transcrito para um serviço externo e ainda não está implementado.", kind: .warning)
                }
            }

            if settings.translationEngine == .apple {
                TranslationLanguagesView(portugueseVariant: settings.portugueseVariant)
            }

            Section {
                SecureField("Chave DeepL", text: $deepLKey)
                    .onSubmit { KeychainStore.set(deepLKey, for: DeepLEngine.keychainAccount) }
                SecureField("Chave LLM", text: $llmKey)
                    .onSubmit { KeychainStore.set(llmKey, for: LLMTranslationEngine.keychainAccount) }
            } header: {
                Text("Chaves de API (motores cloud)")
            } footer: {
                SettingsNote("Guardadas no Keychain ao carregar em Enter. Deixa vazio e carrega em Enter para apagar.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            deepLKey = KeychainStore.string(for: DeepLEngine.keychainAccount) ?? ""
            llmKey = KeychainStore.string(for: LLMTranslationEngine.keychainAccount) ?? ""
        }
    }
}

// MARK: - Avançado

private struct AdvancedSettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("Debug") {
                Toggle("Mostrar latência no overlay", isOn: $settings.showLatency)
                SettingsNote("Fala → original → tradução, medida em cada frase.")
            }

            Section("Avisos") {
                Slider(value: $settings.silenceWarningDelay, in: AppSettings.silenceWarningRange, step: 5) {
                    Text("Avisar sem áudio após")
                }
                .accessibilityValue("\(Int(settings.silenceWarningDelay)) segundos")
                SettingsValueLabel("\(Int(settings.silenceWarningDelay)) s")
            }

            Section("Ferramentas") {
                HStack {
                    Button("Testar captação…") { openWindow(id: WindowID.captureTest) }
                    Button("Testar transcrição…") { openWindow(id: WindowID.transcriptionTest) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Componentes

/// Nota curta por baixo de um controlo. Avisos e erros levam um ícone colorido e o texto
/// na cor normal: texto laranja ou vermelho em letra pequena não tem contraste suficiente.
struct SettingsNote: View {
    enum Kind {
        case info, warning, error
    }

    let text: String
    var kind: Kind = .info

    init(_ text: String, kind: Kind = .info) {
        self.text = text
        self.kind = kind
    }

    var body: some View {
        switch kind {
        case .info:
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .warning, .error:
            Label {
                Text(text)
            } icon: {
                Image(systemName: kind == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(kind == .error ? .red : .orange)
                    .accessibilityLabel(kind == .error ? "Erro" : "Aviso")
            }
            .font(.caption)
        }
    }
}

/// Valor de um slider, alinhado à direita. Escondido do VoiceOver: o slider já o anuncia.
struct SettingsValueLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityHidden(true)
    }
}
