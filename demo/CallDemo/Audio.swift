import AVFoundation
import Speech

/// 一台 AVAudioEngine 同时管「ta 的声音出去」和「你的声音进来」。
///
/// 为什么不用 AVSpeechSynthesizer.speak() 直接念：
/// 光档要读**正在播放的那段声音**的音量。声音必须从你自己的播放器出（02 第 2 节），
/// 这跟真项目里「TTS 回来的 mp3 本地播」是同一个形状 —— 只是这里的 mp3 换成了系统语音。
final class AudioRig {
    static let shared = AudioRig()

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let playFormat = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!

    /// 0...1，光档读它。只在音频线程写，主线程读一个 Float，够用。
    private(set) var level: Float = 0
    var onMicBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var running = false

    /// CallKit 那条路：类别在报来电前配好，**不要自己 setActive**，等系统 didActivate。
    func configureCategory() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .voiceChat,
                           options: [.defaultToSpeaker, .allowBluetooth])
    }

    /// 自己打出去那条路：自己激活。
    func activateSelf() {
        configureCategory()
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func start() {
        guard !running else { return }
        // 第二通电话再进来时 player 还挂在 engine 上；重复 attach 会抛异常。
        if player.engine == nil { engine.attach(player) }
        // 回声消除挂在 engine 的 IO 上：开了它，ta 的声音就不会被麦克风当成你在说话。
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)

        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: micFormat) { [weak self] buf, _ in
            self?.onMicBuffer?(buf)
        }
        player.installTap(onBus: 0, bufferSize: 1024, format: playFormat) { [weak self] buf, _ in
            self?.meter(buf)
        }
        engine.prepare()
        do { try engine.start(); running = true } catch { print("engine start:", error) }
        repinSpeaker()
    }

    /// `deactivate`：自己打的那条路要自己交还音频会话（别人的音乐才能接着放）；
    /// CallKit 那条路系统会收，别插手。
    func stop(deactivate: Bool) {
        guard running else { return }
        player.stop()
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
        if deactivate {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// 坑 2.1：开摄像头会把声音甩回听筒。每次动过 AVCaptureSession 之后都再钉一次扬声器。
    func repinSpeaker() {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
    }

    private func meter(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(buf.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        let x = min(max((db + 50) / 50, 0), 1)
        level = x * x               // 平方：小声几乎不动，大声才鼓起来
    }
}

/// ta 的嘴。系统语音渲染成 PCM → 转成播放格式 → 排进 player。
final class Voice {
    private let synth = AVSpeechSynthesizer()
    private let rig = AudioRig.shared
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?

    /// 念完（最后一块 buffer 被播放器吃掉）才返回。
    func speak(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, rig.running else { return }

        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "zh-CN")

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock(); cont = c; lock.unlock()

            var converter: AVAudioConverter?
            var pending = 0
            var finished = false
            let state = NSLock()
            let doneIfIdle = { [weak self] in
                if finished && pending == 0 { self?.resume() }
            }

            synth.write(u) { [weak self] buf in
                guard let self, let pcm = buf as? AVAudioPCMBuffer else { return }
                state.lock(); defer { state.unlock() }
                if pcm.frameLength == 0 { finished = true; doneIfIdle(); return }
                if converter == nil { converter = AVAudioConverter(from: pcm.format, to: self.rig.playFormat) }
                guard let conv = converter, let out = self.convert(pcm, with: conv) else { return }
                pending += 1
                self.rig.player.scheduleBuffer(out) {
                    state.lock(); pending -= 1; doneIfIdle(); state.unlock()
                }
                if !self.rig.player.isPlaying { self.rig.player.play() }
            }
        }
    }

    /// 挂断 / 打断：停掉并让正在等的 speak() 返回。
    func stop() {
        synth.stopSpeaking(at: .immediate)
        rig.player.stop()
        resume()
    }

    private func resume() {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume()
    }

    private func convert(_ pcm: AVAudioPCMBuffer, with conv: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = rig.playFormat.sampleRate / pcm.format.sampleRate
        let cap = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: rig.playFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }   // noDataNow：流式转换，别把转换器关掉
            fed = true
            status.pointee = .haveData
            return pcm
        }
        return err == nil ? out : nil
    }
}

/// 你的耳朵。SFSpeechRecognizer 出灰字幕；停顿 1.2 秒算你说完。
final class Ears {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// ta 说话时 true：不收音、不出灰字。（真项目里这里要接 barge-in，demo 不做。）
    /// 只在主线程改；音频线程读一个 Bool，够用。
    private(set) var paused = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var silence: DispatchWorkItem?
    /// 代数：旧任务晚到的回调一律丢掉（坑 1.5：上一句被拼到这一句前面）。
    private var generation = 0

    static func askPermissions() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func start() {
        AudioRig.shared.onMicBuffer = { [weak self] buf in
            guard let self, !self.paused else { return }
            self.request?.append(buf)
        }
        newUtterance()
    }

    func stop() {
        AudioRig.shared.onMicBuffer = nil
        silence?.cancel()
        task?.cancel()
        request = nil
        task = nil
        generation += 1
        paused = false
    }

    /// ta 开口：连同还没到点的「说完了」一起作废。
    /// 不作废的话，你说了半句、ta 先开口（比如排队的打字），1.2 秒后那半句会冲出去打断 ta。
    func pause() {
        paused = true
        silence?.cancel()
        task?.cancel()
        task = nil
        request = nil
        generation += 1
        latest = ""
    }

    /// ta 说完：开一个干净的新任务。
    func resume() {
        paused = false
        newUtterance()
    }

    /// 每一句开一个新任务（单个任务有一分钟上限，而且每句清零最不容易串）。
    func newUtterance() {
        task?.cancel()
        generation += 1
        let gen = generation
        latest = ""

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                guard gen == self.generation, !self.paused else { return }
                if let text {
                    self.latest = text
                    self.onPartial?(text)
                    self.armSilence(gen)
                }
                // 任务自己结束了（单个任务约一分钟上限、你一直不说话也会超时报错）：
                // 不重开的话，后半通就再也听不见你了，而且没有任何报错。
                // 报错的那种隔半秒再开：识别器不可用时会立刻报错，不隔就原地空转。
                if isFinal { self.finishNow(gen) }
                else if error != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.finishNow(gen) }
                }
            }
        }
    }

    private func finishNow(_ gen: Int) {
        guard gen == generation else { return }
        silence?.cancel()
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        request?.endAudio()
        newUtterance()
        onFinal?(text)
    }

    private func armSilence(_ gen: Int) {
        silence?.cancel()
        // 坑 1.6：咳一声、碰一下桌子 = 空的。空的也交出去（text 为空），由 CallSession 决定当没发生。
        let item = DispatchWorkItem { [weak self] in self?.finishNow(gen) }
        silence = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }
}
