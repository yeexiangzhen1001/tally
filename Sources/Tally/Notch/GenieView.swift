import AppKit
import MetalKit

/// 开合时的「神奇效果」（macOS 最小化窗口那种）：开合前把面板截成一张纹理，动画期间藏起真面板，
/// 在这个视图里用 Metal 把纹理贴到一张网格上，每帧在 GPU 里算顶点位移；动画结束换回真面板。
///
/// 着色器用运行时编译（`makeLibrary(source:)`），不依赖 Xcode 的离线 Metal 编译器——只装了 Command Line Tools 也能用。
/// 形变：靠刘海的一端收窄、远端保持宽，中间 S 形过渡，纹理按高度压扁；进度 0 是缩进刘海、1 是完整面板。
final class GenieView: MTKView {

    private struct Params {
        var viewSize: SIMD2<Float>
        var texSize: SIMD2<Float>
        var notch: SIMD2<Float>
        var progress: Float
        var rows: UInt32
    }

    private static let rows = 96
    static let openDuration: TimeInterval = 0.6
    static let closeDuration: TimeInterval = 0.4

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

    /// 展开：临界略欠阻尼的弹簧（过一点头再落回）；收起：smoothstep 加速吸进去。
    private func evaluate(_ t: TimeInterval) -> (Double, Bool) {
        if opening {
            let omega = 14.0, zeta = 0.7
            let damped = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
            return t >= Self.openDuration ? (1, true) : (1 - (1 - startProgress) * decay, false)
        }
        let x = min(t / Self.closeDuration, 1)
        let eased = x * x * (3 - 2 * x)
        return (startProgress * (1 - eased), x >= 1)
    }

    private func encode(into pass: MTLRenderPassDescriptor, buffer: MTLCommandBuffer, viewSize: CGSize, progress: Double) {
        guard let texture, let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var params = Params(viewSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                            texSize: SIMD2(Float(texSize.width), Float(texSize.height)),
                            notch: SIMD2(Float(notch.width), Float(notch.height)),
                            progress: Float(progress), rows: UInt32(Self.rows))
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
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
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
        float progress;
        uint rows;
    };

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    // 三角带：每行左右两个顶点。行 v 从刘海一端（0）到远端（1）。
    vertex VOut genieVertex(uint vid [[vertex_id]], constant Params &P [[buffer(0)]]) {
        uint row = vid / 2;
        float side = float(vid % 2);
        float v = float(row) / float(P.rows);
        float p = P.progress;
        float pc = clamp(p, 0.0, 1.0);
        // 高度随进度从刘海高长到面板高（回弹时可以略超）
        float height = P.notch.y + (P.texSize.y - P.notch.y) * max(p, 0.0);
        // 刘海端的宽度跟得慢、远端宽得快：开合途中是个上窄下宽的漏斗
        float topW = P.notch.x + (P.texSize.x - P.notch.x) * pow(pc, 2.2);
        float botW = P.notch.x + (P.texSize.x - P.notch.x) * (1.0 - pow(1.0 - pc, 2.2));
        float width = mix(topW, botW, smoothstep(0.0, 1.0, v));
        float x = P.viewSize.x * 0.5 + (side - 0.5) * width;
        float y = v * height;
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
