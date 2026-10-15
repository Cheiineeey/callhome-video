import AVFoundation
import CoreImage
import SwiftUI

/// 镜头四种状态。`unchosen` 和 `off` 要分开 —— ta 那边说的话不一样（04 坑 4.4）。
enum CameraChoice: String { case unchosen, off, front, back }

/// 你的摄像头 + 取帧。
///
/// 取帧规则（01 第 2 节的缩小版）：每 0.5 秒存一张缩略图，记下它跟上一张差多少；
/// 一轮要图时，从最近 3 张里挑**动得最少（最清楚）**的那一张。
final class Camera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera")
    private let output = AVCaptureVideoDataOutput()
    private let ci = CIContext()

    private struct Frame { let image: UIImage; let motion: Float }
    private var frames: [Frame] = []          // 只在 queue 上碰
    private var lastThumb: [UInt8] = []
    private var lastTake = Date.distantPast
    private var wanted = false                // 坑 1.2：关了之后晚到的帧也不能收
    private var pinned: UIImage?              // 你长按钉住的那一张（01 第 3 节），下一轮优先给

    override init() {
        super.init()
        // 坑 2.1：不关这个，一开摄像头声音就被甩回听筒。
        session.automaticallyConfiguresApplicationAudioSession = false
        output.setSampleBufferDelegate(self, queue: queue)
        output.alwaysDiscardsLateVideoFrames = true
    }

    func use(_ lens: AVCaptureDevice.Position) {
        queue.async { [self] in
            wanted = true
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lens),
               let input = try? AVCaptureDeviceInput(device: dev),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if !session.outputs.contains(output), session.canAddOutput(output) {
                session.addOutput(output)
            }
            session.sessionPreset = .medium
            if let conn = output.connection(with: .video) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
                if conn.isVideoMirroringSupported {
                    conn.automaticallyAdjustsVideoMirroring = false
                    conn.isVideoMirrored = (lens == .front)
                }
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
            frames.removeAll()
            DispatchQueue.main.async { AudioRig.shared.repinSpeaker() }
        }
    }

    func stop() {
        queue.async { [self] in
            wanted = false
            frames.removeAll()        // 当场清：关镜头后那一句不能带上关之前的图
            pinned = nil
            lastThumb = []
            if session.isRunning { session.stopRunning() }
            DispatchQueue.main.async { AudioRig.shared.repinSpeaker() }
        }
    }

    /// 长按你那一格：把当下这一帧钉住。没画面返回 false（界面就别闪）。
    func pin() -> Bool {
        queue.sync {
            guard wanted, let last = frames.last else { return false }
            pinned = last.image
            return true
        }
    }

    /// 这一轮给 ta 的那一张；钉住的优先，用完就清。没有就 nil（然后要明写「这一轮没取到」）。
    func pickFrame() -> (image: UIImage, pinned: Bool)? {
        queue.sync {
            guard wanted else { pinned = nil; return nil }
            if let p = pinned { pinned = nil; return (p, true) }
            return frames.suffix(3).min(by: { $0.motion < $1.motion }).map { ($0.image, false) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard wanted, Date().timeIntervalSince(lastTake) >= 0.5,
              let px = CMSampleBufferGetImageBuffer(sb) else { return }
        lastTake = Date()

        var img = CIImage(cvPixelBuffer: px)
        let scale = 480 / max(img.extent.width, img.extent.height)
        img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ci.createCGImage(img, from: img.extent) else { return }

        let thumb = grayThumb(img)
        var motion: Float = 0
        if thumb.count == lastThumb.count, !thumb.isEmpty {
            var d = 0
            for i in 0..<thumb.count { d += abs(Int(thumb[i]) - Int(lastThumb[i])) }
            motion = Float(d) / Float(thumb.count)
        }
        lastThumb = thumb
        frames.append(Frame(image: UIImage(cgImage: cg), motion: motion))
        if frames.count > 12 { frames.removeFirst(frames.count - 12) }
    }

    /// 16×16 灰度，只用来比两张差多少。
    private func grayThumb(_ img: CIImage) -> [UInt8] {
        let s = 16 / max(img.extent.width, img.extent.height)
        let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            .applyingFilter("CIPhotoEffectMono")
        var buf = [UInt8](repeating: 0, count: 16 * 16 * 4)
        ci.render(small, toBitmap: &buf, rowBytes: 16 * 4,
                  bounds: CGRect(x: small.extent.minX, y: small.extent.minY, width: 16, height: 16),
                  format: .RGBA8, colorSpace: nil)
        return stride(from: 0, to: buf.count, by: 4).map { buf[$0] }
    }
}

/// 预览只有**一个** layer。大小窗对调时挪的是这个 view 的位置，不是再建一个（02 第 5 节）。
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = session
        v.preview.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
