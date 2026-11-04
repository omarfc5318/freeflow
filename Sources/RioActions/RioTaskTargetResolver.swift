import AppKit

/// The live `RioTaskTargetResolving`: snapshots the front window the way the screen handler does
/// and runs the same `RioClickMatcher` over it, so the risk check sees the element that would
/// really be pressed. The snapshot is dropped straight away; nothing is logged or stored.
@MainActor
final class RioTaskTargetResolver: RioTaskTargetResolving {
    func resolveTarget(for action: RioAction) async -> RioTaskTargetResolution {
        switch action {
        case .click, .fillField: break
        default: return .notApplicable
        }
        guard let app = RioAX.frontmostApp(), app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !RioClickSafety.isBlockedApp(bundleID: app.bundleIdentifier),
              let snapshot = await RioClickAX.snapshot(of: app), !snapshot.elements.isEmpty else { return .unresolved }
        return RioTaskTargetMapper.resolution(for: action, elements: snapshot.elements)
    }
}
