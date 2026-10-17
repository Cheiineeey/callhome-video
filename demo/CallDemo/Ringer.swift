import AVFoundation
import CallKit
import UIKit

/// 本地模拟「ta 打过来」。真项目里这一步由 VoIP 推送触发（链路见
/// ios-app-where-it-breaks/02-calls），收到推送后做的事跟这里一模一样：当场 reportNewIncomingCall。
///
/// demo 不需要推送、不需要付费账号：点按钮 → 5 秒后响 → 这 5 秒里可以锁屏，看锁屏全屏来电。
final class Ringer: NSObject, CXProviderDelegate {
    static let shared = Ringer()

    /// 横幅想显示 ta 的照片：通讯录里建一张卡片，邮箱填这个，配上 ta 的照片（05 第 2 节）。
    static let taEmail = "ta@example.com"

    var onAnswer: (() -> Void)?
    var onAudioActivated: (() -> Void)?
    var onEnd: (() -> Void)?
    var onRingOver: (() -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private(set) var current: UUID?
    private var answered = false

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        // 不声明 .emailAddress，系统根本不会拿 handle 去通讯录配人（坑 5.1）。
        config.supportedHandleTypes = [.generic, .emailAddress]
        // 坑 5.2：UIImage(named: "AppIcon") 读不到。用一张普通图，系统只取轮廓。
        config.iconTemplateImageData = UIImage(systemName: "heart.fill")?.pngData()
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func ringIn(after seconds: Double) {
        // 锁屏后 app 会被挂起；借一点后台时间撑过这 5 秒。
        // 任务号装进盒子里：闭包抓的是盒子，不是一个之后才被赋值的 var（Swift 6 会警告）。
        final class Box: @unchecked Sendable { var id: UIBackgroundTaskIdentifier = .invalid }
        let bg = Box()
        bg.id = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            report()
            UIApplication.shared.endBackgroundTask(bg.id)
        }
    }

    private func report() {
        let uuid = UUID()
        current = uuid
        answered = false
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .emailAddress, value: Self.taEmail)
        update.hasVideo = true
        // 响铃时不设 localizedCallerName：它会盖掉通讯录名字，你看不出到底配上没有。
        AudioRig.shared.configureCategory()
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            // 报失败（勿扰、已有通话……）也要把 current 清掉，不然之后的字幕和挂断都对着一通不存在的电话。
            if let error { print("reportNewIncomingCall:", error); self?.current = nil; self?.ringOver() }
        }
        // 坑 5.3 的第 4 层：响铃到期没人挂。这里 30 秒不接就自己挂成未接。
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.current == uuid, !self.answered else { return }
            self.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
            self.current = nil
            self.ringOver()
        }
    }

    /// app 里按挂断：走 CXEndCallAction，让系统界面一起收。
    func endFromApp() {
        guard let uuid = current else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }

    // MARK: 横幅字幕（05 第 3 节）

    private var lastCaptionAt = Date.distantPast
    private var pendingCaption: String?
    private var captionFlush: DispatchWorkItem?

    /// 节流 1.2 秒，但**留尾巴**：被拦掉的最后一句过一会儿补上，不然横幅停在倒数第二句。
    func caption(_ text: String) {
        guard current != nil, answered else { return }
        let gap = Date().timeIntervalSince(lastCaptionAt)
        if gap >= 1.2 {
            push(text)
        } else {
            pendingCaption = text
            captionFlush?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let t = self.pendingCaption else { return }
                self.push(t)
            }
            captionFlush = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (1.2 - gap), execute: item)
        }
    }

    private func push(_ text: String) {
        guard let uuid = current else { return }
        lastCaptionAt = Date()
        pendingCaption = nil
        let u = CXCallUpdate()
        u.localizedCallerName = text      // 只设这一项；没设的 = 不变
        provider.reportCall(with: uuid, updated: u)
    }

    private func ringOver() {
        captionFlush?.cancel()
        pendingCaption = nil
        lastCaptionAt = .distantPast
        DispatchQueue.main.async { self.onRingOver?() }
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        current = nil
        ringOver()
        onEnd?()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        answered = true
        action.fulfill()
        onAnswer?()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        current = nil
        ringOver()
        onEnd?()
    }

    /// 系统把音频会话交给你了 —— 这时候才开 engine，早了没声音。
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onAudioActivated?()
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
