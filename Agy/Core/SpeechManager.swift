import Foundation
import AVFoundation
import Speech
import SwiftUI

// MARK: - 自定义 TTS / STT 语音服务配置（兼容 OpenAI / 硅基流动 / Groq / Fish Audio / Edge-TTS / 本地 Whisper 等）

enum VoiceProviderMode: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case custom = "custom"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "Apple 系统自带"
        case .custom: return "自定义 API 模型"
        }
    }
}

struct CustomTTSConfig: Codable, Equatable {
    var mode: VoiceProviderMode = .system
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-4o-mini-tts"
    var voice: String = "coral"
    var speed: Double = 1.0
    var responseFormat: String = "mp3"
    var instructions: String = ""
    var fallbackToSystem: Bool = true

    var resolvedEndpointURL: URL? {
        Self.resolveEndpoint(base: baseURL, defaultPath: "audio/speech", knownSuffixes: ["/audio/speech", "/speech", "/tts"])
    }

    static func resolveEndpoint(base: String, defaultPath: String, knownSuffixes: [String]) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        for suf in knownSuffixes {
            if lower.hasSuffix(suf) {
                return URL(string: trimmed)
            }
        }
        if lower.hasSuffix("/v1") || lower.contains("/v1/") {
            return URL(string: "\(trimmed)/\(defaultPath)")
        }
        return URL(string: "\(trimmed)/v1/\(defaultPath)")
    }
}

struct CustomSTTConfig: Codable, Equatable {
    var mode: VoiceProviderMode = .system
    var baseURL: String = "https://api.openai.com/v1"
    var model: String = "gpt-4o-mini-transcribe"
    var language: String = "auto"   // auto / zh / en / ja / ko
    var prompt: String = ""

    var resolvedEndpointURL: URL? {
        CustomTTSConfig.resolveEndpoint(
            base: baseURL,
            defaultPath: "audio/transcriptions",
            knownSuffixes: ["/audio/transcriptions", "/audio/translations", "/transcriptions", "/asr"]
        )
    }

    var shortModelTag: String {
        let clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "STT" }
        let last = clean.split(separator: "/").last.map(String.init) ?? clean
        if last.count <= 14 { return last }
        return String(last.prefix(13)) + "…"
    }
}

/// 原生语音识别（实时 32 段波形）+ 自定义 STT 转录 + 系统 / 自定义 TTS 消息朗读管理器
@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = SpeechManager()

    // MARK: - 实时状态
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcript = ""
    @Published var levels: [CGFloat] = Array(repeating: 0.14, count: 32)
    @Published var errorMessage: String?

    @Published var speakingItemId: UUID?
    @Published var loadingTTSItemId: UUID?

    @Published var localeId: String = UserDefaults.standard.string(forKey: "agy_speech_locale") ?? "zh-CN" {
        didSet { UserDefaults.standard.set(localeId, forKey: "agy_speech_locale") }
    }

    // MARK: - 持久化自定义 TTS / STT 配置（API Key 存于 Keychain）
    private static let ttsConfigKey = "agy_custom_tts_config_v1"
    private static let sttConfigKey = "agy_custom_stt_config_v1"
    private static let ttsKeychainAccount = "agy_custom_tts_api_key"
    private static let sttKeychainAccount = "agy_custom_stt_api_key"

    @Published var ttsConfig: CustomTTSConfig {
        didSet {
            if let data = try? JSONEncoder().encode(ttsConfig) {
                UserDefaults.standard.set(data, forKey: Self.ttsConfigKey)
            }
        }
    }

    @Published var sttConfig: CustomSTTConfig {
        didSet {
            if let data = try? JSONEncoder().encode(sttConfig) {
                UserDefaults.standard.set(data, forKey: Self.sttConfigKey)
            }
        }
    }

    var ttsAPIKey: String {
        get { KeychainStore.load(account: Self.ttsKeychainAccount) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainStore.delete(account: Self.ttsKeychainAccount)
            } else {
                KeychainStore.save(trimmed, account: Self.ttsKeychainAccount)
            }
            objectWillChange.send()
        }
    }

    var sttAPIKey: String {
        get { KeychainStore.load(account: Self.sttKeychainAccount) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                KeychainStore.delete(account: Self.sttKeychainAccount)
            } else {
                KeychainStore.save(trimmed, account: Self.sttKeychainAccount)
            }
            objectWillChange.send()
        }
    }

    var isCustomSTTEnabled: Bool { sttConfig.mode == .custom }
    var isCustomTTSEnabled: Bool { ttsConfig.mode == .custom }

    var activeSTTLabel: String {
        isCustomSTTEnabled ? sttConfig.shortModelTag : shortLocaleLabel
    }

    var activeVoiceSummaryBadge: String? {
        switch (isCustomTTSEnabled, isCustomSTTEnabled) {
        case (true, true): return "TTS+STT"
        case (true, false): return "TTS"
        case (false, true): return "STT"
        case (false, false): return nil
        }
    }

    // MARK: - 内部音频/网络句柄
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var onLiveUpdate: ((String) -> Void)?

    // 自定义 STT 录音与转录
    private var audioRecorder: AVAudioRecorder?
    private var recordedAudioURL: URL?
    private var meterTimer: Timer?
    private var recordStartTime: Date?
    private var sttUploadTask: Task<Void, Never>?

    // 自定义 TTS 播放队列
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerContinuation: CheckedContinuation<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var ttsEpoch: Int = 0

    private let httpSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private override init() {
        if let d = UserDefaults.standard.data(forKey: Self.ttsConfigKey),
           let decoded = try? JSONDecoder().decode(CustomTTSConfig.self, from: d) {
            self.ttsConfig = decoded
        } else {
            self.ttsConfig = CustomTTSConfig()
        }
        if let d = UserDefaults.standard.data(forKey: Self.sttConfigKey),
           let decoded = try? JSONDecoder().decode(CustomSTTConfig.self, from: d) {
            self.sttConfig = decoded
        } else {
            self.sttConfig = CustomSTTConfig()
        }
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

    private func ensureMicPermission() async -> Bool {
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

    private func ensureSystemSpeechPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            errorMessage = "请在系统设置中开启语音识别权限"
            return false
        }
        return await ensureMicPermission()
    }

    // MARK: - 录音与语音转录（系统实时识别 / 自定义 STT API）

    func startRecording(onUpdate: @escaping (String) -> Void) async {
        stopSpeaking()
        errorMessage = nil
        sttUploadTask?.cancel()
        sttUploadTask = nil
        isTranscribing = false

        if isCustomSTTEnabled {
            await startCustomSTTRecording(onUpdate: onUpdate)
        } else {
            await startSystemSpeechRecording(onUpdate: onUpdate)
        }
    }

    private func startSystemSpeechRecording(onUpdate: @escaping (String) -> Void) async {
        guard await ensureSystemSpeechPermissions() else { return }
        stopRecordingInternal(discardCustomFile: true)

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
                            self.stopRecordingInternal(discardCustomFile: true)
                        }
                    }
                    if error != nil && self.isRecording {
                        self.stopRecordingInternal(discardCustomFile: true)
                    }
                }
            }
        } catch {
            errorMessage = "启动录音失败：\(error.localizedDescription)"
            stopRecordingInternal(discardCustomFile: true)
        }
    }

    private func startCustomSTTRecording(onUpdate: @escaping (String) -> Void) async {
        guard sttConfig.resolvedEndpointURL != nil else {
            errorMessage = "自定义 STT 地址格式无效，请在「语音设置」中检查"
            return
        }
        guard await ensureMicPermission() else { return }
        stopRecordingInternal(discardCustomFile: true)

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agy_stt_\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 32000
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                errorMessage = "无法启动音频录制"
                return
            }

            audioRecorder = recorder
            recordedAudioURL = fileURL
            recordStartTime = Date()
            onLiveUpdate = onUpdate
            transcript = ""
            levels = Array(repeating: 0.14, count: 32)
            isRecording = true

            meterTimer?.invalidate()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording, let rec = self.audioRecorder else { return }
                    rec.updateMeters()
                    let power = rec.averagePower(forChannel: 0) // -160 .. 0 dB
                    let clamped = max(-52.0, min(-4.0, Double(power)))
                    let norm = CGFloat((clamped + 52.0) / 48.0)
                    self.levels.removeFirst()
                    self.levels.append(max(0.12, min(1.0, norm)))
                }
            }
        } catch {
            errorMessage = "启动录音失败：\(error.localizedDescription)"
            stopRecordingInternal(discardCustomFile: true)
        }
    }

    /// 取消当前录音或正在进行的云端转录
    func cancelRecording() {
        sttUploadTask?.cancel()
        sttUploadTask = nil
        isTranscribing = false
        stopRecordingInternal(discardCustomFile: true)
    }

    /// 结束录音：系统模式直接返回实时文本；自定义 STT 模式异步上传转录并回调 onUpdate
    @discardableResult
    func stopRecording() -> String {
        if audioRecorder != nil {
            let fileURL = recordedAudioURL
            let callback = onLiveUpdate
            let elapsed = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
            stopRecordingInternal(discardCustomFile: false)

            guard let fileURL else { return "" }
            if elapsed < 0.25 {
                try? FileManager.default.removeItem(at: fileURL)
                return ""
            }

            let cfg = sttConfig
            let key = sttAPIKey
            isTranscribing = true
            sttUploadTask?.cancel()
            sttUploadTask = Task { [weak self] in
                defer {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                guard let self else { return }
                do {
                    let text = try await self.transcribeAudioFile(fileURL, config: cfg, apiKey: key)
                    guard !Task.isCancelled else { return }
                    self.isTranscribing = false
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        self.transcript = clean
                        callback?(clean)
                    } else {
                        self.errorMessage = "未识别到语音内容"
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.isTranscribing = false
                    self.errorMessage = "语音转录失败：\(error.localizedDescription)"
                }
            }
            return ""
        }

        let final = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopRecordingInternal(discardCustomFile: true)
        return final
    }

    /// 供「语音设置」页面直接测试当前自定义 STT 配置：停止当前测试录音并返回结果与耗时
    func stopRecordingAndTranscribeForTest(config: CustomSTTConfig, apiKey: String) async -> (text: String?, latencyMs: Int, error: String?) {
        let fileURL = recordedAudioURL
        let elapsed = recordStartTime.map { Date().timeIntervalSince($0) } ?? 0
        stopRecordingInternal(discardCustomFile: false)
        guard let fileURL else { return (nil, 0, "没有录音文件") }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard elapsed >= 0.25 else { return (nil, 0, "录音时间过短，请至少说 1 秒") }

        let t0 = Date()
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let text = try await transcribeAudioFile(fileURL, config: config, apiKey: apiKey)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), ms, nil)
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return (nil, ms, error.localizedDescription)
        }
    }

    /// 开始仅录音不依赖全局 mode 的测试录音（供 VoiceSettingsSheet 测试自定义 STT）
    func startTestAudioCapture() async -> Bool {
        stopSpeaking()
        errorMessage = nil
        guard await ensureMicPermission() else { return false }
        stopRecordingInternal(discardCustomFile: true)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("agy_stt_test_\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 32000
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else { return false }
            audioRecorder = recorder
            recordedAudioURL = fileURL
            recordStartTime = Date()
            levels = Array(repeating: 0.14, count: 32)
            isRecording = true
            return true
        } catch {
            errorMessage = "启动测试录音失败：\(error.localizedDescription)"
            return false
        }
    }

    private func transcribeAudioFile(_ fileURL: URL, config: CustomSTTConfig, apiKey: String) async throws -> String {
        guard let url = config.resolvedEndpointURL else {
            throw NSError(domain: "AgySTT", code: -1, userInfo: [NSLocalizedDescriptionKey: "STT 接口地址无效"])
        }
        let audioData = try Data(contentsOf: fileURL)
        guard !audioData.isEmpty else {
            throw NSError(domain: "AgySTT", code: -2, userInfo: [NSLocalizedDescriptionKey: "录音数据为空"])
        }

        let boundary = "AgyBoundary-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        let modelName = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        appendField("model", modelName.isEmpty ? "whisper-1" : modelName)
        appendField("response_format", "json")

        let lang = config.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lang.isEmpty && lang.lowercased() != "auto" {
            appendField("language", lang)
        }
        let prompt = config.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            appendField("prompt", prompt)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty {
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body

        let (data, resp) = try await httpSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "AgySTT", code: -3, userInfo: [NSLocalizedDescriptionKey: "无网络响应"])
        }
        if http.statusCode >= 400 {
            let msg = Self.extractAPIError(data: data, statusCode: http.statusCode)
            throw NSError(domain: "AgySTT", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let text = obj["text"] as? String { return text }
            if let text = obj["transcript"] as? String { return text }
            if let res = obj["result"] as? [String: Any], let text = res["text"] as? String { return text }
        }
        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        return ""
    }

    private func stopRecordingInternal(discardCustomFile: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil

        meterTimer?.invalidate()
        meterTimer = nil
        if let rec = audioRecorder {
            if rec.isRecording { rec.stop() }
            audioRecorder = nil
        }
        if discardCustomFile, let u = recordedAudioURL {
            try? FileManager.default.removeItem(at: u)
        }
        recordedAudioURL = nil
        recordStartTime = nil

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

    // MARK: - TTS 朗读（系统 AVSpeechSynthesizer / 自定义 OpenAI 兼容 TTS 分段预取流式播放）

    func toggleSpeak(text: String, itemId: UUID) {
        if speakingItemId == itemId || loadingTTSItemId == itemId {
            stopSpeaking()
            return
        }
        speak(text: text, itemId: itemId)
    }

    func speak(text: String, itemId: UUID) {
        stopSpeaking()
        errorMessage = nil
        let cleaned = Self.stripMarkdown(text)
        guard !cleaned.isEmpty else { return }

        if isCustomTTSEnabled {
            speakWithCustomTTS(cleanedText: cleaned, itemId: itemId, config: ttsConfig, apiKey: ttsAPIKey)
        } else {
            speakWithSystemTTS(cleanedText: cleaned, itemId: itemId)
        }
    }

    private func speakWithSystemTTS(cleanedText: String, itemId: UUID) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {}

        let utterance = AVSpeechUtterance(string: cleanedText)
        let hasChinese = cleanedText.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: hasChinese ? "zh-CN" : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        loadingTTSItemId = nil
        speakingItemId = itemId
        synthesizer.speak(utterance)
    }

    private func speakWithCustomTTS(cleanedText: String, itemId: UUID, config: CustomTTSConfig, apiKey: String) {
        ttsEpoch &+= 1
        let myEpoch = ttsEpoch
        loadingTTSItemId = itemId
        speakingItemId = nil

        let chunks = Self.splitIntoSpeechChunks(cleanedText, maxChars: 340)
        guard !chunks.isEmpty else {
            loadingTTSItemId = nil
            return
        }

        ttsTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Self.activatePlaybackSession()
                var nextFetch: Task<Data, Error>? = Task {
                    try await self.fetchTTSAudio(text: chunks[0], config: config, apiKey: apiKey)
                }

                for idx in chunks.indices {
                    guard !Task.isCancelled, self.ttsEpoch == myEpoch else {
                        nextFetch?.cancel()
                        return
                    }
                    let audioData = try await nextFetch!.value
                    guard !Task.isCancelled, self.ttsEpoch == myEpoch else { return }

                    // 在播放当前段的同时后台预取下一段，消除段间停顿
                    if idx + 1 < chunks.count {
                        let nextChunk = chunks[idx + 1]
                        nextFetch = Task {
                            try await self.fetchTTSAudio(text: nextChunk, config: config, apiKey: apiKey)
                        }
                    } else {
                        nextFetch = nil
                    }

                    if idx == 0 {
                        self.loadingTTSItemId = nil
                        self.speakingItemId = itemId
                    }
                    try await self.playAudioData(audioData, epoch: myEpoch)
                }

                if self.ttsEpoch == myEpoch {
                    self.loadingTTSItemId = nil
                    self.speakingItemId = nil
                }
            } catch {
                guard !Task.isCancelled, self.ttsEpoch == myEpoch else { return }
                self.loadingTTSItemId = nil
                self.speakingItemId = nil
                if config.fallbackToSystem {
                    self.errorMessage = "自定义 TTS 异常（\(error.localizedDescription)），已回退系统朗读"
                    self.speakWithSystemTTS(cleanedText: cleanedText, itemId: itemId)
                } else {
                    self.errorMessage = "自定义 TTS 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 供「语音设置」页试听当前 TTS 配置（返回耗时与错误，不自动静默吞错）
    func testCustomTTS(sampleText: String, config: CustomTTSConfig, apiKey: String) async -> (ok: Bool, latencyMs: Int, error: String?) {
        stopSpeaking()
        ttsEpoch &+= 1
        let myEpoch = ttsEpoch
        let t0 = Date()
        do {
            let data = try await fetchTTSAudio(text: sampleText, config: config, apiKey: apiKey)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            try Self.activatePlaybackSession()
            let testId = UUID()
            speakingItemId = testId
            ttsTask = Task { [weak self] in
                guard let self else { return }
                try? await self.playAudioData(data, epoch: myEpoch)
                if self.ttsEpoch == myEpoch {
                    self.speakingItemId = nil
                }
            }
            return (true, ms, nil)
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            return (false, ms, error.localizedDescription)
        }
    }

    private func fetchTTSAudio(text: String, config: CustomTTSConfig, apiKey: String) async throws -> Data {
        guard let url = config.resolvedEndpointURL else {
            throw NSError(domain: "AgyTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "TTS 接口地址无效"])
        }
        let modelName = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceName = config.voice.trimmingCharacters(in: .whitespacesAndNewlines)
        let fmt = config.responseFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload: [String: Any] = [
            "model": modelName.isEmpty ? "tts-1" : modelName,
            "input": text,
            "voice": voiceName.isEmpty ? "alloy" : voiceName,
            "response_format": fmt.isEmpty ? "mp3" : fmt,
            "speed": max(0.25, min(4.0, config.speed))
        ]
        let instr = config.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instr.isEmpty {
            payload["instructions"] = instr
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 40
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty {
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await httpSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "AgyTTS", code: -2, userInfo: [NSLocalizedDescriptionKey: "无网络响应"])
        }
        if http.statusCode >= 400 {
            let msg = Self.extractAPIError(data: data, statusCode: http.statusCode)
            throw NSError(domain: "AgyTTS", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        guard data.count > 64 else {
            throw NSError(domain: "AgyTTS", code: -3, userInfo: [NSLocalizedDescriptionKey: "返回的音频数据为空"])
        }
        // 某些兼容代理即使 200 也可能返回 JSON 错误体
        if let ctype = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           ctype.contains("application/json") {
            let msg = Self.extractAPIError(data: data, statusCode: http.statusCode)
            throw NSError(domain: "AgyTTS", code: -4, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    private func playAudioData(_ data: Data, epoch: Int) async throws {
        guard ttsEpoch == epoch else { return }
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if self.ttsEpoch != epoch {
                cont.resume()
                return
            }
            self.audioPlayerContinuation = cont
            if !player.play() {
                self.audioPlayerContinuation = nil
                cont.resume()
            }
        }
    }

    private static func activatePlaybackSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
    }

    func stopSpeaking() {
        ttsEpoch &+= 1
        ttsTask?.cancel()
        ttsTask = nil
        if let p = audioPlayer {
            p.delegate = nil
            p.stop()
            audioPlayer = nil
        }
        if let cont = audioPlayerContinuation {
            audioPlayerContinuation = nil
            cont.resume()
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        loadingTTSItemId = nil
        speakingItemId = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.audioPlayer === player {
                self.audioPlayer = nil
                let cont = self.audioPlayerContinuation
                self.audioPlayerContinuation = nil
                cont?.resume()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            if self.audioPlayer === player {
                self.audioPlayer = nil
                let cont = self.audioPlayerContinuation
                self.audioPlayerContinuation = nil
                cont?.resume()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingItemId = nil }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingItemId = nil }
    }

    // MARK: - 文本清洗、句级切片与错误提取

    private static func extractAPIError(data: Data, statusCode: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty {
                return String(msg.prefix(160))
            }
            if let msg = obj["error"] as? String, !msg.isEmpty {
                return String(msg.prefix(160))
            }
            if let msg = obj["message"] as? String, !msg.isEmpty {
                return String(msg.prefix(160))
            }
        }
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return String(s.prefix(140))
        }
        return "HTTP \(statusCode)"
    }

    private static func splitIntoSpeechChunks(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        let delimiters: Set<Character> = ["。", "！", "？", ".", "!", "?", ";", "；", "\n"]
        var chunks: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if current.count >= maxChars || (current.count >= maxChars / 2 && delimiters.contains(ch)) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { chunks.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            if let last = chunks.last, last.count + tail.count < maxChars + 80 {
                chunks[chunks.count - 1] = last + " " + tail
            } else {
                chunks.append(tail)
            }
        }
        return chunks
    }

    private static func stripMarkdown(_ src: String) -> String {
        var s = src
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
        return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
    }
}
