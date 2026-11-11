import Foundation

public enum RuleListTarget: Codable, Sendable, Hashable {
    case exit(RuleTarget)
    case everythingElse

    private enum CodingKeys: String, CodingKey { case kind, id }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "everythingElse": self = .everythingElse
        case "direct": self = .exit(.direct)
        case "tunnel": self = .exit(.tunnel(try c.decode(UUID.self, forKey: .id)))
        case "group": self = .exit(.group(try c.decode(UUID.self, forKey: .id)))
        default: throw StoreCodec.Error.invalidDocument
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .everythingElse: try c.encode("everythingElse", forKey: .kind)
        case .exit(.direct): try c.encode("direct", forKey: .kind)
        case .exit(.tunnel(let id)):
            try c.encode("tunnel", forKey: .kind)
            try c.encode(id, forKey: .id)
        case .exit(.group(let id)):
            try c.encode("group", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}

public struct RuleList: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: Int?
    public var target: RuleListTarget
    public var isEnabled: Bool
    public var showInMenu: Bool

    public init(
        id: UUID = UUID(), name: String, color: Int? = nil,
        target: RuleListTarget, isEnabled: Bool = true, showInMenu: Bool = true
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.target = target
        self.isEnabled = isEnabled
        self.showInMenu = showInMenu
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, target, tunnelID, groupID, isEnabled, showInMenu
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(Int.self, forKey: .color)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        showInMenu = try c.decode(Bool.self, forKey: .showInMenu)
        guard [CodingKeys.target, .tunnelID, .groupID].filter({ c.contains($0) }).count == 1
        else { throw StoreCodec.Error.invalidDocument }
        if let name = try c.decodeIfPresent(String.self, forKey: .target) {
            switch name {
            case "direct": target = .exit(.direct)
            case "everythingElse": target = .everythingElse
            default: throw StoreCodec.Error.invalidDocument
            }
        } else if let id = try c.decodeIfPresent(UUID.self, forKey: .tunnelID) {
            target = .exit(.tunnel(id))
        } else {
            target = .exit(.group(try c.decode(UUID.self, forKey: .groupID)))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(showInMenu, forKey: .showInMenu)
        switch target {
        case .everythingElse: try c.encode("everythingElse", forKey: .target)
        case .exit(.direct): try c.encode("direct", forKey: .target)
        case .exit(.tunnel(let id)): try c.encode(id, forKey: .tunnelID)
        case .exit(.group(let id)): try c.encode(id, forKey: .groupID)
        }
    }
}

public enum ListValidationError: Error, Sendable, Equatable {
    case duplicateListID, duplicateRuleID, invalidName, invalidColor, orphanRule, missingList,
        missingRule
}

extension Store {
    public func list(id: UUID) -> RuleList? { lists.first { $0.id == id } }
    public func rules(in listID: UUID) -> [Rule] { rules.filter { $0.listID == listID } }

    public func validateMembership() throws {
        guard Set(lists.map(\.id)).count == lists.count else {
            throw ListValidationError.duplicateListID
        }
        guard Set(rules.map(\.id)).count == rules.count else {
            throw ListValidationError.duplicateRuleID
        }
        var names: Set<String> = []
        for list in lists {
            guard list.name == list.name.trimmingCharacters(in: .whitespacesAndNewlines),
                (1...40).contains(list.name.count), names.insert(list.name.lowercased()).inserted
            else { throw ListValidationError.invalidName }
            if let color = list.color, !(0...7).contains(color) {
                throw ListValidationError.invalidColor
            }
        }
        let ids = Set(lists.map(\.id))
        guard rules.allSatisfy({ $0.listID.map(ids.contains) == true }) else {
            throw ListValidationError.orphanRule
        }
    }

    public func declaredTarget(for rule: Rule) -> RuleListTarget? {
        if let target = rule.target { return .exit(target) }
        return rule.listID.flatMap { list(id: $0)?.target }
    }

    public func target(for rule: Rule) -> RuleTarget? {
        declaredTarget(for: rule).map(resolvedTarget)
    }

    public func resolvedTarget(_ target: RuleListTarget) -> RuleTarget {
        switch target {
        case .exit(let exit): exit
        case .everythingElse:
            effectiveDefaultExit.map {
                switch $0 {
                case .tunnel(let t): .tunnel(t.id)
                case .group(let g): .group(g.id)
                }
            } ?? .direct
        }
    }

    /// Work on a value copy, then validate before replacing the caller's store.
    public mutating func editLists(_ edit: (inout Store) throws -> Void) throws {
        var next = self
        try edit(&next)
        try next.validateMembership()
        self = next
    }

    public mutating func createList(_ list: RuleList) throws {
        try editLists { $0.lists.insert(list, at: 0) }
    }
    public mutating func updateList(_ id: UUID, _ edit: (inout RuleList) -> Void) throws {
        try editLists {
            guard let i = $0.lists.firstIndex(where: { $0.id == id }) else {
                throw ListValidationError.missingList
            }
            edit(&$0.lists[i])
        }
    }
    public mutating func reorderList(_ id: UUID, to position: Int) throws {
        try editLists {
            guard let i = $0.lists.firstIndex(where: { $0.id == id }) else {
                throw ListValidationError.missingList
            }
            let list = $0.lists.remove(at: i)
            $0.lists.insert(list, at: min(max(0, position), $0.lists.count))
        }
    }
    public mutating func moveRule(_ id: UUID, to listID: UUID, position: Int? = nil) throws {
        try editLists {
            guard $0.list(id: listID) != nil else { throw ListValidationError.missingList }
            guard let i = $0.rules.firstIndex(where: { $0.id == id }) else {
                throw ListValidationError.missingRule
            }
            var row = $0.rules.remove(at: i)
            row.listID = listID
            let destinationRows = $0.rules
            let indices = destinationRows.indices.filter { destinationRows[$0].listID == listID }
            let offset = min(max(0, position ?? indices.count), indices.count)
            let insert =
                offset < indices.count
                ? indices[offset] : (indices.last.map { $0 + 1 } ?? $0.rules.count)
            $0.rules.insert(row, at: insert)
        }
    }
    /// Move a selection as one stable block, computing the destination after removal.
    public mutating func moveRules(_ ids: Set<UUID>, to listID: UUID, before target: UUID? = nil)
        throws
    {
        guard target.map(ids.contains) != true else { return }
        try editLists { store in
            guard store.list(id: listID) != nil else { throw ListValidationError.missingList }
            let rows = store.lists.flatMap { store.rules(in: $0.id) }.filter { ids.contains($0.id) }
            guard rows.count == ids.count else { throw ListValidationError.missingRule }
            store.rules.removeAll { ids.contains($0.id) }
            let index =
                target.flatMap { id in
                    store.rules.firstIndex { $0.id == id && $0.listID == listID }
                } ?? store.endIndexOfList(listID)
            store.rules.insert(
                contentsOf: rows.map { row in
                    var row = row
                    row.listID = listID
                    return row
                }, at: index)
        }
    }

    public mutating func pinRule(_ id: UUID, to target: RuleTarget?) throws {
        try editLists {
            guard let i = $0.rules.firstIndex(where: { $0.id == id }) else {
                throw ListValidationError.missingRule
            }
            $0.rules[i].target = target
        }
    }
    public mutating func deleteList(_ id: UUID) throws {
        try editLists {
            guard $0.list(id: id) != nil else { throw ListValidationError.missingList }
            $0.rules.removeAll { $0.listID == id }
            $0.lists.removeAll { $0.id == id }
        }
    }

    public func availableListName(_ requested: String) -> String {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "List" : trimmed
        var candidate = String(base.prefix(40))
        var n = 2
        while lists.contains(where: { $0.name.lowercased() == candidate.lowercased() }) {
            let suffix = " (\(n))"
            candidate = String(base.prefix(40 - suffix.count)) + suffix
            n += 1
        }
        return candidate
    }

    /// Compatibility entry point for callers that still choose an exit until stage 4.
    public mutating func ensureList(for target: RuleTarget) -> UUID {
        if let list = lists.first(where: { $0.target == .exit(target) }) { return list.id }
        let name =
            target.exitID.flatMap(exitName(id:)) ?? (target.isDirect ? "Direct" : "Unknown exit")
        let list = RuleList(name: availableListName(name), target: .exit(target))
        lists.insert(list, at: 0)
        return list.id
    }

    /// Keep shells and other pins when an exit is deleted.
    public mutating func removeRules(boundTo target: RuleTarget) {
        let boundLists = Set(lists.filter { $0.target == .exit(target) }.map(\.id))
        rules.removeAll { rule in
            rule.target == target
                || (rule.target == nil && rule.listID.map(boundLists.contains) == true)
        }
    }
}
