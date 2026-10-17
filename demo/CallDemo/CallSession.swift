import SwiftUI

struct Caption: Identifiable, Equatable {
    enum Who { case ta, me }
    let id = UUID()
    let who: Who
    var text: String
    var isAction = false     // （动作）：上屏不念
    var typed = false
}

/// 照片档的表情。**两边要一起改**：模型那边能写的标签 = 这张表（02 第 3 节）。
enum Face: String, CaseIterable {
    case calm = "平静", smile = "笑", shy = "害羞", tease = "坏笑", soft = "心疼"
    var imageName: String {
        switch self {
        case .calm:  "face_calm"
        case .smile: "face_smile"
        case .shy:   "face_shy"
        case .tease: "face_tease"
        case .soft:  "face_soft"
        }
    }
}

enum Stage: String { case glow, photo }

@MainActor
final class CallSession: ObservableObject {
    @Published var active = false
    @Published var camera: CameraChoice = .unchosen
    @Published var face: Face = .calm
    @Published var captions: [Caption] = []
    @Published var hearing = ""            // 你正在说的灰字，只给你看
    @Published var speaking = false
    @Published var thinking = false
    @Published var seenFrame: UIImage?     // 「ta 看到的」，亮 5 秒
    // 三个开关都记在 UserDefaults，下一通还是你上次选的。
    @Published var stage = Stage(rawValue: UserDefaults.standard.string(forKey: "callVideoStage") ?? "") ?? .glow {
        didSet { UserDefaults.standard.set(stage.rawValue, forKey: "callVideoStage") }
    }
    @Published var followUp = UserDefaults.standard.object(forKey: "callFollowUp") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followUp, forKey: "callFollowUp"); followUpChanged() }
    }
    private var lastLens = UserDefaults.standard.string(forKey: "callCameraLens") ?? CameraChoice.front.rawValue {
        didSet { UserDefaults.standard.set(lastLens, forKey: "callCameraLens") }
    }

    let cam = Camera()
    private let voice = Voice()
    private let ears = Ears()
    private var viaCallKit = false
    private var typedQueue: [String] = []
    private var followTask: Task<Void, Never>?
    private var seenClear: Task<Void, Never>?
    private var turnGen = 0
    private var followStep = 0
    // CallKit 那条路上，「权限问完」和「系统交出音频」谁先到不一定；两样都齐了才开。
    private var permsOK = false
    private var audioReady = false
    private var audioUp = false
    private var audioTries = 0

    init() {
        #if DEBUG
        Self.assertMarkerParser()
        #endif
    }

    // MARK: 接通 / 挂断

    func start(viaCallKit: Bool) {
        guard !active else { return }
        self.viaCallKit = viaCallKit
        // 上一通留下的东西全清掉 —— 尤其是打字队列，不然上一通没念的字会在这一通冒出来。
        captions = []; hearing = ""; camera = .unchosen; face = .calm
        typedQueue = []; followStep = 0; thinking = false; seenFrame = nil
        permsOK = false; audioUp = false; audioTries = 0
        audioReady = !viaCallKit       // 自己打的不用等系统
        active = true
        Task {
            guard await Ears.askPermissions() else {
                captions.append(Caption(who: .ta, text: "（要麦克风和语音识别权限才能打）", isAction: true))
                return
            }
            guard active else { return }
            permsOK = true
            if !viaCallKit { AudioRig.shared.activateSelf() }
            bringUpAudioIfReady()
        }
    }

    /// 系统 didActivate。可能比权限弹窗先回来，也可能晚，所以只记一笔、两样齐了再开。
    func audioActivatedByCallKit() {
        guard active else { return }
        audioReady = true
        bringUpAudioIfReady()
    }

    private func bringUpAudioIfReady() {
        guard active, permsOK, audioReady, !audioUp else { return }
        guard AudioRig.shared.start() else {
            // 刚接通那一下系统可能还没把音频交稳，engine 起不来。别就这么静音着：
            // 隔一会儿再试两次，还不行就上屏说一声，不然你只会觉得 ta 不理你。
            audioTries += 1
            if audioTries <= 2 {
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    bringUpAudioIfReady()
                }
            } else {
                captions.append(Caption(who: .ta, text: "（声音没起来，挂了重打一次）", isAction: true))
            }
            return
        }
        audioUp = true
        ears.onPartial = { [weak self] t in self?.hearing = t; self?.cancelFollowUp() }
        ears.onFinal = { [weak self] t in
            guard let self else { return }
            self.hearing = ""
            if t.isEmpty {
                // 坑 1.6：咳一声是空的。不算一句 —— 但它刚才那下 onPartial 把接话取消了，这里要接回去。
                // 只在被取消过时接回；识别任务每分钟超时也会走到这，不能每次都把倒计时重置掉。
                if !self.speaking && !self.thinking && (self.followTask?.isCancelled ?? true) { self.armFollowUp() }
            } else {
                self.herTurn(t, typed: false)
            }
        }
        ears.start()
        runTurn(Turn(kind: .connected, text: "", sight: .notChosen))
    }

    func hangUp(fromCallKit: Bool = false) {
        guard active else { return }   // App 里按挂断 → CallKit 回调 onEnd 又进来一次
        turnGen += 1
        followTask?.cancel()
        seenClear?.cancel()
        typedQueue = []
        thinking = false
        voice.stop()
        ears.stop()
        cam.stop()
        AudioRig.shared.stop(deactivate: !viaCallKit)
        audioUp = false
        if viaCallKit && !fromCallKit { Ringer.shared.endFromApp() }
        active = false
    }

    // MARK: 镜头

    func choose(_ c: CameraChoice) {
        camera = c
        switch c {
        case .front: cam.use(.front); lastLens = c.rawValue
        case .back:  cam.use(.back);  lastLens = c.rawValue
        case .off, .unchosen: cam.stop()
        }
    }

    /// 关了再开：回到上次那颗镜头，不要写死前置（坑 1.3）。
    func toggleCamera() {
        if camera == .front || camera == .back { choose(.off) }
        else { choose(CameraChoice(rawValue: lastLens) ?? .front) }
    }

    /// 翻转也走 choose —— 绕过它，lastLens 就不更新了。
    func flip() { choose(camera == .front ? .back : .front) }

    // MARK: 一轮

    func send(typed text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if speaking || thinking { typedQueue.append(t) }   // ta 在说就先排着
        else { herTurn(t, typed: true) }
    }

    private func herTurn(_ text: String, typed: Bool) {
        cancelFollowUp()
        followStep = 0                  // 你一开口，间隔从头算
        captions.append(Caption(who: .me, text: text, typed: typed))
        runTurn(Turn(kind: typed ? .typed : .spoke, text: text, sight: currentSight()))
    }

    private func currentSight() -> Sight {
        switch camera {
        case .unchosen: return .notChosen
        case .off:      return .cameraOff
        case .front, .back:
            guard let shot = cam.pickFrame() else { return .noFrame }
            showSeen(shot.image)
            return .frame(shot.image, pinned: shot.pinned)
        }
    }

    private func showSeen(_ img: UIImage) {
        seenFrame = img
        seenClear?.cancel()
        seenClear = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { seenFrame = nil } }
    }

    private func runTurn(_ turn: Turn) {
        turnGen += 1
        let gen = turnGen
        thinking = true
        Task {
            let raw = await MockBrain.reply(to: turn)
            guard gen == turnGen, active else { return }
            thinking = false
            await play(raw, gen: gen)
            guard gen == turnGen, active else { return }
            if let next = typedQueue.first {
                typedQueue.removeFirst()
                herTurn(next, typed: true)
            } else {
                armFollowUp()
            }
        }
    }

    /// 拆一条回复：〔表情〕换照片，（动作）上屏不念，其余逐句念。
    private func play(_ raw: String, gen: Int) async {
        speaking = true
        ears.pause()
        hearing = ""
        defer { speaking = false; if active { ears.resume() } }

        face = .calm                // 每轮从「看着你」开始；ta 写了标签才换（02 第 3 节）
        for seg in Self.segments(raw) {
            guard gen == turnGen, active else { return }
            switch seg {
            case .face(let f):
                face = f            // 只在标签处换；不自动切「说话脸」（坑 2.3）
            case .action(let a):
                captions.append(Caption(who: .ta, text: a, isAction: true))
            case .say(let s):
                captions.append(Caption(who: .ta, text: s))
                Ringer.shared.caption(s)
                await voice.speak(s)
            }
        }
    }

    enum Segment { case face(Face), action(String), say(String) }

    /// 只认闭合的标记；没闭合的半截先藏起来，避免流式输出把动作念出来。
    static func segments(_ raw: String) -> [Segment] {
        var out: [Segment] = []
        var buf = ""
        var i = raw.startIndex
        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.say(t)) }
            buf = ""
        }
        while i < raw.endIndex {
            let ch = raw[i]
            if ch == "〔" || ch == "（" {
                let next = raw[raw.index(after: i)...].firstIndex { $0 == "〔" || $0 == "（" } ?? raw.endIndex
                // 没闭合的括号：只吞到下一个标记开头（或结尾），别把后面整段话连同完整的标记一起丢掉。
                guard let close = raw[i..<next].firstIndex(of: ch == "〔" ? "〕" : "）") else {
                    flush()
                    i = next
                    continue
                }
                flush()
                let inner = String(raw[raw.index(after: i)..<close])
                if ch == "〔" {
                    if let f = Face(rawValue: inner) { out.append(.face(f)) }   // 不认识的标签直接吞掉，别上屏
                } else {
                    out.append(.action(inner))
                }
                i = raw.index(after: close)
                continue
            }
            buf.append(ch)
            i = raw.index(after: i)
        }
        flush()
        return out
    }

    #if DEBUG
    private static func assertMarkerParser() {
        let spoken = segments("你好（低头").compactMap { segment -> String? in
            if case .say(let text) = segment { return text }
            return nil
        }
        assert(spoken == ["你好"], "未闭合的动作标记不能进入 TTS")
        let rest = segments("你好（低头〔笑〕我在。").compactMap { segment -> String? in
            if case .say(let text) = segment { return text }
            return nil
        }
        assert(rest == ["你好", "我在。"], "没闭合的括号不能吞掉后面的话")
    }
    #endif

    // MARK: 你安静时我接话（01 第 7 节）

    private static let followUpDelays: [UInt64] = [4, 7, 12, 20, 32, 50]

    private func armFollowUp() {
        followTask?.cancel()
        guard followUp else { return }
        let wait = followStep < Self.followUpDelays.count ? Self.followUpDelays[followStep] : 60
        followTask = Task {
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            guard !Task.isCancelled, followUp, active, !speaking, !thinking, hearing.isEmpty else { return }
            followStep += 1
            // demo 不花钱所以不设上限；接真模型时每次都是一整轮生成，记得封顶（坑 1.7）。
            runTurn(Turn(kind: .silence, text: "", sight: currentSight()))
            // 这一轮念完，runTurn 会再 armFollowUp，间隔往后挪一档
        }
    }

    private func cancelFollowUp() { followTask?.cancel() }

    private func followUpChanged() {
        if followUp { if !speaking && !thinking { armFollowUp() } } else { cancelFollowUp() }
    }
}
