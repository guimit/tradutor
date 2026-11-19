import AppKit
import SwiftUI

/// Janela de Definições (⌘,).
struct SettingsView: View {
    let appState: AppState
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            Tab("Legendas", systemImage: "captions.bubble") {
                OverlaySettingsView(appState: appState, settings: settings)
            }
            Tab("Transcrição", systemImage: "waveform") {
                TranscriptionSettingsView(settings: settings)
            }
            Tab("Tradução", systemImage: "translate") {
                TranslationSettingsView(settings: settings)
            }
        }
        .frame(width: 480)
    }
}

private struct OverlaySettingsView: View {
    let appState: AppState
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Mostrar", selection: $settings.overlayDisplayMode) {
                ForEach(OverlayDisplayMode.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Traduzir para", selection: $settings.targetLanguage) {
                ForEach(Language.allCases) { Text($0.displayName).tag($0) }
            }
            if !settings.isTranslationNeeded {
                Text("O idioma de origem é igual ao de destino: mostra-se só o original.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Aparência") {
                Slider(value: $settings.overlayFontSize, in: AppSettings.fontSizeRange, step: 2) {
                    Text("Tamanho do texto")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                Text("\(Int(settings.overlayFontSize)) pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Slider(value: $settings.overlayBackgroundOpacity, in: 0...1) {
                    Text("Opacidade do fundo")
                }
                Text("\(Int(settings.overlayBackgroundOpacity * 100)) %")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Stepper(value: $settings.overlayLineCount, in: AppSettings.lineCountRange) {
                    Text("Linhas: \(settings.overlayLineCount)")
                }
            }

            Section("Comportamento") {
                Slider(value: $settings.overlayHideDelay, in: AppSettings.hideDelayRange, step: 1) {
                    Text("Esconder após silêncio")
                }
                Text("\(Int(settings.overlayHideDelay)) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
}

private struct TranscriptionSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Picker("Motor", selection: $settings.transcriptionEngine) {
                ForEach(TranscriptionEngineKind.allCases) { Text($0.displayName).tag($0) }
            }
            if settings.transcriptionEngine == .whisperKit {
                Picker("Modelo", selection: $settings.whisperModel) {
                    ForEach(WhisperModel.allCases) { model in
                        Text(model.displayName + (WhisperModelStore.isDownloaded(model) ? "" : " — por descarregar"))
                            .tag(model)
                    }
                }
            } else if settings.sourceLanguage == .auto {
                Text("O motor da Apple não deteta o idioma: escolhe um idioma de origem fixo.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Idioma de origem", selection: $settings.sourceLanguage) {
                ForEach(SourceLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Variante do português", selection: $settings.portugueseVariant) {
                ForEach(PortugueseVariant.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Idioma de destino", selection: $settings.targetLanguage) {
                ForEach(Language.allCases) { Text($0.displayName).tag($0) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranslationSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var deepLKey = ""
    @State private var llmKey = ""

    var body: some View {
        Form {
            Picker("Idioma de destino", selection: $settings.targetLanguage) {
                ForEach(Language.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Motor", selection: $settings.translationEngine) {
                ForEach(TranslationEngineKind.allCases) { Text($0.displayName).tag($0) }
            }
            if settings.translationEngine.isCloud {
                Text("Este motor envia o texto transcrito para um serviço externo e ainda não está implementado.")
                    .font(.caption)
                    .foregroundStyle(.orange)
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

            Section("Debug") {
                Toggle("Mostrar latência no overlay", isOn: $settings.showLatency)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            deepLKey = KeychainStore.string(for: DeepLEngine.keychainAccount) ?? ""
            llmKey = KeychainStore.string(for: LLMTranslationEngine.keychainAccount) ?? ""
        }
    }
}
