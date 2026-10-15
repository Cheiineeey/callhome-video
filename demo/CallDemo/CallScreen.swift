import SwiftUI

/// FaceTime 式布局：满屏是 ta，你的摄像头在小窗；点小窗对调，拖到四角吸附（02 第 5 节）。
struct CallScreen: View {
    @EnvironmentObject var call: CallSession
    @State private var swapped = false
    @State private var pinFlash = false
    @State private var justPinned = false     // 长按松手那一下别再算成「点一下对调」
    @State private var corner: Corner = .topTrailing
    @State private var drag: CGSize = .zero
    @State private var typing = false
    @State private var draft = ""

    enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private var cameraOn: Bool { call.camera == .front || call.camera == .back }

    var body: some View {
        // 外层只用来读安全区；画面那层铺满整屏（含刘海和底部横条），坐标原点是屏幕左上角。
        // 两层分开是因为：铺满的那层 size 和 safeAreaInsets 不在同一个坐标系里，混着用小窗会偏。
        GeometryReader { outer in
            let safe = outer.safeAreaInsets
            ZStack {
                GeometryReader { geo in
                    let full = geo.size
                    let small = CGSize(width: 110, height: 160)
                    ZStack {
                        Color.black
                        // 两块都常驻，只挪位置 —— 摄像头预览因此只有一个 layer。
                        tile(isTa: true, big: !swapped || !cameraOn, full: full, small: small, safe: safe)
                        if cameraOn {
                            tile(isTa: false, big: swapped, full: full, small: small, safe: safe)
                        }
                    }
                }
                .ignoresSafeArea()

                VStack(spacing: 10) {
                    topBar
                    if let img = call.seenFrame { seen(img) }
                    Spacer()
                    if call.camera == .unchosen { cameraChoice }
                    CaptionsView()
                    if typing { typingBar }
                    controls
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        // 镜头关了就回到默认：不然再开镜头时，满屏突然变成你自己。
        .onChange(of: cameraOn) { if !cameraOn { swapped = false } }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: 两块画面

    @ViewBuilder
    private func tile(isTa: Bool, big: Bool, full: CGSize, small: CGSize, safe: EdgeInsets) -> some View {
        let size = big ? full : small
        let pos = big ? CGPoint(x: full.width / 2, y: full.height / 2) : smallCenter(full: full, small: small, safe: safe)
        Group {
            if isTa { TaView() } else { CameraPreview(session: call.cam.session) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: big ? 0 : 14))
        .position(x: pos.x + (big ? 0 : drag.width), y: pos.y + (big ? 0 : drag.height))
        .zIndex(big ? 0 : 1)
        .overlay(Color.white.opacity(!isTa && pinFlash ? 0.6 : 0).allowsHitTesting(false))
        .onTapGesture {
            if justPinned { justPinned = false; return }
            if !big { withAnimation(.spring(duration: 0.35)) { swapped.toggle() } }
        }
        // 长按你那一格 = 钉住这一帧，下一轮优先给 ta（01 第 3 节）。
        // 要 simultaneous：小窗身上还挂着拖动，普通 .gesture 会被拖动吃掉（01 坑 1.4）
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in
            guard !isTa, call.cam.pin() else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            justPinned = true
            pinFlash = true
            withAnimation(.easeOut(duration: 0.4).delay(0.06)) { pinFlash = false }
        })
        // 大的那块不接拖动：用 mask 关掉，而不是传一个可选手势。
        .gesture(DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { v in
                let p = CGPoint(x: pos.x + v.translation.width, y: pos.y + v.translation.height)
                withAnimation(.spring(duration: 0.35)) {
                    corner = p.x < full.width / 2
                        ? (p.y < full.height / 2 ? .topLeading : .bottomLeading)
                        : (p.y < full.height / 2 ? .topTrailing : .bottomTrailing)
                    drag = .zero
                }
            }, including: big ? .subviews : .all)
    }

    private func smallCenter(full: CGSize, small: CGSize, safe: EdgeInsets) -> CGPoint {
        let m: CGFloat = 16
        let left = m + small.width / 2, right = full.width - m - small.width / 2
        let top = safe.top + 60 + small.height / 2, bottom = full.height - safe.bottom - 300 + small.height / 2
        switch corner {
        case .topLeading:     return CGPoint(x: left, y: top)
        case .topTrailing:    return CGPoint(x: right, y: top)
        case .bottomLeading:  return CGPoint(x: left, y: bottom)
        case .bottomTrailing: return CGPoint(x: right, y: bottom)
        }
    }

    // MARK: 上面

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("ta").font(.headline)
                Text(call.speaking ? "在说" : call.thinking ? "在想" : "在听")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("ta 的画面", selection: $call.stage) {
                    Label("光", systemImage: "circle.hexagongrid").tag(Stage.glow)
                    Label("照片", systemImage: "photo").tag(Stage.photo)
                }
                Toggle("你安静时我接话", isOn: $call.followUp)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
        }
        .foregroundStyle(.white)
    }

    private func seen(_ img: UIImage) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 64, height: 86).clipShape(RoundedRectangle(cornerRadius: 8))
                Text("ta 看到的").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .transition(.opacity)
    }

    // MARK: 接通时先问开不开镜头（01 第 1 节：不自动开）

    private var cameraChoice: some View {
        VStack(spacing: 12) {
            Text("开镜头给 ta 看吗").font(.subheadline)
            HStack(spacing: 10) {
                choice("不开", .off)
                choice("前置", .front)
                choice("后置", .back)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func choice(_ title: String, _ c: CameraChoice) -> some View {
        Button(title) { call.choose(c) }
            .buttonStyle(.bordered)
            .tint(.white)
    }

    // MARK: 下面

    private var typingBar: some View {
        HStack {
            TextField("打字给 ta", text: $draft)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(sendDraft)
            Button("发", action: sendDraft).disabled(draft.isEmpty)
        }
    }

    private func sendDraft() {
        call.send(typed: draft)
        draft = ""
    }

    private var controls: some View {
        HStack(spacing: 22) {
            round(cameraOn ? "video.fill" : "video.slash.fill", on: cameraOn) { call.toggleCamera() }
            round("arrow.triangle.2.circlepath.camera", on: false) { call.flip() }
                .disabled(!cameraOn).opacity(cameraOn ? 1 : 0.35)
            round("keyboard", on: typing) { withAnimation { typing.toggle() } }
            Button { call.hangUp() } label: {
                Image(systemName: "phone.down.fill")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(.red, in: Circle())
            }
        }
        .padding(.top, 4)
    }

    private func round(_ icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(on ? .black : .white)
                .frame(width: 56, height: 56)
                .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
        }
    }
}

// MARK: - ta 那一格

struct TaView: View {
    @EnvironmentObject var call: CallSession
    var body: some View {
        switch call.stage {
        case .glow:  GlowView()
        case .photo: PhotoView(face: call.face)
        }
    }
}

/// 光档：呼吸 + 跟着声音鼓起来（02 第 2 节那段公式）。
struct GlowView: View {
    @State private var smoother = Smoother()

    final class Smoother {
        var v: Float = 0
        func next(_ x: Float) -> Float { v += (x - v) * 0.3; return v }   // 0.3 低通，不抖
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * 2 * .pi / 5) + 1) / 2                   // 5 秒一口气
            let s = Double(smoother.next(AudioRig.shared.level))
            let scale = 1 + 0.10 * breath + 0.55 * s
            ZStack {
                Color.black
                Circle()
                    .fill(RadialGradient(colors: [.pink.opacity(0.7), .purple.opacity(0.25), .clear],
                                         center: .center, startRadius: 10, endRadius: 160))
                    .frame(width: 320, height: 320)
                    .scaleEffect(scale)
                    .blur(radius: 24)
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 70, height: 70)
                    .scaleEffect(1 + 0.25 * s)
                    .blur(radius: 6)
            }
        }
    }
}

/// 照片档：只在〔表情〕处换，0.4 秒淡入淡出。
/// 往 Assets 里放 face_calm / face_smile / face_shy / face_tease / face_soft 五张图就是你的 ta；
/// 没放就显示占位。五张最好从同一张参考图生成，不然换的时候像换了个人。
struct PhotoView: View {
    let face: Face
    var body: some View {
        ZStack {
            if let img = UIImage(named: face.imageName) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Text(face.rawValue).font(.system(size: 64, weight: .ultraLight))
                    Text(face.imageName).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
        .id(face)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.4), value: face)
        .clipped()
    }
}

// MARK: - 字幕：整通都在，能往回翻（01 第 6 节）

struct CaptionsView: View {
    @EnvironmentObject var call: CallSession
    @State private var browsing = false
    @State private var resume: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(call.captions) { c in row(c).id(c.id) }
                    if !call.hearing.isEmpty {
                        Text(call.hearing)
                            .foregroundStyle(.white.opacity(0.45))     // 灰字只给你看
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id("hearing")
                    }
                }
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 170)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18)],
                                 startPoint: .top, endPoint: .bottom))
            .simultaneousGesture(DragGesture()
                .onChanged { _ in browsing = true; resume?.cancel() }
                .onEnded { _ in
                    resume = Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)   // 松手 5 秒再跟回最新
                        guard !Task.isCancelled else { return }
                        browsing = false
                        follow(proxy)
                    }
                })
            .onChange(of: call.captions.count) { follow(proxy) }
            .onChange(of: call.hearing) { follow(proxy) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard !browsing else { return }
        let target: AnyHashable? = call.hearing.isEmpty ? call.captions.last.map { AnyHashable($0.id) } : "hearing"
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    @ViewBuilder
    private func row(_ c: Caption) -> some View {
        switch c.who {
        case .ta:
            Text(c.text)
                .font(c.isAction ? .callout.italic() : .body)
                .foregroundStyle(c.isAction ? .white.opacity(0.55) : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .me:
            Text(c.typed ? "⌨︎ \(c.text)" : c.text)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
