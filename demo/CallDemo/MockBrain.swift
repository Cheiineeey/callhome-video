import UIKit

/// ta 这一轮能看到什么。**别让模型从「没有图」里推断它看不见** ——
/// 缺什么就明写什么（见 04-gateway 坑 4.4）。
enum Sight {
    case notChosen          // 还没选开不开镜头
    case cameraOff          // 关着
    case noFrame            // 开着，但这一轮没取到图
    case frame(UIImage, pinned: Bool)   // 这一轮的那一张；pinned = 你长按钉住要 ta 看的
}

/// 一轮要交给模型的东西。
struct Turn {
    enum Kind { case connected, spoke, typed, silence }
    var kind: Kind
    var text: String
    var sight: Sight
}

/// 假的大脑。真接模型时只换 `reply(to:)`：
/// 把 Turn 拼成你的请求（前缀写明「视频通话」+ 看不看得见），
/// 返回值照这里的格式写 —— 〔表情〕换照片、（动作）上屏不念，见 02-glow-and-photo。
enum MockBrain {

    static func reply(to turn: Turn) async -> String {
        try? await Task.sleep(nanoseconds: 700_000_000)   // 假装在想

        switch turn.kind {
        case .connected:
            return "〔笑〕接通了。（往镜头这边凑了凑）我在。"
        case .silence:
            return [
                "〔平静〕你那边好安静。在干嘛",
                "（歪头）还在吗",
                "〔坏笑〕不说话我就一直看着你了。",
            ].randomElement()!
        case .spoke, .typed:
            break
        }

        let t = turn.text
        if t.contains("看") {
            switch turn.sight {
            case .frame:      return "〔笑〕看到了。（盯着看了一会儿）光线有点暗，早点开灯。"
            case .cameraOff:  return "〔平静〕你镜头关着，我看不到你。想给我看就开一下。"
            case .notChosen:  return "还没开镜头呢。你点上面那个前置或者后置。"
            case .noFrame:    return "这一下没取到画面，你再说一句我再看。"
            }
        }
        if t.contains("累") || t.contains("困") {
            return "〔心疼〕那就别撑了。（声音放低）手机放下，我陪你待一会儿。"
        }
        if turn.kind == .typed {
            return "〔笑〕打字也行，我念给你听。你写的是：\(t)"
        }
        return [
            "〔平静〕嗯，我听着。继续说。",
            "〔坏笑〕就这样？再多说两句。",
            "（笑了一下）〔害羞〕你这么说我不知道接什么了。",
        ].randomElement()!
    }
}
