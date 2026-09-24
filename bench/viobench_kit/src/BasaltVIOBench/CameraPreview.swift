import CoreGraphics
import CoreVideo
import SwiftUI

/// What the operator is shown while a run is in progress.
///
/// An operator who cannot see the viewfinder cannot execute a real capture
/// trajectory, which is why `preview_enabled` moved to true.
///
/// The preview draws the luma plane the run has already accepted -- the same
/// bytes the engine received. It deliberately does **not** hand the ARSession to
/// an `ARSCNView`: assigning a session to `ARSCNView` makes that view the
/// session's delegate, which would displace `ARKitReferenceSession` and silently
/// stop `didUpdate`. Accounting would stall and a `record` run would persist
/// nothing, while the screen showed a perfectly healthy camera feed. A preview
/// that can break the measurement is not worth having, so this one only ever
/// reads frames the measurement already consumed.
///
/// One path serves all three arms, because at that point every arm is just
/// "here is the frame currently being processed".
enum BenchPreviewSource: Equatable {
    case none
    /// A run is active and publishing frames through `PreviewFrameTap`.
    case liveFrames(label: String)

    var receiptMode: String {
        switch self {
        case .none: return "none"
        case .liveFrames: return "accepted_frame_passthrough"
        }
    }

    /// True only when the source displays frames the run already produced,
    /// without opening a capture session or taking a delegate of its own.
    var isDisplayOnly: Bool {
        switch self {
        case .none, .liveFrames: return true
        }
    }
}

/// Turns accepted camera frames into something drawable, cheaply enough that the
/// arm being measured is not measuring the preview.
///
/// Two costs are controlled deliberately:
///
/// * **Rate.** Capped at `intervalNanoseconds`, not every frame. The operator
///   needs to see framing and motion, not 30 Hz fidelity.
/// * **Size.** Decimated by row and column skipping -- nearest neighbour, no
///   interpolation, no colour conversion. At 1920x1440 decimated by 4 the copy
///   is 173 KB against the 2.76 MB frame it came from.
///
/// The tap runs after the engine has accepted the frame, so it cannot delay
/// admission or change what the algorithm sees.
final class PreviewFrameTap: @unchecked Sendable {
    static let decimation = 4
    static let intervalNanoseconds: UInt64 = 100_000_000  // 10 Hz

    private let publish: (CGImage) -> Void
    private let renderQueue = DispatchQueue(
        label: "com.kyle.viobench.preview",
        qos: .utility
    )
    private let lock = NSLock()
    private var lastEmitNanoseconds: UInt64 = 0
    private var busy = false

    init(publish: @escaping (CGImage) -> Void) {
        self.publish = publish
    }

    /// Accepts a frame's luma plane. Returns immediately; never blocks the
    /// caller, and drops rather than queueing when rendering is still busy.
    func offer(pixelBuffer: CVPixelBuffer, monotonicNanoseconds: UInt64) {
        lock.lock()
        let due = monotonicNanoseconds &- lastEmitNanoseconds >= Self.intervalNanoseconds
        guard due, !busy else { lock.unlock(); return }
        lastEmitNanoseconds = monotonicNanoseconds
        busy = true
        lock.unlock()

        // Decimate inside the callback because the pixel buffer is only valid
        // here; everything after this point works on our own small copy.
        guard let small = Self.decimatedLuma(pixelBuffer) else {
            lock.lock(); busy = false; lock.unlock()
            return
        }
        renderQueue.async { [weak self] in
            guard let self else { return }
            if let image = Self.makeImage(small) { self.publish(image) }
            self.lock.lock(); self.busy = false; self.lock.unlock()
        }
    }

    struct DecimatedLuma {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    static func decimatedLuma(_ pixelBuffer: CVPixelBuffer) -> DecimatedLuma? {
        // The `...OfPlane` accessors answer for planar buffers. `-PWOfficialBGRA`
        // makes the transport deliver 32BGRA, which is not planar, and what these
        // return for it is not something CoreVideo promises. Take the non-planar
        // geometry explicitly and step 4 bytes per pixel; the preview only needs
        // something recognisable on screen, so one channel is enough.
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let bytesPerPixel = planar ? 1 : 4
        let sourceWidth = planar
            ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = planar
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetHeight(pixelBuffer)
        let width = sourceWidth / decimation
        let height = sourceHeight / decimation
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let baseOrNil = planar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer)
        guard let base = baseOrNil else {
            return nil
        }
        let stride = planar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard stride >= sourceWidth * bytesPerPixel else { return nil }
        let source = base.assumingMemoryBound(to: UInt8.self)

        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = source.advanced(by: y * decimation * stride)
            for x in 0..<width {
                pixels[y * width + x] = row[x * decimation * bytesPerPixel]
            }
        }
        return DecimatedLuma(width: width, height: height, pixels: pixels)
    }

    static func makeImage(_ luma: DecimatedLuma) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(luma.pixels) as CFData) else {
            return nil
        }
        return CGImage(
            width: luma.width,
            height: luma.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: luma.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// The preview area, framed at the scoring aspect ratio so the operator composes
/// the capture the way the algorithm receives it.
struct BenchPreview: View {
    let source: BenchPreviewSource
    let frame: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let frame {
                // The camera sensor is landscape; the phone is held upright.
                Image(decorative: frame, scale: 1, orientation: .right)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(placeholder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(
            CGFloat(BenchResolution.scoring.height)
                / CGFloat(BenchResolution.scoring.width),
            contentMode: .fit
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var placeholder: String {
        switch source {
        case .none: return "未运行"
        case .liveFrames(let label): return "等待首帧 · \(label)"
        }
    }
}
