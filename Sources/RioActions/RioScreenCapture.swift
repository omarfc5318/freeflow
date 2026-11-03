import AppKit
import CoreGraphics

/// Captures the window the user is working in, for "what's on my screen" (builder J). It captures
/// one window by its ID, so Rio's own windows (the bear, panels, badges) can never be in the
/// picture, and it uses the same Screen Recording permission Rio already has for context. The
/// result is JPEG bytes in memory only: never written to disk, never logged.
@MainActor
enum RioScreenCapture {
    static let maxDimension: CGFloat = 1280
    private static let jpegQuality = 0.6
    private static let maxBytes = 3_000_000

    enum Failure: Error, Equatable {
        case noPermission
        case noWindow
        case sensitiveWindow
        case captureFailed
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// The frontmost normal window that isn't Rio's.
    static func capture() throws -> Data {
        guard hasPermission else { throw Failure.noPermission }
        guard let target = targetWindow() else { throw Failure.noWindow }
        let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        if RioClickSafety.isSensitiveCaptureApp(bundleID: bundleID)
            || RioClickSafety.isBlockedWindow(bundleID: bundleID, title: target.title) {
            throw Failure.sensitiveWindow
        }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, target.id, [.bestResolution, .boundsIgnoreFraming]),
              let jpeg = encode(image) else { throw Failure.captureFailed }
        return jpeg
    }

    private struct Target {
        let id: CGWindowID
        let pid: pid_t
        let title: String?
    }

    private static func targetWindow() -> Target? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let preferred = NSWorkspace.shared.frontmostApplication.map(\.processIdentifier).flatMap { $0 == ownPID ? nil : $0 }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var fallback: Target?
        for info in windows {
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }), pid != ownPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }),
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) >= 120, (bounds["Height"] ?? 0) >= 80 else { continue }
            let target = Target(id: id, pid: pid, title: info[kCGWindowName as String] as? String)
            if preferred == nil || pid == preferred { return target }
            if fallback == nil { fallback = target }
        }
        return fallback
    }

    /// Downscaled to at most `maxDimension` on the long side, JPEG-encoded, kept under `maxBytes`.
    private static func encode(_ image: CGImage) -> Data? {
        var limit = maxDimension
        for quality in [jpegQuality, 0.45, 0.3] {
            guard let scaled = scaled(image, maxDimension: limit) else { return nil }
            let rep = NSBitmapImageRep(cgImage: scaled)
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= maxBytes {
                return data
            }
            limit *= 0.75
        }
        return nil
    }

    private static func scaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let longSide = CGFloat(max(image.width, image.height))
        guard longSide > maxDimension else { return image }
        let scale = maxDimension / longSide
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
