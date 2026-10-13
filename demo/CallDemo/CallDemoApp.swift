import SwiftUI

@main
struct CallDemoApp: App {
    @StateObject private var call = CallSession()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(call)
                .fullScreenCover(isPresented: $call.active) {
                    CallScreen().environmentObject(call)
                }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var call: CallSession
    @State private var ringing = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Circle()
                .fill(.pink.opacity(0.25))
                .frame(width: 120, height: 120)
                .overlay(Text("ta").font(.largeTitle.weight(.light)))
            Text("callhome-video demo")
                .font(.headline)
            Text("离线演示：ta 的回复是写死的，声音是系统语音。\n换成你自己的模型，改 MockBrain.swift 一个函数。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                call.start(viaCallKit: false)
            } label: {
                Label("打给 ta", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button {
                ringing = true
                Ringer.shared.ringIn(after: 5)
            } label: {
                Label(ringing ? "5 秒后响 —— 现在可以锁屏" : "让 ta 打过来（CallKit）",
                      systemImage: "phone.arrow.down.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(ringing)

            Spacer()
            Text("CallKit 在中国大陆地区的 App Store 上架受限；自己装来玩不受影响。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .onAppear {
            Ringer.shared.onAnswer = { call.start(viaCallKit: true) }
            Ringer.shared.onAudioActivated = { call.audioActivatedByCallKit() }
            Ringer.shared.onEnd = { call.hangUp(fromCallKit: true) }
            Ringer.shared.onRingOver = { ringing = false }
        }
    }
}
