import Foundation

/// One reversible change made from the command line (docs/design/09-wayforkctl.md
/// § Dead-man confirm). Every case carries what it expects to find, so the inverse of a
/// change the GUI has since touched is skipped instead of clobbering the GUI's edit.
public enum StoreEdit: Codable, Sendable, Hashable {
    /// Insert before `before` (a rule of the same group) or at the group's end.
    case insertRule(Rule, before: UUID?)
    /// Remove the rule with this id if it still equals this value. `before` records the
    /// rule that followed it in its group, for the inverse.
    case removeRule(Rule, before: UUID?)
    /// Replace the rule `from.id` if it still equals `from`.
    case replaceRule(from: Rule, to: Rule)
    case setLogLevel(from: LogLevel, to: LogLevel)

    public var inverse: StoreEdit {
        switch self {
        case .insertRule(let rule, let before): .removeRule(rule, before: before)
        case .removeRule(let rule, let before): .insertRule(rule, before: before)
        case .replaceRule(let from, let to): .replaceRule(from: to, to: from)
        case .setLogLevel(let from, let to): .setLogLevel(from: to, to: from)
        }
    }

    /// Applies the edit. Returns nil on success, or why it was skipped (the store is then
    /// unchanged).
    @discardableResult
    public func apply(to store: inout Store) -> String? {
        switch self {
        case .insertRule(let rule, let before):
            if store.rules.contains(where: { $0.id == rule.id }) {
                return "rule \(rule.pattern) already exists"
            }
            if store.rules.contains(where: { $0.pattern == rule.pattern && $0.match == rule.match }
            ) {
                return "another rule for \(rule.pattern) exists"
            }
            let index =
                before.flatMap { id in
                    store.rules.firstIndex { $0.id == id && $0.target == rule.target }
                } ?? store.endIndexOfGroup(rule.target)
            store.rules.insert(rule, at: index)
            return nil
        case .removeRule(let rule, _):
            guard let index = store.rules.firstIndex(where: { $0.id == rule.id }) else {
                return "rule \(rule.pattern) is gone"
            }
            guard store.rules[index] == rule else {
                return "rule \(rule.pattern) was changed since"
            }
            store.rules.remove(at: index)
            return nil
        case .replaceRule(let from, let to):
            guard let index = store.rules.firstIndex(where: { $0.id == from.id }) else {
                return "rule \(from.pattern) is gone"
            }
            guard store.rules[index] == from else {
                return "rule \(from.pattern) was changed since"
            }
            store.rules[index] = to
            return nil
        case .setLogLevel(let from, let to):
            guard store.settings.logLevel == from else {
                return "log level was changed since"
            }
            store.settings.logLevel = to
            return nil
        }
    }

    /// A removal of `rule` as it sits in `store`, with the rule that follows it in its
    /// group recorded for the inverse.
    public static func removal(of rule: Rule, in store: Store) -> StoreEdit {
        let group = store.rules.filter { $0.target == rule.target }
        let next = group.firstIndex(where: { $0.id == rule.id }).flatMap { index in
            index + 1 < group.count ? group[index + 1].id : nil
        }
        return .removeRule(rule, before: next)
    }
}

extension Store {
    /// Index right after the last rule of `target`'s group (or `rules.endIndex`).
    public func endIndexOfGroup(_ target: RuleTarget) -> Int {
        guard let last = rules.lastIndex(where: { $0.target == target }) else {
            return rules.endIndex
        }
        return last + 1
    }
}
