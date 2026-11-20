import CoreAudio
import Foundation

/// Avisa quando muda o dispositivo de saída predefinido (ex.: colunas → auscultadores).
///
/// O ScreenCaptureKit capta a mistura do sistema e não um dispositivo, mas a troca de
/// dispositivo (sobretudo com outra frequência de amostragem, como auscultadores Bluetooth)
/// pode interromper ou calar o stream. Por isso o pipeline recomeça a captação nesta altura.
enum AudioDeviceMonitor {
    static func defaultOutputChanges() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            // O mesmo bloco tem de ser passado ao remover o listener.
            nonisolated(unsafe) let listener: AudioObjectPropertyListenerBlock = { _, _ in continuation.yield() }
            var addAddress = address
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addAddress, .main, listener)
            guard status == noErr else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                var address = address
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            }
        }
    }
}
