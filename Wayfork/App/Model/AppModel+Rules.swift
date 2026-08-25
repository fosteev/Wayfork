import Foundation
import WayforkCore

// Rule management (F2, F8): grouped by target (Direct or a tunnel), ordered within the group.

extension AppModel {
    /// Quick add from the popover. Returns an error message or nil.
    @discardableResult
    func quickAdd(input: String, target: RuleTarget) -> String? {
        switch QuickAdd.evaluate(input: input, target: target, store: store) {
        case .invalid(let message):
            return message
        case .add(let rule):
            update { $0.rules.append(rule) }
            logs.app(.info, "rule added: \(rule.pattern) → \(targetName(target))")
        case .update(let rule):
            update { store in
                guard let index = store.rules.firstIndex(where: { $0.id == rule.id }) else {
                    return
                }
                store.rules[index] = rule
            }
            logs.app(.info, "rule updated: \(rule.pattern) → \(targetName(target))")
        }
        quickAddTarget = target
        return nil
    }

    /// Adds a rule at the end of a group. Returns an error message or nil.
    @discardableResult
    func addRule(pattern input: String, match: RuleMatch, target: RuleTarget) -> String? {
        switch RuleEditing.normalize(
            input, match: match, target: target, store: store, excluding: nil)
        {
        case .failure(let failure):
            return RuleEditing.message(for: failure)
        case .success(let pattern):
            let rule = Rule(pattern: pattern, match: match, target: target)
            update { store in
                store.rules.insert(rule, at: store.endIndexOfGroup(target))
            }
            return nil
        }
    }

    /// Edits pattern and match of an existing rule. Returns an error message or nil.
    @discardableResult
    func updateRule(id: UUID, pattern input: String, match: RuleMatch) -> String? {
        guard let rule = store.rules.first(where: { $0.id == id }) else { return nil }
        switch RuleEditing.normalize(
            input, match: match, target: rule.target, store: store, excluding: id)
        {
        case .failure(let failure):
            return RuleEditing.message(for: failure)
        case .success(let pattern):
            update { store in
                guard let index = store.rules.firstIndex(where: { $0.id == id }) else { return }
                store.rules[index].pattern = pattern
                store.rules[index].match = match
            }
            return nil
        }
    }

    func setRuleEnabled(id: UUID, _ enabled: Bool) {
        update { store in
            guard let index = store.rules.firstIndex(where: { $0.id == id }) else { return }
            store.rules[index].isEnabled = enabled
        }
    }

    func setRuleNote(id: UUID, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        update { store in
            guard let index = store.rules.firstIndex(where: { $0.id == id }) else { return }
            store.rules[index].note = trimmed.isEmpty ? nil : trimmed
        }
    }

    func removeRule(id: UUID) {
        update { $0.rules.removeAll { $0.id == id } }
    }

    /// Moves a rule inside its group or to another group (a tunnel, or Direct — which turns
    /// it into an exception), placing it before `target` (another rule) or at the end of
    /// the group when `target` is nil.
    func moveRule(id: UUID, to group: RuleTarget, before target: UUID?) {
        guard id != target else { return }
        update { store in
            guard let index = store.rules.firstIndex(where: { $0.id == id }) else { return }
            var rule = store.rules.remove(at: index)
            rule.target = group
            if let target, let targetIndex = store.rules.firstIndex(where: { $0.id == target }),
                store.rules[targetIndex].target == group
            {
                store.rules.insert(rule, at: targetIndex)
            } else {
                store.rules.insert(rule, at: store.endIndexOfGroup(group))
            }
        }
    }

    func tunnelName(_ id: UUID) -> String {
        store.tunnel(id: id)?.name ?? "?"
    }

    func targetName(_ target: RuleTarget) -> String {
        switch target {
        case .direct: "Direct"
        case .tunnel(let id): tunnelName(id)
        }
    }
}

extension Store {
    /// Index right after the last rule of `target`'s group (or `rules.endIndex`).
    fileprivate func endIndexOfGroup(_ target: RuleTarget) -> Int {
        guard let last = rules.lastIndex(where: { $0.target == target }) else {
            return rules.endIndex
        }
        return last + 1
    }
}
