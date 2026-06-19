import Foundation
import AVFoundation
import Speech
import UIKit

// Drop-in replacement for GeminiLiveService.
// Uses Apple on-device STT + OpenClaw/Ares chatCompletions + Apple on-device TTS.
// No Gemini API key required.
@MainActor
class AresLiveService: ObservableObject {
    @Published var connectionState: GeminiConnectionState = .disconnected
    @Published var isModelSpeaking: Bool = false

    // Interface mirrors GeminiLiveService for ViewModel compatibility
    var onAudioReceived: ((Data) -> Void)?          // unused: TTS is direct
    var onTurnComplete: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    var onToolCall: ((GeminiToolCall) -> Void)?     // unused: Ares handles tools
    var onToolCallCancellation: ((GeminiToolCallCancellation) -> Void)?

    private let bridge = OpenClawBridge()
    private let synthesizer = AVSpeechSynthesizer()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var silenceTimer: Timer?
    private var pendingTranscript: String = ""
    private var lastFrame: UIImage?

    // MARK: - Lifecycle

    func connect() async -> Bool {
        await bridge.checkConnection()
        guard bridge.connectionState == .connected else {
            connectionState = .error("Ares gateway unreachable — check OpenClaw config")
            return false
        }
        bridge.resetSession()
        await requestPermissions()
        startListening()
        connectionState = .ready
        return true
    }

    func disconnect() {
        stopListening()
        connectionState = .disconnected
        isModelSpeaking = false
    }

    // MARK: - Input (called by existing AudioManager / ViewModel)
    // Audio is handled internally via AVAudioEngine, so these are no-ops.
    func sendAudio(data: Data) {}

    func sendVideoFrame(image: UIImage) {
        lastFrame = image
    }

    func sendToolResponse(_ response: GeminiToolResponse) {}

    // MARK: - STT

    private func startListening() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-CO"))
        audioEngine = AVAudioEngine()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            recognitionRequest?.shouldReportPartialResults = true
            recognitionRequest?.requiresOnDeviceRecognition = false

            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) { [weak self] result, _ in
                guard let self, let result else { return }
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.pendingTranscript = text
                    self.onInputTranscription?(text)
                    self.armSilenceTimer()
                }
            }

            let input = audioEngine!.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                self?.recognitionRequest?.append(buf)
            }
            audioEngine!.prepare()
            try audioEngine!.start()
        } catch {
            connectionState = .error("Mic error: \(error.localizedDescription)")
        }
    }

    private func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let text = self.pendingTranscript.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    self.pendingTranscript = ""
                    await self.sendToAres(text: text, frame: self.lastFrame)
                }
            }
        }
    }

    // MARK: - Ares

    private func sendToAres(text: String, frame: UIImage?) async {
        guard !isModelSpeaking else { return }
        isModelSpeaking = true
        stopListening()

        // Optionally attach camera description via base64 (Claude vision)
        var prompt = text
        if let img = frame,
           let jpg = img.jpegData(compressionQuality: 0.4) {
            let b64 = jpg.base64EncodedString()
            prompt += "\n\n[Camera frame from glasses — base64 JPEG: data:image/jpeg;base64,\(b64)]"
        }

        let result = await bridge.delegateTask(task: prompt)

        switch result {
        case .success(let reply):
            onOutputTranscription?(reply)
            await speak(reply)
        case .failure(let err):
            onOutputTranscription?("Error: \(err)")
        }

        isModelSpeaking = false
        onTurnComplete?()
        startListening()   // resume mic after response
    }

    // MARK: - TTS

    private func speak(_ text: String) async {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
        try? session.setActive(true)

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "es-CO")
                       ?? AVSpeechSynthesisVoice(language: "es-ES")
        utterance.rate = 0.53
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)

        while synthesizer.isSpeaking {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // MARK: - Permissions

    private func requestPermissions() async {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { _ in cont.resume() }
        }
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { _ in cont.resume() }
        }
    }
}
