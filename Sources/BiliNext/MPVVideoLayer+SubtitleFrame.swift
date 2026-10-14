import CMPV
import Foundation
import OpenGL.GL3

extension MPVVideoLayer {
    /// Render video alone into a small offscreen framebuffer on the render queue. Unlike
    /// screenshot-raw, this works with zero-copy VideoToolbox hardware frames and excludes
    /// SwiftUI overlays.
    func subtitleFrame(sourceWidth: Double, sourceHeight: Double) async -> SubtitleFrame? {
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }
        return await withContext { renderer in
            Self.captureFrame(
                renderer: renderer, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        }
    }

    private static func captureFrame(
        renderer: OpaquePointer, sourceWidth: Double, sourceHeight: Double
    ) -> SubtitleFrame? {
        let scale = min(1, 1280 / sourceWidth, 720 / sourceHeight)
        let width = max(1, Int(sourceWidth * scale))
        let height = max(1, Int(sourceHeight * scale))
        var previous: GLint = 0
        var textureBinding: GLint = 0
        var viewport = [GLint](repeating: 0, count: 4)
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &previous)
        glGetIntegerv(GLenum(GL_TEXTURE_BINDING_2D), &textureBinding)
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)
        var framebuffer: GLuint = 0
        var texture: GLuint = 0
        glGenFramebuffers(1, &framebuffer)
        glGenTextures(1, &texture)
        defer {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previous))
            glBindTexture(GLenum(GL_TEXTURE_2D), GLuint(textureBinding))
            glViewport(viewport[0], viewport[1], viewport[2], viewport[3])
            glDeleteTextures(1, &texture)
            glDeleteFramebuffers(1, &framebuffer)
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(
            GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA8), GLsizei(width), GLsizei(height), 0,
            GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(
            GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D),
            texture, 0)
        guard
            glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE)
        else { return nil }
        var fbo = mpv_opengl_fbo(
            fbo: Int32(framebuffer), w: Int32(width), h: Int32(height),
            internal_format: Int32(GL_RGBA8))
        var flip: Int32 = 1
        var block: Int32 = 0
        let result = withUnsafeMutablePointer(to: &fbo) { target in
            withUnsafeMutablePointer(to: &flip) { orientation in
                withUnsafeMutablePointer(to: &block) { wait in
                    var parameters = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: target),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: orientation),
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: wait),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(renderer, &parameters)
                }
            }
        }
        guard result >= 0 else { return nil }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            glReadPixels(
                0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA),
                GLenum(GL_UNSIGNED_BYTE), bytes.baseAddress)
        }
        // OpenGL starts at the bottom row; CGImage expects the top row first.
        var flipped = Data(count: pixels.count)
        flipped.withUnsafeMutableBytes { output in
            pixels.withUnsafeBytes { input in
                for row in 0..<height {
                    output.baseAddress!.advanced(by: row * width * 4).copyMemory(
                        from: input.baseAddress!.advanced(by: (height - row - 1) * width * 4),
                        byteCount: width * 4)
                }
            }
        }
        return SubtitleFrame(width: width, height: height, pixels: flipped)
    }

}
