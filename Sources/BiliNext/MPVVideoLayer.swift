import AppKit
import CMPV
import OpenGL.GL3
import QuartzCore

/// Draws mpv frames on its own serial queue, so a busy main thread never holds video back.
/// Every draw happens on `renderQueue`: when Core Animation asks the layer to display on the
/// main thread (after a resize), the request is forwarded there instead of drawing in place.
/// The main thread therefore never waits for the render queue, which itself must take Core
/// Animation's transaction lock to flush; waiting in either direction deadlocks the app.
final class MPVVideoLayer: CAOpenGLLayer, @unchecked Sendable {
    let renderQueue = DispatchQueue(label: "dev.bilinext.mpv-render", qos: .userInteractive)
    private let pixelFormat: CGLPixelFormatObj
    private let context: CGLContextObj
    private var renderer: OpaquePointer?
    private let drawLock = NSLock()
    private let scheduleLock = NSLock()
    private var scheduled = false
    private var forced = false

    init?(handle: OpaquePointer) {
        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var format: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &format, &count)
        var created: CGLContextObj?
        guard let format, CGLCreateContext(format, nil, &created) == kCGLNoError,
            let created
        else { return nil }
        pixelFormat = format
        context = created
        super.init()
        isOpaque = true
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        // Let the driver pipeline GL commands on its own thread.
        CGLEnable(context, kCGLCEMPEngine)
        createRenderer(handle: handle)
    }

    /// Core Animation copies layers for presentation; the copy never draws.
    override init(layer: Any) {
        let other = layer as! MPVVideoLayer
        pixelFormat = CGLRetainPixelFormat(other.pixelFormat)
        context = CGLRetainContext(other.context)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func createRenderer(handle: OpaquePointer) {
        CGLLockContext(context)
        defer { CGLUnlockContext(context) }
        CGLSetCurrentContext(context)
        var initialization = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            }, get_proc_address_ctx: nil)
        "opengl".withCString { api in
            withUnsafeMutablePointer(to: &initialization) { gl in
                var parameters = [
                    mpv_render_param(
                        type: MPV_RENDER_PARAM_API_TYPE,
                        data: UnsafeMutableRawPointer(mutating: api)
                    ),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: gl),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                let result = mpv_render_context_create(&renderer, handle, &parameters)
                if result < 0 { NSLog("mpv renderer: %s", mpv_error_string(result)) }
            }
        }
        guard let renderer else { return }
        mpv_render_context_set_update_callback(
            renderer,
            { context in
                guard let context else { return }
                Unmanaged<MPVVideoLayer>.fromOpaque(context).takeUnretainedValue().scheduleFrame()
            }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Called from mpv's threads, and from the main thread to redraw after a resize.
    /// Coalesces bursts into one pending render; `force` redraws even without a new frame.
    private func scheduleFrame(force: Bool = false) {
        scheduleLock.lock()
        let pending = scheduled
        scheduled = true
        if force { forced = true }
        scheduleLock.unlock()
        guard !pending else { return }
        renderQueue.async { [self] in
            scheduleLock.lock()
            scheduled = false
            let force = forced
            forced = false
            scheduleLock.unlock()
            guard let renderer else { return }
            let flags = mpv_render_context_update(renderer)
            if force || flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 { render() }
        }
    }

    /// Runs only on the render queue.
    private func render() {
        drawLock.lock()
        super.display()
        drawLock.unlock()
        // Off the main thread there is no run loop to commit the implicit transaction. Flush
        // without holding the draw lock, since flushing waits for Core Animation's lock.
        CATransaction.flush()
    }

    /// Core Animation calls this on the main thread when the layer needs redrawing; the draw
    /// itself is moved to the render queue.
    override func display() {
        scheduleFrame(force: true)
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        pixelFormat
    }

    override func copyCGLContext(forPixelFormat format: CGLPixelFormatObj) -> CGLContextObj {
        context
    }

    override func canDraw(
        inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj,
        forLayerTime layerTime: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?
    ) -> Bool { renderer != nil }

    override func draw(
        inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj,
        forLayerTime layerTime: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?
    ) {
        guard let renderer else { return }
        // Core Animation binds its own framebuffer; render into it at the viewport size.
        var binding: GLint = 0
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &binding)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        var fbo = mpv_opengl_fbo(fbo: binding, w: viewport[2], h: viewport[3], internal_format: 0)
        var flip: Int32 = 1
        var block: Int32 = 0
        withUnsafeMutablePointer(to: &fbo) { buffer in
            withUnsafeMutablePointer(to: &flip) { orientation in
                withUnsafeMutablePointer(to: &block) { wait in
                    var parameters = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: buffer),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: orientation),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: wait),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    mpv_render_context_render(renderer, &parameters)
                }
            }
        }
        glFlush()
        mpv_render_context_report_swap(renderer)
    }

    /// Runs `body` on the render queue with the GL context current, off the main thread.
    func withContext<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            renderQueue.async { [self] in
                drawLock.lock()
                CGLLockContext(context)
                CGLSetCurrentContext(context)
                let result = renderer.flatMap(body)
                CGLUnlockContext(context)
                drawLock.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    /// Frees the mpv render context on the render queue, after any pending draw, without
    /// making the caller wait. `owner` is kept alive until then and released on the main
    /// thread, so the player's mpv core always outlives its render context.
    func releaseRenderer(keepingAlive owner: AnyObject? = nil) {
        renderQueue.async { [self] in
            drawLock.lock()
            if let renderer {
                CGLLockContext(context)
                CGLSetCurrentContext(context)
                mpv_render_context_set_update_callback(renderer, nil, nil)
                mpv_render_context_free(renderer)
                self.renderer = nil
                CGLUnlockContext(context)
            }
            drawLock.unlock()
            if let owner { DispatchQueue.main.async { withExtendedLifetime(owner) {} } }
        }
    }

    deinit {
        // The last reference may drop on the render queue, so free directly instead of syncing.
        if let renderer {
            CGLLockContext(context)
            CGLSetCurrentContext(context)
            mpv_render_context_set_update_callback(renderer, nil, nil)
            mpv_render_context_free(renderer)
            CGLUnlockContext(context)
        }
        CGLReleaseContext(context)
        CGLReleasePixelFormat(pixelFormat)
    }
}
