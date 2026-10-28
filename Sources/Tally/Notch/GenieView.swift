import AppKit
import MetalKit

/// 开合时的「神奇效果」（macOS 最小化窗口那种）：开合前把面板截成一张纹理，动画期间藏起真面板，
/// 在这个视图里用 Metal 把纹理贴到一张网格上，每帧在 GPU 里算顶点位移；动画结束换回真面板。
///
/// 算法照 macOS 真实的做法（参考 AnNingUI/Macos-Genie-Effect-With-WebGPU，原理见 daniate 的「细说如何完美实现 macOS 中的神奇效果」）：
/// 窗口的轮廓是一个固定的漏斗，左右两条边界是余弦曲线，窄端对着刘海、宽端保持完整宽度；
/// 先让漏斗收窄成形（`curve`），再让内容沿着漏斗滑向刘海、一路被挤窄，最后整块被吸进去（`translate`）。
/// 展开就是这个过程倒放。两段在时间上有重叠，各自带缓动。
///
/// 着色器用运行时编译（`makeLibrary(source:)`），不依赖 Xcode 的离线 Metal 编译器——只装了 Command Line Tools 也能用。
final class GenieView: MTKView {

    private struct Params {
        var viewSize: SIMD2<Float>
        var texSize: SIMD2<Float>
        var notch: SIMD2<Float>
        /// 漏斗收窄量 0…1
        var curve: Float
        /// 内容向刘海滑进去的量 0…1
        var translate: Float
        var rows: UInt32
    }

    private static let rows = 160
    /// 4 倍多重采样：漏斗两边是斜线，不抗锯齿会一格一格的。
    private static let samples = 4
    static let openDuration: TimeInterval = 0.5
    static let closeDuration: TimeInterval = 0.45

    /// 总开关：`defaults write com.aiden.tally genieEffect -bool false` 关掉，回到普通的弹簧动画。
    /// 系统开了「减弱动态效果」或没有 GPU 时也不用。
    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "genieEffect") as? Bool ?? true else { return false }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        return MTLCreateSystemDefaultDevice() != nil
    }

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let loader: MTKTextureLoader
    private var texture: MTLTexture?
    private var texSize = CGSize.zero
    private var notch = CGSize.zero
    private var opening = true
    private var startProgress = 0.0
    private var startTime: CFTimeInterval = 0
    private var completion: (() -> Void)?
    /// 当前进度；动画被打断时据此接着走，不跳变。
    private(set) var progress = 0.0
    private(set) var isPlaying = false

    init?(overlay: Void) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let vertex = library.makeFunction(name: "genieVertex"),
              let fragment = library.makeFunction(name: "genieFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.rasterSampleCount = Self.samples
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        // 纹理是预乘 alpha 的
        let color = descriptor.colorAttachments[0]!
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.sourceAlphaBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.queue = queue
        self.pipeline = pipeline
        self.loader = MTKTextureLoader(device: device)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = false
        sampleCount = Self.samples
        isPaused = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 120
        wantsLayer = true
        layer?.isOpaque = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) 不使用") }

    /// 覆盖层不接鼠标：事件照常落到下面的面板上。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// - Parameters:
    ///   - image: 完整展开态面板的截图（像素尺寸 = `size` × 屏幕缩放）。
    ///   - size: 面板展开态的点尺寸，画在视图顶部居中。
    ///   - notch: 物理刘海的点尺寸，收起的那一头。
    ///   - from: 起始进度（打断另一段动画时接着走）。
    func play(image: CGImage, size: CGSize, notch: CGSize, opening: Bool, from: Double,
              completion: @escaping () -> Void) {
        guard let texture = try? loader.newTexture(cgImage: image, options: [
            .SRGB: false, .origin: MTKTextureLoader.Origin.topLeft, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ]) else { completion(); return }
        if let space = image.colorSpace { (layer as? CAMetalLayer)?.colorspace = space }
        self.texture = texture
        self.texSize = size
        self.notch = notch
        self.opening = opening
        self.startProgress = from
        self.progress = from
        self.startTime = CACurrentMediaTime()
        self.completion = completion
        isPlaying = true
        isPaused = false
    }

    /// 停掉当前动画（不调完成回调），返回停下时的进度。
    @discardableResult
    func stop() -> Double {
        isPaused = true
        isPlaying = false
        completion = nil
        return progress
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isPlaying, texture != nil, let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer() else { return }
        let (value, done) = evaluate(CACurrentMediaTime() - startTime)
        progress = value
        encode(into: pass, buffer: buffer, viewSize: bounds.size, progress: value)
        buffer.present(drawable)
        buffer.commit()
        if done {
            isPaused = true
            isPlaying = false
            let finish = completion
            completion = nil
            // 最后一帧先上屏，下一轮再换回真面板
            DispatchQueue.main.async { finish?() }
        }
    }

    /// 进度 `p`（1 展开、0 收进刘海）随时间线性走，两段缓动在 `Params` 里：时间越短越接近终点，被打断时按剩下的距离折算时长。
    private func evaluate(_ t: TimeInterval) -> (Double, Bool) {
        if opening {
            let duration = Self.openDuration * max(1 - startProgress, 0.15)
            let x = min(t / duration, 1)
            return (startProgress + (1 - startProgress) * x, x >= 1)
        }
        let duration = Self.closeDuration * max(startProgress, 0.15)
        let x = min(t / duration, 1)
        return (startProgress * (1 - x), x >= 1)
    }

    /// 收起时间线 x（0 展开 → 1 收进去）上两段重叠的缓动：漏斗先成形，内容稍后开始往刘海里滑。
    private static func phases(for progress: Double) -> (curve: Double, translate: Double) {
        func smooth(_ v: Double) -> Double { let c = min(max(v, 0), 1); return c * c * (3 - 2 * c) }
        let x = 1 - min(max(progress, 0), 1)
        return (smooth(x / 0.62), smooth((x - 0.28) / 0.72))
    }

    private func encode(into pass: MTLRenderPassDescriptor, buffer: MTLCommandBuffer, viewSize: CGSize, progress: Double) {
        guard let texture, let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let phase = Self.phases(for: progress)
        var params = Params(viewSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                            texSize: SIMD2(Float(texSize.width), Float(texSize.height)),
                            notch: SIMD2(Float(notch.width), Float(notch.height)),
                            curve: Float(phase.curve), translate: Float(phase.translate), rows: UInt32(Self.rows))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: (Self.rows + 1) * 2)
        encoder.endEncoding()
    }

    /// 调试：把某个进度的画面离屏渲染成图（不上屏），用来在没法录屏时检查形变对不对。
    func debugRender(progress: Double) -> CGImage? {
        guard let device, texture != nil else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }
        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .shared
        let msaaDescriptor = MTLTextureDescriptor()
        msaaDescriptor.textureType = .type2DMultisample
        msaaDescriptor.pixelFormat = .bgra8Unorm
        msaaDescriptor.width = width
        msaaDescriptor.height = height
        msaaDescriptor.sampleCount = Self.samples
        msaaDescriptor.usage = .renderTarget
        msaaDescriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: resolveDescriptor),
              let msaa = device.makeTexture(descriptor: msaaDescriptor),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        encode(into: pass, buffer: buffer, viewSize: bounds.size, progress: progress)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float2 viewSize;
        float2 texSize;
        float2 notch;
        float curve;
        float translate;
        uint rows;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    // 三角带：每行左右两个顶点，行 v 是纹理里从刘海一端（0）到远端（1）的位置。
    // 轮廓是固定的漏斗：行在窗口里的位置 yn（0 在刘海、1 在最远端）决定左右边界；
    // 内容沿漏斗往刘海滑 translate，所以纹理行 v 落在 yn = v - translate，滑到 0 以上的行全挤在刘海那里（零面积）。
    vertex VOut genieVertex(uint vid [[vertex_id]], constant Params &P [[buffer(0)]]) {
        uint row = vid / 2;
        float side = float(vid % 2);
        float v = float(row) / float(P.rows);
        float yn = max(v - P.translate, 0.0);

        // 刘海端左右边界收到刘海宽度，向远端按余弦曲线回到 0 / 1（0.5 * (1 + cos) 在 yn=0 为 1、yn=1 为 0）
        float neck = (1.0 - P.notch.x / P.texSize.x) * 0.5 * P.curve;
        float shape = 0.5 * (1.0 + cos(M_PI_F * yn));
        float left = neck * shape;
        float right = 1.0 - neck * shape;

        float x = P.viewSize.x * 0.5 + (mix(left, right, side) - 0.5) * P.texSize.x;
        float y = yn * P.texSize.y;
        VOut out;
        out.position = float4(x / P.viewSize.x * 2.0 - 1.0, 1.0 - y / P.viewSize.y * 2.0, 0.0, 1.0);
        out.uv = float2(side, v);
        return out;
    }

    fragment float4 genieFragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return tex.sample(s, in.uv);
    }
    """
}
