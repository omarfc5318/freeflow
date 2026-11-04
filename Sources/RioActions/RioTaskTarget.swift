import Foundation

// What a task step is about to press or fill, resolved BEFORE the risk decision (security H2).
// The model names a control by a label; the executor presses whatever `RioClickMatcher` makes of
// that label (prefix, all words, substring, one typo). So the risk check must look at the
// matched element, not the model's wording. Pure; the live resolver is in RioTaskTargetResolver.

/// One element the label resolved to.
struct RioTaskTarget: Equatable {
    /// Everything the element says about itself (title, description, help, child text).
    let texts: [String]
    let kind: RioClickKind
    /// The element sits under an AXWebArea (it is part of a page, not browser chrome).
    var isInWebArea = true
    /// The element is a browser's address (and search) field.
    var isAddressField = false
}

enum RioTaskTargetResolution: Equatable {
    /// Not a click or a fill: nothing to resolve.
    case notApplicable
    /// Nothing matched (or the window could not be read). The step fails closed.
    case unresolved
    /// `candidates` is every element the executor might press (several when the label is
    /// ambiguous). `isExact` is false unless the label matched the element's text in full.
    case resolved(candidates: [RioTaskTarget], isExact: Bool)
}

@MainActor protocol RioTaskTargetResolving: AnyObject {
    func resolveTarget(for action: RioAction) async -> RioTaskTargetResolution
}

enum RioTaskTargetMapper {
    /// Same lookup the screen handler does: clicks over every element, fills over text fields.
    static func resolution(for action: RioAction, elements: [RioClickElement]) -> RioTaskTargetResolution {
        switch action {
        case .click(let label, let ordinal):
            return map(RioClickMatcher.resolve(label: trim(label), ordinal: ordinal, in: elements))
        case .fillField(let label, _):
            let fields = elements.filter { $0.kind == .textField }
            return map(RioClickMatcher.resolve(label: trim(label), ordinal: nil, in: fields))
        default:
            return .notApplicable
        }
    }

    /// Binds a checked click or fill to the element that was checked: the label becomes that
    /// element's own text, so if the page swaps the control between the check and the press, the
    /// executor finds no exact match and the step fails instead of pressing something else.
    /// Ambiguous (several candidates) or unresolved steps are returned unchanged.
    static func bind(_ action: RioAction, to resolution: RioTaskTargetResolution) -> RioAction {
        guard case .resolved(let candidates, _) = resolution, candidates.count == 1,
              let text = candidates[0].texts.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return action
        }
        switch action {
        case .click(_, let ordinal): return .click(label: text, ordinal: ordinal)
        case .fillField(_, let value): return .fillField(label: text, text: value)
        default: return action
        }
    }

    private static func trim(_ label: String) -> String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func map(_ resolution: RioClickResolution) -> RioTaskTargetResolution {
        let elements: [RioClickElement]
        switch resolution.outcome {
        case .none, .ordinalOutOfRange: return .unresolved
        case .unique(let element): elements = [element]
        case .ambiguous(let choices): elements = choices
        }
        let targets = elements.map {
            RioTaskTarget(texts: $0.texts, kind: $0.kind, isInWebArea: $0.isInWebArea, isAddressField: $0.isAddressField)
        }
        return .resolved(candidates: targets, isExact: resolution.isExact)
    }
}
