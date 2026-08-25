import Foundation
import WayforkCore

// Rule management (F2): grouped by tunnel, ordered within the group.

extension AppModel {
    /// Quick add from the popover. Returns an error message or nil.
    @discardableResult
    func quickAdd(input: String, tunnelID: UUID) -> String? {
        switch QuickAdd.evaluate(input: input, tunnelID: tunnelID, store: store) {
        case .invalid(let message):
            return message
        case .add(let rule):
            update { $0.rules.append(rule) }
            logs.app(.info, "rule added: \(rule.pattern) → \(tunnelName(tunnelID))")
        case .update(let rule):
            update { store in
                guard let index = store.rules.firstIndex(where: { $0.id == rule.id }) else {
                    return
                }
                store.rules[index] = rule
            }
            logs.app(.info, "rule updated: \(rule.pattern) → \(tunnelName(tunnelID))")
        }
        quickAddTunnelID = tunnelID
        return nil
    }

    /// Adds a rule at the end of a tunnel's group. Returns an error message or nil.
    @discardableResult
    func addRule(pattern input: String, match: RuleMatch, tunnelID: UUID) -> String? {
        switch RuleEditing.normalize(
            input, match: match, tunnelID: tunnelID, store: store, excluding: nil)
        {
        case .failure(let failure):
            return RuleEditing.message(for: failure)
        case .success(let pattern):
            let rule = Rule(pattern: pattern, match: match, tunnelID: tunnelID)
            update { store in
                store.rules.insert(rule, at: store.endIndexOfGroup(tunnelID))
            }
            return nil
        }
    }

    /// Edits pattern and match of an existing rule. Returns an error message or nil.
    @discardableResult
    func updateRule(id: UUID, pattern input: String, match: RuleMatch) -> String? {
        guard let rule = store.rules.first(where: { $0.id == id }) else { return nil }
        switch RuleEditing.normalize(
            input, match: match, tunnelID: rule.tunnelID, store: store, excluding: id)
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

    /// Moves a rule inside its group or to another tunnel's group, placing it before
    /// `target` (another rule) or at the end of the group when `target` is nil.
    func moveRule(id: UUID, toTunnel tunnelID: UUID, before target: UUID?) {
        guard id != target else { return }
        update { store in
            guard let index = store.rules.firstIndex(where: { $0.id == id }) else { return }
            var rule = store.rules.remove(at: index)
            rule.tunnelID = tunnelID
            if let target, let targetIndex = store.rules.firstIndex(where: { $0.id == target }),
                store.rules[targetIndex].tunnelID == tunnelID
            {
                store.rules.insert(rule, at: targetIndex)
            } else {
                store.rules.insert(rule, at: store.endIndexOfGroup(tunnelID))
            }
        }
    }

    func tunnelName(_ id: UUID) -> String {
        store.tunnel(id: id)?.name ?? "?"
    }
}

extension Store {
    /// Index right after the last rule of `tunnelID` (or `rules.endIndex`).
    fileprivate func endIndexOfGroup(_ tunnelID: UUID) -> Int {
        guard let last = rules.lastIndex(where: { $0.tunnelID == tunnelID }) else {
            return rules.endIndex
        }
        return last + 1
    }
}
