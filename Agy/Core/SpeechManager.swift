import Foundation
import AVFoundation
import Speech
import SwiftUI

/// 原生语音识别（实时 32 段波形）+ TTS 消息朗读管理器
@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()

    @Published var isRecording = false
    @Published var transcript = ""
    @Published var levels: [CGFloat] = Array(repeating: 0.14, count: 32)
    @Published var errorMessage: String?
    @Published var speakingItemId: UUID?

    @Published var localeId: String = UserDefaults.standard.string(forKey: "agy_speech_locale") ?? "zh-CN" {
        didSet { UserDefaults.standard.set(localeId, forKey: "agy_speech_locale") }
    }

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var onLiveUpdate: ((String) -> Void)?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    var shortLocaleLabel: String {
        localeId.hasPrefix("zh") ? "中文" : "EN"
    }

    func toggleLocale() {
        localeId = localeId.hasPrefix("zh") ? "en-US" : "zh-CN"
    }

    // MARK: - 权限

    private func ensurePermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            errorMessage = "请在系统设置中开启语音识别权限"
            return false
        }

        let micGranted = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
        guard micGranted else {
            errorMessage = "请在系统设置中开启麦克风权限"
            return false
        }
        return true
    }

    // MARK: - 录音与识别

    func startRecording(onUpdate: @escaping (String) -> Void) async {
        stopSpeaking()
        errorMessage = nil
        guard await ensurePermissions() else { return }

        stopRecordingInternal()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)),
              recognizer.isAvailable else {
            errorMessage = "当前语言的语音识别暂不可用"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            recognitionRequest = request
            onLiveUpdate = onUpdate
            transcript = ""
            levels = Array(repeating: 0.14, count: 32)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let amp = Self.rmsLevel(from: buffer)
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.levels.removeFirst()
                    self.levels.append(amp)
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.transcript = text
                        self.onLiveUpdate?(text)
                        if result.isFinal {
                            self.stopRecordingInternal()
                        }
                    }
                    if error != nil && self.isRecording {
                        self.stopRecordingInternal()
                    }
                }
            }
        } catch {
            errorMessage = "启动录音失败：\(error.localizedDescription)"
            stopRecordingInternal()
        }
    }

    @discardableResult
    func stopRecording() -> String {
        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRecordingInternal()
        return final
    }

    private func stopRecordingInternal() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        onLiveUpdate = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private nonisolated static func rmsLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let data = buffer.floatChannelData?[0] else { return 0.14 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0.14 }
        var sum: Float = 0
        for i in stride(from: 0, to: n, by: 4) {
            let v = data[i]
            sum += v * v
        }
        let rms = sqrt(sum / Float(max(1, n / 4)))
        let db = max(-55, min(-5, 20 * log10(max(rms, 1e-6))))
        let normalized = CGFloat((db + 55) / 50)
        return max(0.12, min(1.0, normalized))
    }

    // MARK: - TTS 朗读

    func toggleSpeak(text: String, itemId: UUID) {
        if speakingItemId == itemId {
            stopSpeaking()
            return
        }
        speak(text: text, itemId: itemId)
    }

    func speak(text: String, itemId: UUID) {
        stopSpeaking()
        let cleaned = Self.stripMarkdown(text)
        guard !cleaned.isEmpty else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {}

        let utterance = AVSpeechUtterance(string: cleaned)
        let hasChinese = cleaned.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: hasChinese ? "zh-CN" : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        speakingItemId = itemId
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speakingItemId = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingItemId = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingItemId = nil }
    }

    private static func stripMarkdown(_ src: String) -> String {
        var s = src
        // 去掉代码块、图片、链接括号、Markdown 标记
        let patterns: [(String, String)] = [
            (#"```[\s\S]*?```"#, " 代码块 "),
            (#"!\[[^\]]*\]\([^\)]*\)"#, ""),
            (#"\[([^\]]+)\]\([^\)]+\)"#, "$1"),
            (#"\$\$[\s\S]*?\$\$"#, " 公式 "),
            (#"`([^`]+)`"#, "$1"),
            (#"[#>*_~]+"#, " ")
        ]
        for (p, r) in patterns {
            s = s.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3000))
    }
}
