import UIKit
import Metal
import QuartzCore

private struct ScoreGPUUniforms {
    var viewport: SIMD2<Float>
    var time: Float
    var pixelRatio: Float
}

private final class ScoreSemanticElement: UIAccessibilityElement {
    let scoreID: UInt32

    init(container: Any, scoreID: UInt32) {
        self.scoreID = scoreID
        super.init(accessibilityContainer: container)
    }

    override func accessibilityActivate() -> Bool {
        score_ios_accessibility_activate(scoreID)
        return true
    }
}

final class ScoreMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var onHostRequest: ((UInt32) -> Void)?
    var onPlayback: (([ScorePlaybackEvent]) -> Void)?
    var onAutosave: (() -> Void)?

    private let metalDevice: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var itemBuffer: MTLBuffer
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval = 0
    private var nextAutosaveTimestamp: CFTimeInterval = 0
    private let itemCapacity = 16_384
    private var accessibilitySignature = ""

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        guard score_ios_api_version() == 1 else { fatalError("Unsupported Score core ABI") }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is unavailable on this device")
        }
        guard let libraryURL = Bundle.main.url(forResource: "ScoreShaders", withExtension: "metallib"),
              let library = try? device.makeLibrary(URL: libraryURL),
              let vertex = library.makeFunction(name: "scoreVertex"),
              let fragment = library.makeFunction(name: "scoreFragment") else {
            fatalError("Score Metal shader library is missing")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor),
              let buffer = device.makeBuffer(length: itemCapacity * MemoryLayout<ScoreDrawItem>.stride, options: .storageModeShared) else {
            fatalError("Score Metal pipeline could not be created")
        }
        metalDevice = device
        commandQueue = queue
        pipeline = pipelineState
        itemBuffer = buffer
        super.init(frame: frame)

        isOpaque = true
        backgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.055, alpha: 1)
        isMultipleTouchEnabled = true
        isAccessibilityElement = false
        contentScaleFactor = UIScreen.main.scale
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = contentScaleFactor

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        guard score_ios_create(Float(max(bounds.width, 320)), Float(max(bounds.height, 320)), Float(contentScaleFactor)) else {
            fatalError("Score core could not start")
        }
        let link = CADisplayLink(target: self, selector: #selector(renderFrame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    required init?(coder: NSCoder) { fatalError("ScoreMetalView is programmatic") }

    deinit {
        displayLink?.invalidate()
        score_ios_destroy()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        contentScaleFactor = scale
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        score_ios_resize(Float(max(bounds.width, 320)), Float(max(bounds.height, 320)), Float(scale))
    }

    @objc private func renderFrame(_ link: CADisplayLink) {
        let delta = previousTimestamp == 0 ? 1.0 / 60.0 : min(link.timestamp - previousTimestamp, 0.1)
        previousTimestamp = link.timestamp
        score_ios_frame(Float(delta))
        updateAccessibility()

        let request = score_ios_host_request()
        if request != 0 { onHostRequest?(request) }
        drainPlayback()
        if nextAutosaveTimestamp == 0 || link.timestamp >= nextAutosaveTimestamp {
            onAutosave?()
            nextAutosaveTimestamp = link.timestamp + 2
        }

        let count = min(Int(score_ios_draw_count()), itemCapacity)
        guard count > 0, let source = score_ios_draw_items(), let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass(for: drawable)) else { return }
        memcpy(itemBuffer.contents(), source, count * MemoryLayout<ScoreDrawItem>.stride)
        var uniforms = ScoreGPUUniforms(
            viewport: SIMD2(Float(max(bounds.width, 1)), Float(max(bounds.height, 1))),
            time: Float(link.timestamp),
            pixelRatio: Float(contentScaleFactor)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ScoreGPUUniforms>.stride, index: 0)
        encoder.setVertexBuffer(itemBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderPass(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.035, green: 0.043, blue: 0.055, alpha: 1)
        return pass
    }

    private func drainPlayback() {
        var events = Array(repeating: ScorePlaybackEvent(pitch: 0, velocity: 0, channel: 0, on: 0), count: 128)
        let count = events.withUnsafeMutableBufferPointer { buffer in
            score_ios_drain_playback(buffer.baseAddress, buffer.count)
        }
        if count > 0 { onPlayback?(Array(events.prefix(count))) }
    }

    private func updateAccessibility() {
        let count = Int(score_ios_accessibility_count())
        guard count > 0, let pointer = score_ios_accessibility_items() else { return }
        var entries: [(ScoreAccessibilityItem, CGRect, String)] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            var item = pointer[index]
            let rectValues = withUnsafeBytes(of: &item.rect) { raw in Array(raw.bindMemory(to: Float.self).prefix(4)) }
            let label = withUnsafeBytes(of: &item.label) { raw in
                String(decoding: raw.bindMemory(to: UInt8.self).prefix(Int(item.label_len)), as: UTF8.self)
            }
            entries.append((item, CGRect(x: CGFloat(rectValues[0]), y: CGFloat(rectValues[1]), width: CGFloat(rectValues[2]), height: CGFloat(rectValues[3])), label))
        }
        let signature = entries.map { "\($0.0.id):\($0.0.role):\($0.1):\($0.0.flags):\($0.2)" }.joined(separator: "|")
        if signature == accessibilitySignature { return }
        accessibilitySignature = signature
        accessibilityElements = entries.map { item, rect, label in
            let element = ScoreSemanticElement(container: self, scoreID: item.id)
            element.accessibilityLabel = label
            element.accessibilityFrameInContainerSpace = rect
            if item.role == 0 {
                element.accessibilityTraits = .staticText
            } else {
                var traits: UIAccessibilityTraits = item.role == 2 ? .tabBar : .button
                if (item.flags & 1) != 0 || (item.flags & 2) != 0 { traits.insert(.selected) }
                element.accessibilityTraits = traits
            }
            return element
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 1) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 0) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 2) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 3) }

    private func forward(_ touches: Set<UITouch>, kind: UInt32) {
        for touch in touches {
            let point = touch.location(in: self)
            let pointerType: UInt32 = touch.type == .pencil ? 1 : (touch.type == .indirectPointer ? 0 : 2)
            let pressure = touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : (kind == 2 ? 0 : 1)
            score_ios_pointer(kind, pointerType, UInt32(truncatingIfNeeded: ObjectIdentifier(touch).hashValue), Float(point.x), Float(point.y), kind == 2 ? 0 : 1, Float(pressure), 0, 0)
        }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let point = recognizer.location(in: self)
        score_ios_pointer(0, 0, 0, Float(point.x), Float(point.y), 0, 0, 0, 0)
    }
}
