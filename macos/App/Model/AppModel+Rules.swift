import Foundation
import WayforkCore

struct ListRouteUndo {
    let id = UUID()
    var listID: UUID
    var before: RuleListTarget
    var after: RuleListTarget
    var message: String
}

// Rule management: source membership and pins are independent of effective exits.

extension AppModel {
    var preferredRuleListID: UUID? {
        let saved = UserDefaults.standard.string(forKey: "ruleLists.lastUsed").flatMap(
            UUID.init(uuidString:))
        if let saved, store.list(id: saved) != nil { return saved }
        return store.lists.first(where: \.isEnabled)?.id ?? store.lists.first?.id
    }

    var menuRuleLists: [RuleList] {
        let switchedAt = UserDefaults.standard.dictionary(forKey: "ruleLists.switchedAt") ?? [:]
        return Array(
            store.lists.filter(\.showInMenu).sorted {
                let lhs = switchedAt[$0.id.uuidString] as? Double ?? 0
                let rhs = switchedAt[$1.id.uuidString] as? Double ?? 0
                return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs > rhs
            }.prefix(6))
    }

    func rememberRuleList(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: "ruleLists.lastUsed")
    }

    func changeListRoute(_ id: UUID, to target: RuleListTarget) {
        guard let list = store.list(id: id), list.target != target else { return }
        let edit = StoreEdit.setListTarget(id: id, from: list.target, to: target)
        update { _ = edit.apply(to: &$0) }
        var counts = UserDefaults.standard.dictionary(forKey: "ruleLists.switchedAt") ?? [:]
        counts[id.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(counts, forKey: "ruleLists.switchedAt")
        let undo = ListRouteUndo(
            listID: id, before: list.target, after: target,
            message: "\(list.name) → \(listTargetName(target))")
        listUndoTask?.cancel()
        listRouteUndo = undo
        listUndoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.listRouteUndo?.id == undo.id else { return }
            self?.listRouteUndo = nil
        }
    }

    func undoListRoute() {
        guard let undo = listRouteUndo else { return }
        update {
            _ = StoreEdit.setListTarget(id: undo.listID, from: undo.after, to: undo.before).apply(
                to: &$0)
        }
        listUndoTask?.cancel()
        listRouteUndo = nil
    }

    func listTargetName(_ target: RuleListTarget) -> String {
        switch target {
        case .everythingElse: "Everything else · \(targetName(store.resolvedTarget(target)))"
        case .exit(.direct): "Direct"
        case .exit(let exit): targetName(exit)
        }
    }

    func listNames(using target: RuleTarget) -> String {
        store.lists.filter { $0.isEnabled && store.resolvedTarget($0.target) == target }
            .map(\.name).joined(separator: ", ")
    }

    func listExitWarning(_ target: RuleTarget?) -> String? {
        guard let target, let id = target.exitID else { return nil }
        if let tunnel = store.tunnel(id: id) {
            if !tunnel.isEnabled { return "off — other lists, then Everything else" }
            if missingSecrets.contains(id) {
                return "needs its secret — other lists, then Everything else"
            }
            let summary = rowSummary(for: tunnel)
            return summary.isError ? "unreachable — matching connections fail" : nil
        }
        if let group = store.group(id: id) {
            if !group.isEnabled { return "off — other lists, then Everything else" }
            if !RuleValidator.availableExitIDs(store, missingSecrets: missingSecrets).contains(id) {
                return "no usable member — other lists, then Everything else"
            }
            return groupCard(for: group).isError
                ? "no member reachable — matching connections fail" : nil
        }
        return "missing exit — other lists, then Everything else"
    }

    @discardableResult
    func editRuleList(_ id: UUID, _ edit: (inout RuleList) -> Void) -> String? {
        var next = store
        do { try next.updateList(id, edit) } catch {
            return "Use a unique name of 1–40 characters and a valid color."
        }
        update { $0 = next }
        return nil
    }

    func reorderRuleList(_ id: UUID, before destination: UUID) {
        guard id != destination else { return }
        update { store in
            let remaining = store.lists.filter { $0.id != id }
            guard let position = remaining.firstIndex(where: { $0.id == destination }) else {
                return
            }
            try? store.reorderList(id, to: position)
        }
    }

    func moveRules(_ ids: Set<UUID>, to listID: UUID, before target: UUID? = nil) {
        update { try? $0.moveRules(ids, to: listID, before: target) }
    }

    func pinRule(_ id: UUID, to target: RuleTarget?) {
        update { try? $0.pinRule(id, to: target) }
    }

    func exitDeletionImpact(_ targets: Set<RuleTarget>) -> String {
        let bound = Set(
            store.lists.filter { list in
                if case .exit(let target) = list.target { return targets.contains(target) }
                return false
            }.map(\.id))
        let removed = store.rules.filter { row in
            if let pin = row.target { return targets.contains(pin) }
            return row.listID.map(bound.contains) == true
        }
        let affected = bound.union(removed.compactMap(\.listID))
        let names = store.lists.filter { affected.contains($0.id) }.map(\.name).joined(
            separator: ", ")
        return
            "Removes \(StatusText.count(removed.count, "rule")) in \(StatusText.count(affected.count, "list"))"
            + (names.isEmpty ? "." : " (\(names)).")
            + " List shells and pins to other exits stay; lists bound to a deleted exit show a missing-exit warning."
    }

    func deleteRuleList(_ id: UUID) {
        guard let list = store.list(id: id),
            Alerts.confirm(
                title: "Delete list",
                message:
                    "Delete \(list.name) and its \(StatusText.count(store.rules(in: id).count, "rule"))?",
                destructive: "Delete")
        else { return }
        update { try? $0.deleteList(id) }
    }

    @discardableResult
    func createRuleList(name: String, color: Int?, target: RuleListTarget, rows: [Rule]) -> String?
    {
        var next = store
        let list = RuleList(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines), color: color, target: target
        )
        do {
            try next.editLists { candidate in
                candidate.lists.insert(list, at: 0)
                for var row in rows {
                    row.listID = list.id
                    row.target = nil
                    candidate.rules.insert(row, at: candidate.endIndexOfList(list.id))
                }
            }
        } catch { return "Use a unique list name of 1–40 characters." }
        update { $0 = next }
        rememberRuleList(list.id)
        return nil
    }

    @discardableResult
    func quickAdd(input: String, listID: UUID) -> String? {
        var input = input
        var inferred: RuleMatch?
        if let message = translateFakeIP(&input, match: &inferred) { return message }
        switch QuickAdd.evaluate(input: input, listID: listID, store: store) {
        case .invalid(let message): return message
        case .add(let rule): update { $0.rules.insert(rule, at: $0.endIndexOfList(listID)) }
        case .update(let rule):
            update { store in
                guard let index = store.rules.firstIndex(where: { $0.id == rule.id }) else {
                    return
                }
                store.rules[index] = rule
            }
        }
        rememberRuleList(listID)
        return nil
    }

    @discardableResult
    func addRule(pattern input: String, match: RuleMatch, listID: UUID, network: RuleNetwork? = nil)
        -> String?
    {
        guard store.list(id: listID) != nil else { return "Choose a rule list" }
        var input = input
        var match = match
        if let message = translateFakeIP(&input, match: &match) { return message }
        switch RuleEditing.normalize(
            input, match: match, target: nil, store: store,
            excluding: nil, network: network, listID: listID)
        {
        case .failure(let failure): return RuleEditing.message(for: failure)
        case .success(let pattern):
            update {
                $0.rules.insert(
                    Rule(pattern: pattern, match: match, listID: listID, network: network),
                    at: $0.endIndexOfList(listID))
            }
            rememberRuleList(listID)
            return nil
        }
    }

    /// Quick add from the popover. Returns an error message or nil.
    @discardableResult
    func quickAdd(input: String, target: RuleTarget) -> String? {
        var input = input
        var inferred: RuleMatch?
        if let message = translateFakeIP(&input, match: &inferred) { return message }
        var candidate = store
        let listID = candidate.ensureList(for: target)
        if store.list(id: listID) == nil {
            // Keep creation and the row in one update.
            switch QuickAdd.evaluate(input: input, listID: listID, store: candidate) {
            case .invalid(let message): return message
            case .add(let rule), .update(let rule):
                candidate.rules.append(rule)
                update { $0 = candidate }
                rememberRuleList(listID)
                return nil
            }
        }
        return quickAdd(input: input, listID: listID)
    }

    /// Adds a rule at the end of a group. Returns an error message or nil.
    @discardableResult
    func addRule(
        pattern input: String, match: RuleMatch, target: RuleTarget, network: RuleNetwork? = nil
    ) -> String? {
        var input = input
        var match = match
        if let message = translateFakeIP(&input, match: &match) { return message }
        switch RuleEditing.normalize(
            input, match: match, target: target, store: store, excluding: nil, network: network)
        {
        case .failure(let failure):
            return RuleEditing.message(for: failure)
        case .success(let pattern):
            update { store in
                let listID = store.ensureList(for: target)
                let rule = Rule(pattern: pattern, match: match, listID: listID, network: network)
                store.rules.insert(rule, at: store.endIndexOfList(listID))
            }
            return nil
        }
    }

    /// Edits pattern and match of an existing rule; its network stays unless `network` is
    /// given (F23; dropped by the model when the new match is a domain kind). Returns an
    /// error message or nil.
    @discardableResult
    func updateRule(
        id: UUID, pattern input: String, match: RuleMatch, network: RuleNetwork?? = .none
    ) -> String? {
        var input = input
        var match = match
        if let message = translateFakeIP(&input, match: &match) { return message }
        guard let rule = store.rules.first(where: { $0.id == id }) else { return nil }
        let newNetwork = network ?? rule.network
        switch RuleEditing.normalize(
            input, match: match, target: rule.target, store: store, excluding: id,
            network: newNetwork)
        {
        case .failure(let failure):
            return RuleEditing.message(for: failure)
        case .success(let pattern):
            update { store in
                guard let index = store.rules.firstIndex(where: { $0.id == id }) else { return }
                store.rules[index].pattern = pattern
                store.rules[index].match = match
                store.rules[index].network = newNetwork
            }
            return nil
        }
    }

    /// F23: narrows an app or IP rule to one transport, or back to both with nil. Returns an
    /// error message when the same rule already exists with that network.
    @discardableResult
    func setNetwork(id: UUID, _ network: RuleNetwork?) -> String? {
        guard let rule = store.rules.first(where: { $0.id == id }) else { return nil }
        if case .failure(let failure) = RuleEditing.normalize(
            rule.pattern, match: rule.match, target: rule.target, store: store, excluding: id,
            network: network)
        {
            return RuleEditing.message(for: failure)
        }
        update { store in
            guard let index = store.rules.firstIndex(where: { $0.id == id }) else { return }
            store.rules[index].network = network
        }
        return nil
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
            let destination = store.ensureList(for: group)
            let position = target.flatMap { target in
                store.rules(in: destination).firstIndex { $0.id == target }
            }
            try? store.moveRule(id, to: destination, position: position)
        }
    }

    /// A pasted fake IP becomes the wildcard rule of the name behind it (`FakeIP`); the
    /// fields replace it live, this is the safety net for the submit path. Returns an error
    /// message for a fake IP the logs have not explained.
    private func translateFakeIP(_ input: inout String, match: inout RuleMatch) -> String? {
        var inferred: RuleMatch? = match
        let message = translateFakeIP(&input, match: &inferred)
        if let inferred { match = inferred }
        return message
    }

    func translateFakeIP(_ input: inout String, match: inout RuleMatch?) -> String? {
        switch FakeIP.translate(input, index: fakeIPs) {
        case nil:
            return nil
        case .unknown(let address):
            return FakeIP.message(forUnknown: address)
        case .pattern(let pattern, let name):
            logs.app(.info, "\(input) is the fake IP of \(name): using \(pattern)")
            input = pattern
            match = RulePattern.inferMatch(pattern)
            return nil
        }
    }

    func tunnelName(_ id: UUID) -> String {
        store.tunnel(id: id)?.name ?? "?"
    }

    func targetName(_ target: RuleTarget?) -> String {
        switch target {
        case nil: "Inherited"
        case .direct: "Not via any tunnel"
        case .tunnel(let id): tunnelName(id)
        case .group(let id): store.group(id: id)?.name ?? "Group"
        }
    }
}
