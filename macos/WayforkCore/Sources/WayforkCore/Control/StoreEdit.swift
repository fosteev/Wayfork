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
    case setListTarget(id: UUID, from: RuleListTarget, to: RuleListTarget)
    case insertList(RuleList)
    case removeEmptyList(RuleList)
    case batch([StoreEdit])

    public var inverse: StoreEdit {
        switch self {
        case .insertRule(let rule, let before): .removeRule(rule, before: before)
        case .removeRule(let rule, let before): .insertRule(rule, before: before)
        case .replaceRule(let from, let to): .replaceRule(from: to, to: from)
        case .setLogLevel(let from, let to): .setLogLevel(from: to, to: from)
        case .setListTarget(let id, let from, let to):
            .setListTarget(id: id, from: to, to: from)
        case .insertList(let list): .removeEmptyList(list)
        case .removeEmptyList(let list): .insertList(list)
        case .batch(let edits): .batch(edits.reversed().map(\.inverse))
        }
    }

    /// Applies the edit. Returns nil on success, or why it was skipped (the store is then
    /// unchanged).
    @discardableResult
    public func apply(to store: inout Store) -> String? {
        var next = store
        if let skipped = applyUnchecked(to: &next) { return skipped }
        do { try next.validateMembership() } catch { return "invalid list membership: \(error)" }
        store = next
        return nil
    }

    private func applyUnchecked(to store: inout Store) -> String? {
        switch self {
        case .batch(let edits):
            for edit in edits {
                if let skipped = edit.applyUnchecked(to: &store) { return skipped }
            }
            return nil
        case .setListTarget(let id, let from, let to):
            guard let index = store.lists.firstIndex(where: { $0.id == id }) else {
                return "list is gone"
            }
            guard store.lists[index].target == from else {
                return "list route was changed since"
            }
            store.lists[index].target = to
            return nil
        case .insertList(let list):
            guard store.list(id: list.id) == nil else { return "list already exists" }
            store.lists.insert(list, at: 0)
            return nil
        case .removeEmptyList(let list):
            guard store.list(id: list.id) == list, store.rules(in: list.id).isEmpty else {
                return nil  // Keep a shell another edit has adopted or changed.
            }
            store.lists.removeAll { $0.id == list.id }
            return nil
        case .insertRule(let rule, let before):
            guard let listID = rule.listID, store.list(id: listID) != nil else {
                return "rule list is gone"
            }
            if store.rules.contains(where: { $0.id == rule.id }) {
                return "rule \(rule.pattern) already exists"
            }
            // F23: a rule narrowed to another network is a sibling, not a duplicate.
            if store.rules.contains(where: {
                $0.pattern == rule.pattern && $0.match == rule.match
                    && $0.network == rule.network && $0.listID == rule.listID
            }) {
                return "another rule for \(rule.pattern) exists"
            }
            let index =
                before.flatMap { id in
                    store.rules.firstIndex { $0.id == id && $0.listID == rule.listID }
                } ?? store.endIndexOfList(rule.listID)
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
        let group = store.rules.filter { $0.listID == rule.listID }
        let next = group.firstIndex(where: { $0.id == rule.id }).flatMap { index in
            index + 1 < group.count ? group[index + 1].id : nil
        }
        return .removeRule(rule, before: next)
    }
}

extension Store {
    public func endIndexOfList(_ listID: UUID?) -> Int {
        rules.lastIndex { $0.listID == listID }.map { $0 + 1 } ?? rules.endIndex
    }

    /// Index right after the last rule of `target`'s group (or `rules.endIndex`).
    public func endIndexOfGroup(_ target: RuleTarget) -> Int {
        guard let last = rules.lastIndex(where: { $0.target == target }) else {
            return rules.endIndex
        }
        return last + 1
    }
}
