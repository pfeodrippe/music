import UIKit
import Metal
import QuartzCore

struct ScoreControllerMessage {
    let kind: UInt32
    let payload: Data
}

private struct ScoreGPUUniforms {
    var viewport: SIMD2<Float>
    var time: Float
    var pixelRatio: Float
}

private final class ScoreSemanticElement: UIAccessibilityElement {
    let scoreID: UInt32
    let onActivated: () -> Void

    init(container: Any, scoreID: UInt32, onActivated: @escaping () -> Void) {
        self.scoreID = scoreID
        self.onActivated = onActivated
        super.init(accessibilityContainer: container)
    }

    override func accessibilityActivate() -> Bool {
        score_ios_accessibility_activate(scoreID)
        onActivated()
        return true
    }
}

final class ScoreMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var onHostRequest: ((UInt32) -> Void)?
    var onPlayback: (([ScorePlaybackEvent]) -> Void)?
    var onController: (([ScoreControllerMessage]) -> Void)?
    var onControllerPreferencesChanged: (() -> Void)?
    var onAutosave: (() -> Void)?

    private let metalDevice: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState
    private let glyphTexture: MTLTexture
    private let glyphSampler: MTLSamplerState
    private var itemBuffer: MTLBuffer
    private var displayLink: CADisplayLink?
    private var previousTimestamp: CFTimeInterval = 0
    private var nextAutosaveTimestamp: CFTimeInterval = 0
    private let itemCapacity = 16_384
    private var accessibilitySignature = ""
#if DEBUG
    private var shaderOverrideURL: URL?
    private var shaderModificationTime: TimeInterval?
    private var nextShaderPollTimestamp: CFTimeInterval = 0
    private var shaderReloadInFlight = false
#endif

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        guard score_ios_api_version() == 3 else { fatalError("Unsupported Score core ABI") }
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("Metal is unavailable on this device")
        }
        guard let libraryURL = Bundle.main.url(forResource: "ScoreShaders", withExtension: "metallib"),
              let library = try? device.makeLibrary(URL: libraryURL),
              let vertex = library.makeFunction(name: "scoreVertex"),
              let fragment = library.makeFunction(name: "scoreFragment") else {
            fatalError("Score Metal shader library is missing")
        }
        let atlasWidth = Int(score_ios_glyph_atlas_width())
        let atlasHeight = Int(score_ios_glyph_atlas_height())
        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: atlasWidth, height: atlasHeight, mipmapped: false)
        atlasDescriptor.usage = .shaderRead
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let pipelineState = try? Self.makePipeline(device: device, vertex: vertex, fragment: fragment),
              let buffer = device.makeBuffer(length: itemCapacity * MemoryLayout<ScoreDrawItem>.stride, options: .storageModeShared),
              let atlas = device.makeTexture(descriptor: atlasDescriptor),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let atlasBytes = score_ios_glyph_atlas_bytes() else {
            fatalError("Score Metal pipeline could not be created")
        }
        atlas.replace(region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight), mipmapLevel: 0, withBytes: atlasBytes, bytesPerRow: atlasWidth * 4)
        metalDevice = device
        commandQueue = queue
        pipeline = pipelineState
        glyphTexture = atlas
        glyphSampler = sampler
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
#if DEBUG
        configureShaderReload()
#endif
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
#if DEBUG
        pollShaderReload(at: link.timestamp)
#endif
        score_ios_frame(Float(delta))
        updateAccessibility()

        let request = score_ios_host_request()
        if request != 0 { onHostRequest?(request) }
        drainPlayback()
        drainController()
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
        encoder.setFragmentTexture(glyphTexture, index: 0)
        encoder.setFragmentSamplerState(glyphSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

#if DEBUG
    /// Development builds seed a writable shader beside the autosave data.
    /// `scripts/dev-ios.sh` replaces this file in the running simulator. A
    /// physical development build can receive the same file through its
    /// file-sharing container without changing the signed application bundle.
    private func configureShaderReload() {
        guard let bundledSource = Bundle.main.url(forResource: "ScoreShaders", withExtension: "metal"),
              let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("Score shader reload unavailable: development source is missing")
            return
        }
        let directory = supportRoot.appendingPathComponent("Score", isDirectory: true)
        let override = directory.appendingPathComponent("ScoreShaders.metal")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: override.path) {
                try FileManager.default.copyItem(at: bundledSource, to: override)
            }
            shaderOverrideURL = override
            shaderModificationTime = Self.modificationTime(of: override)
            print("Score shader reload watching \(override.path)")
        } catch {
            print("Score shader reload unavailable: \(error)")
        }
    }

    private static func modificationTime(of url: URL) -> TimeInterval? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
    }

    private func pollShaderReload(at timestamp: CFTimeInterval) {
        guard timestamp >= nextShaderPollTimestamp else { return }
        nextShaderPollTimestamp = timestamp + 0.25
        guard !shaderReloadInFlight, let url = shaderOverrideURL,
              let modified = Self.modificationTime(of: url), modified != shaderModificationTime else { return }

        // Mark this revision attempted before compiling so invalid source does
        // not trigger every frame. A later save changes the timestamp and gets
        // another independent attempt.
        shaderModificationTime = modified
        shaderReloadInFlight = true
        let device = metalDevice
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<MTLRenderPipelineState, Error>
            do {
                let source = try String(contentsOf: url, encoding: .utf8)
                let library = try device.makeLibrary(source: source, options: nil)
                guard let vertex = library.makeFunction(name: "scoreVertex"),
                      let fragment = library.makeFunction(name: "scoreFragment") else {
                    throw ScoreShaderReloadError.missingEntryPoint
                }
                result = .success(try Self.makePipeline(device: device, vertex: vertex, fragment: fragment))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.shaderReloadInFlight = false
                switch result {
                case .success(let candidate):
                    // The render loop and this assignment both run on the main
                    // thread, so no frame can observe a partially built state.
                    self.pipeline = candidate
                    print("Score shader reload accepted; live Flecs state preserved")
                case .failure(let error):
                    print("Score shader reload rejected; retaining last-good pipeline: \(error)")
                }
            }
        }
    }
#endif

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

    private func drainController() {
        var outputs = Array(repeating: ScoreControllerOutput(), count: 64)
        let count = outputs.withUnsafeMutableBufferPointer { buffer in
            score_ios_drain_controller(buffer.baseAddress, buffer.count)
        }
        guard count > 0 else { return }
        var messages: [ScoreControllerMessage] = []
        messages.reserveCapacity(count)
        for index in 0..<count {
            var output = outputs[index]
            let length = min(Int(output.length), 128)
            let payload = withUnsafeBytes(of: &output.bytes) { Data($0.prefix(length)) }
            messages.append(ScoreControllerMessage(kind: output.kind, payload: payload))
        }
        onController?(messages)
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
            let element = ScoreSemanticElement(container: self, scoreID: item.id) { [weak self] in
                self?.drainController()
                self?.onControllerPreferencesChanged?()
            }
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        forward(touches, kind: 1, event: event)
        // Pencil Force mode defers note-on until this first high-rate force
        // refresh. Six milliseconds is short enough for performance while
        // avoiding the coarse/estimated force commonly present in began.
        for touch in touches where touch.type == .pencil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.006) { [weak self, weak touch] in
                guard let self, let touch, touch.phase == .stationary || touch.phase == .moved else { return }
                self.forward([touch], kind: 0, event: nil)
            }
        }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 0, event: event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 2, event: event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 3, event: event) }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) { forward(touches, kind: 0, event: nil) }

    private func forward(_ touches: Set<UITouch>, kind: UInt32, event: UIEvent?) {
        for touch in touches {
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for sample in samples {
                let point = sample.location(in: self)
                let pointerType: UInt32 = sample.type == .pencil ? 1 : (sample.type == .indirectPointer ? 0 : 2)
                // Pencil has genuine force. Finger Dynamic mode separately
                // receives majorRadius, explicitly an approximate contact area.
                let pressure = sample.type == .pencil && sample.maximumPossibleForce > 0 && kind != 2 && kind != 3
                    ? sample.force / sample.maximumPossibleForce
                    : 0
                let contactRadius = sample.type == .direct && kind != 2 && kind != 3 ? sample.majorRadius : 0
                score_ios_pointer(kind, pointerType, UInt32(truncatingIfNeeded: ObjectIdentifier(touch).hashValue), Float(point.x), Float(point.y), kind == 2 ? 0 : 1, Float(pressure), Float(contactRadius), 0, 0)
            }
        }
        // Controller gestures must not wait for the next 60 Hz render tick.
        // Draining here removes up to one full frame of tap-to-MIDI latency;
        // the display-link drain remains as a fallback for non-touch sources.
        drainController()
        if kind == 2 || kind == 3 { onControllerPreferencesChanged?() }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let point = recognizer.location(in: self)
        score_ios_pointer(0, 0, 0, Float(point.x), Float(point.y), 0, 0, 0, 0, 0)
    }
}

#if DEBUG
private enum ScoreShaderReloadError: LocalizedError {
    case missingEntryPoint

    var errorDescription: String? {
        switch self {
        case .missingEntryPoint:
            return "scoreVertex or scoreFragment is missing"
        }
    }
}
#endif
