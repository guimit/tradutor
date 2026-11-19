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
                Text("Funcionam em qualquer app. \"Alternar o que mostrar\" passa por Só original → Só tradução → Original e tradução.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func hotKeyRow(_ title: String, hotKey: Binding<HotKey?>, action: GlobalHotKeys.Action) -> some View {
        LabeledContent(title) {
            HotKeyRecorder(hotKey: hotKey, hotKeys: appState.hotKeys)
        }
        if appState.hotKeys.failed.contains(action) {
            Text("Não foi possível ativar este atalho: já está a ser usado (pelo outro atalho ou pelo sistema). Escolhe outro.")
                .font(.caption)
                .foregroundStyle(.red)
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
                    Text("O motor da Apple não deteta o idioma: escolhe um idioma de origem fixo (ou o WhisperKit em Motor).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Picker("Traduzir para", selection: $settings.targetLanguage) {
                    ForEach(Language.allCases) { Text($0.displayName).tag($0) }
                }
                if !settings.isTranslationNeeded {
                    Text("A origem é igual ao destino: não há tradução, mostra-se só o original.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Variante do português", selection: $settings.portugueseVariant) {
                    ForEach(PortugueseVariant.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("Afeta a tradução para português (ex.: \"autocarro\" ou \"ônibus\") e orienta a transcrição.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                valueLabel("\(Int(settings.overlayFontSize)) pt")

                Slider(value: $settings.overlayBackgroundOpacity, in: 0...1) {
                    Text("Opacidade do fundo")
                }
                valueLabel("\(Int(settings.overlayBackgroundOpacity * 100)) %")

                Stepper(value: $settings.overlayLineCount, in: AppSettings.lineCountRange) {
                    Text("Linhas: \(settings.overlayLineCount)")
                }

                Slider(value: $settings.overlayHideDelay, in: AppSettings.hideDelayRange, step: 1) {
                    Text("Esconder após silêncio")
                }
                valueLabel("\(Int(settings.overlayHideDelay)) s")
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
                Text("No modo de ajuste, arrasta a caixa das legendas para onde quiseres. A posição fica guardada.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { appState.overlay.setEditing(false) }
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
                        Text("Este modelo ainda não está no Mac: é descarregado (\(settings.whisperModel.approximateSize)) ao iniciar as legendas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Usa o reconhecimento de fala do macOS. O modelo de cada idioma é descarregado pelo sistema ao iniciar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.sourceLanguage == .auto {
                        Text("Não deteta o idioma: escolhe um idioma de origem fixo em Idiomas.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Tradução") {
                Picker("Motor", selection: $settings.translationEngine) {
                    ForEach(TranslationEngineKind.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.translationEngine.isCloud {
                    Text("Este motor envia o texto transcrito para um serviço externo e ainda não está implementado.")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
                Text("Guardadas no Keychain ao carregar em Enter. Deixa vazio e carrega em Enter para apagar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Fala → original → tradução, medida em cada frase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Avisos") {
                Slider(value: $settings.silenceWarningDelay, in: AppSettings.silenceWarningRange, step: 5) {
                    Text("Avisar sem áudio após")
                }
                Text("\(Int(settings.silenceWarningDelay)) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
