import SwiftUI
import UIKit

/// 自定义 TTS 朗读模型与 STT 语音转录模型配置页（兼容 OpenAI / 硅基流动 / Groq / Fish Audio / 本地网关）
struct VoiceSettingsSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var speech = SpeechManager.shared
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil

    @State private var tab = 0 // 0 = TTS 朗读, 1 = STT 语音转录

    // TTS 草稿状态
    @State private var ttsDraft = CustomTTSConfig()
    @State private var ttsKey = ""
    @State private var showTTSKey = false
    @State private var sampleText = "你好，这是 Antigravity 自定义语音朗读测试。"
    @State private var testingTTS = false
    @State private var ttsTestStatus: (ok: Bool, text: String)? = nil

    // STT 草稿状态
    @State private var sttDraft = CustomSTTConfig()
    @State private var sttKey = ""
    @State private var showSTTKey = false
    @State private var testingSTTRecording = false
    @State private var testingSTTUploading = false
    @State private var sttTestStatus: (ok: Bool, text: String)? = nil

    @State private var dirty = false

    private struct TTSPreset: Identifiable {
        let id: String
        let title: String
        let baseURL: String
        let model: String
        let voice: String
        let format: String
    }

    private struct STTPreset: Identifiable {
        let id: String
        let title: String
        let baseURL: String
        let model: String
    }

    private static let ttsPresets: [TTSPreset] = [
        TTSPreset(id: "openai-4o", title: "OpenAI 4o-mini-tts", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-tts", voice: "coral", format: "mp3"),
        TTSPreset(id: "openai-tts1", title: "OpenAI tts-1", baseURL: "https://api.openai.com/v1", model: "tts-1", voice: "nova", format: "mp3"),
        TTSPreset(id: "sf-cosy", title: "硅基流动 CosyVoice2", baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/CosyVoice2-0.5B", voice: "FunAudioLLM/CosyVoice2-0.5B:alex", format: "mp3"),
        TTSPreset(id: "sf-fish", title: "硅基流动 FishSpeech", baseURL: "https://api.siliconflow.cn/v1", model: "fishaudio/fish-speech-1.5", voice: "fishaudio/fish-speech-1.5:alex", format: "mp3"),
        TTSPreset(id: "local-kokoro", title: "本地 Edge / Kokoro", baseURL: "http://127.0.0.1:8880/v1", model: "kokoro", voice: "zf_xiaoxiao", format: "mp3")
    ]

    private static let sttPresets: [STTPreset] = [
        STTPreset(id: "openai-4o", title: "OpenAI 4o-transcribe", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe"),
        STTPreset(id: "openai-whisper", title: "OpenAI whisper-1", baseURL: "https://api.openai.com/v1", model: "whisper-1"),
        STTPreset(id: "groq-v3", title: "Groq Whisper V3 Turbo", baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo"),
        STTPreset(id: "sf-sensevoice", title: "硅基流动 SenseVoice", baseURL: "https://api.siliconflow.cn/v1", model: "FunAudioLLM/SenseVoiceSmall")
    ]

    private static let sttLanguages: [(id: String, label: String)] = [
        ("auto", "自动检测"),
        ("zh", "中文 (zh)"),
        ("en", "English (en)"),
        ("ja", "日本語 (ja)"),
        ("ko", "한국어 (ko)")
    ]

    private static let audioFormats = ["mp3", "wav", "aac", "flac"]

    private func closeSelf() {
        if testingSTTRecording {
            speech.cancelRecording()
            testingSTTRecording = false
        }
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("模块", selection: $tab) {
                    Text("朗读模型 (TTS)").tag(0)
                    Text("语音转录 (STT)").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemGroupedBackground))

                if tab == 0 {
                    ttsForm
                } else {
                    sttForm
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("语音服务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        closeSelf()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                            Text("返回")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        saveAll()
                    } label: {
                        Text("保存")
                            .fontWeight(dirty ? .bold : .semibold)
                    }
                }
            }
            .onAppear {
                loadFromManager()
            }
            .onDisappear {
                if testingSTTRecording {
                    speech.cancelRecording()
                    testingSTTRecording = false
                }
            }
        }
    }

    private func loadFromManager() {
        ttsDraft = speech.ttsConfig
        ttsKey = speech.ttsAPIKey
        sttDraft = speech.sttConfig
        sttKey = speech.sttAPIKey
        dirty = false
    }

    private func saveAll() {
        speech.ttsConfig = ttsDraft
        speech.ttsAPIKey = ttsKey
        speech.sttConfig = sttDraft
        speech.sttAPIKey = sttKey
        dirty = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        state.showToast("语音配置已保存")
    }

    // MARK: - Tab 0: TTS 朗读配置

    private var ttsForm: some View {
        Form {
            Section {
                Picker("朗读引擎", selection: $ttsDraft.mode) {
                    ForEach(VoiceProviderMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: ttsDraft.mode) { _ in dirty = true }
            } header: {
                Text("消息朗读引擎")
            } footer: {
                Text(ttsDraft.mode == .system
                     ? "使用 iOS 系统离线语音引擎，零延迟且不消耗额度。"
                     : "兼容所有 OpenAI /v1/audio/speech 协议接口（OpenAI、硅基流动、OneAPI / NewAPI、Fish Audio、Edge-TTS / Kokoro 等），长回复支持句级分段预取无缝连播。")
            }

            if ttsDraft.mode == .custom {
                Section("快捷预设") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.ttsPresets) { p in
                                Button {
                                    ttsDraft.baseURL = p.baseURL
                                    ttsDraft.model = p.model
                                    ttsDraft.voice = p.voice
                                    ttsDraft.responseFormat = p.format
                                    dirty = true
                                } label: {
                                    Text(p.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL 或完整 Speech 接口地址")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("https://api.openai.com/v1", text: $ttsDraft.baseURL)
                            .font(.system(size: 14, design: .monospaced))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: ttsDraft.baseURL) { _ in dirty = true }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key（本地免鉴权服务可留空）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if showTTSKey {
                            TextField("sk-...", text: $ttsKey)
                                .font(.system(size: 13.5, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: ttsKey) { _ in dirty = true }
                        } else {
                            SecureField("sk-...", text: $ttsKey)
                                .font(.system(size: 13.5, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: ttsKey) { _ in dirty = true }
                        }
                        HStack(spacing: 14) {
                            Button {
                                showTTSKey.toggle()
                            } label: {
                                Label(showTTSKey ? "隐藏" : "显示", systemImage: showTTSKey ? "eye.slash" : "eye")
                                    .font(.system(size: 12.5))
                            }
                            .buttonStyle(.borderless)

                            Button {
                                if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                                    ttsKey = s
                                    dirty = true
                                }
                            } label: {
                                Label("粘贴", systemImage: "doc.on.clipboard")
                                    .font(.system(size: 12.5))
                            }
                            .buttonStyle(.borderless)

                            Spacer()

                            if !sttKey.isEmpty && ttsKey.isEmpty {
                                Button("复用 STT Key") {
                                    ttsKey = sttKey
                                    dirty = true
                                }
                                .font(.system(size: 12.5))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("接口与鉴权")
                } footer: {
                    if let resolved = ttsDraft.resolvedEndpointURL?.absoluteString {
                        Text("实际请求端点：\(resolved)")
                    } else {
                        Text("请输入有效的 http:// 或 https:// 地址")
                            .foregroundStyle(.red)
                    }
                }

                Section("模型与音色参数") {
                    HStack {
                        Text("模型 ID")
                            .frame(width: 72, alignment: .leading)
                        TextField("如 gpt-4o-mini-tts / tts-1", text: $ttsDraft.model)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: ttsDraft.model) { _ in dirty = true }
                    }

                    HStack {
                        Text("音色名")
                            .frame(width: 72, alignment: .leading)
                        TextField("如 coral / nova / alloy", text: $ttsDraft.voice)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: ttsDraft.voice) { _ in dirty = true }
                    }

                    Picker("音频格式", selection: $ttsDraft.responseFormat) {
                        ForEach(Self.audioFormats, id: \.self) { fmt in
                            Text(fmt.uppercased()).tag(fmt)
                        }
                    }
                    .onChange(of: ttsDraft.responseFormat) { _ in dirty = true }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("语速")
                            Spacer()
                            Text(String(format: "%.2fx", ttsDraft.speed))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $ttsDraft.speed, in: 0.5...2.0, step: 0.05)
                            .onChange(of: ttsDraft.speed) { _ in dirty = true }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("语气指令（可选，如 gpt-4o-mini-tts 支持）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("例如：自然亲切、播音腔、语速平稳", text: $ttsDraft.instructions)
                            .font(.system(size: 14))
                            .onChange(of: ttsDraft.instructions) { _ in dirty = true }
                    }

                    Toggle("请求失败时自动回退系统朗读", isOn: $ttsDraft.fallbackToSystem)
                        .onChange(of: ttsDraft.fallbackToSystem) { _ in dirty = true }
                }

                Section("试听测试") {
                    TextField("试听文本", text: $sampleText, axis: .vertical)
                        .font(.system(size: 14))
                        .lineLimit(2...4)

                    HStack(spacing: 12) {
                        Button {
                            Task { await runTTSTest() }
                        } label: {
                            HStack(spacing: 6) {
                                if testingTTS {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: "play.circle.fill")
                                }
                                Text(testingTTS ? "合成中…" : "试听当前配置")
                                    .fontWeight(.semibold)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(testingTTS || sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Spacer()

                        if speech.speakingItemId != nil {
                            Button(role: .destructive) {
                                speech.stopSpeaking()
                            } label: {
                                Label("停止", systemImage: "stop.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if let st = ttsTestStatus {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: st.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(st.ok ? Color.green : Color.red)
                            Text(st.text)
                                .font(.system(size: 12.5))
                                .foregroundStyle(st.ok ? Color.secondary : Color.red)
                        }
                    }
                }
            }
        }
    }

    private func runTTSTest() async {
        testingTTS = true
        ttsTestStatus = nil
        let res = await speech.testCustomTTS(sampleText: sampleText, config: ttsDraft, apiKey: ttsKey)
        testingTTS = false
        if res.ok {
            ttsTestStatus = (true, "合成成功并开始播放（首包耗时 \(res.latencyMs) ms）")
        } else {
            ttsTestStatus = (false, res.error ?? "测试失败")
        }
    }

    // MARK: - Tab 1: STT 语音转录配置

    private var sttForm: some View {
        Form {
            Section {
                Picker("转录引擎", selection: $sttDraft.mode) {
                    ForEach(VoiceProviderMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: sttDraft.mode) { _ in dirty = true }
            } header: {
                Text("语音输入转录引擎")
            } footer: {
                Text(sttDraft.mode == .system
                     ? "使用 iOS 原生实时语音听写，边说边出字。"
                     : "兼容所有 OpenAI /v1/audio/transcriptions 协议接口（OpenAI Whisper / 4o-transcribe、Groq Whisper V3 Turbo、硅基流动 SenseVoice、本地 Faster-Whisper 等）。录音采用 16kHz AAC 压缩，4G 下亦极速上传。")
            }

            if sttDraft.mode == .system {
                Section("系统听写语言") {
                    Picker("默认识别语言", selection: $speech.localeId) {
                        Text("简体中文 (zh-CN)").tag("zh-CN")
                        Text("English (en-US)").tag("en-US")
                    }
                }
            } else {
                Section("快捷预设") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.sttPresets) { p in
                                Button {
                                    sttDraft.baseURL = p.baseURL
                                    sttDraft.model = p.model
                                    dirty = true
                                } label: {
                                    Text(p.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Base URL 或完整 Transcriptions 接口地址")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("https://api.openai.com/v1", text: $sttDraft.baseURL)
                            .font(.system(size: 14, design: .monospaced))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: sttDraft.baseURL) { _ in dirty = true }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key（本地免鉴权服务可留空）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if showSTTKey {
                            TextField("sk-... / gsk_...", text: $sttKey)
                                .font(.system(size: 13.5, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: sttKey) { _ in dirty = true }
                        } else {
                            SecureField("sk-... / gsk_...", text: $sttKey)
                                .font(.system(size: 13.5, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onChange(of: sttKey) { _ in dirty = true }
                        }
                        HStack(spacing: 14) {
                            Button {
                                showSTTKey.toggle()
                            } label: {
                                Label(showSTTKey ? "隐藏" : "显示", systemImage: showSTTKey ? "eye.slash" : "eye")
                                    .font(.system(size: 12.5))
                            }
                            .buttonStyle(.borderless)

                            Button {
                                if let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                                    sttKey = s
                                    dirty = true
                                }
                            } label: {
                                Label("粘贴", systemImage: "doc.on.clipboard")
                                    .font(.system(size: 12.5))
                            }
                            .buttonStyle(.borderless)

                            Spacer()

                            if !ttsKey.isEmpty && sttKey.isEmpty {
                                Button("复用 TTS Key") {
                                    sttKey = ttsKey
                                    dirty = true
                                }
                                .font(.system(size: 12.5))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    Text("接口与鉴权")
                } footer: {
                    if let resolved = sttDraft.resolvedEndpointURL?.absoluteString {
                        Text("实际请求端点：\(resolved)")
                    } else {
                        Text("请输入有效的 http:// 或 https:// 地址")
                            .foregroundStyle(.red)
                    }
                }

                Section("转录模型与参数") {
                    HStack {
                        Text("模型 ID")
                            .frame(width: 72, alignment: .leading)
                        TextField("如 whisper-1 / SenseVoiceSmall", text: $sttDraft.model)
                            .font(.system(size: 14, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: sttDraft.model) { _ in dirty = true }
                    }

                    Picker("目标语言", selection: $sttDraft.language) {
                        ForEach(Self.sttLanguages, id: \.id) { opt in
                            Text(opt.label).tag(opt.id)
                        }
                    }
                    .onChange(of: sttDraft.language) { _ in dirty = true }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("上下文提示词 / 专有名词词表（可选）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("如 Antigravity, SwiftUI, MCP, VPS", text: $sttDraft.prompt)
                            .font(.system(size: 14))
                            .onChange(of: sttDraft.prompt) { _ in dirty = true }
                    }
                }

                Section("录音转录测试") {
                    HStack(spacing: 12) {
                        Button {
                            Task { await toggleSTTTest() }
                        } label: {
                            HStack(spacing: 6) {
                                if testingSTTUploading {
                                    ProgressView().scaleEffect(0.75)
                                } else {
                                    Image(systemName: testingSTTRecording ? "stop.circle.fill" : "mic.circle.fill")
                                }
                                Text(testingSTTUploading
                                     ? "正在上传转录…"
                                     : (testingSTTRecording ? "停止并测试转录" : "开始录音测试"))
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(testingSTTRecording ? Color.red : Color.accentColor)
                        }
                        .buttonStyle(.borderless)
                        .disabled(testingSTTUploading)

                        Spacer()

                        if testingSTTRecording {
                            Button("取消") {
                                speech.cancelRecording()
                                testingSTTRecording = false
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.borderless)
                        }
                    }

                    if let st = sttTestStatus {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: st.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(st.ok ? Color.green : Color.red)
                            Text(st.text)
                                .font(.system(size: 13))
                                .foregroundStyle(st.ok ? Color.primary : Color.red)
                        }
                    }
                }
            }
        }
    }

    private func toggleSTTTest() async {
        if testingSTTRecording {
            testingSTTRecording = false
            testingSTTUploading = true
            sttTestStatus = nil
            let res = await speech.stopRecordingAndTranscribeForTest(config: sttDraft, apiKey: sttKey)
            testingSTTUploading = false
            if let text = res.text, !text.isEmpty {
                sttTestStatus = (true, "「\(text)」（耗时 \(res.latencyMs) ms）")
            } else {
                sttTestStatus = (false, res.error ?? "未识别出文本")
            }
        } else {
            sttTestStatus = nil
            let started = await speech.startTestAudioCapture()
            testingSTTRecording = started
        }
    }
}
