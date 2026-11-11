import Foundation

/// Pure G1 conversion, including the old validator's disabled-first suppression.
enum LegacyListMigration {
    static func migrate(_ source: Store) -> Store {
        guard source.rules.allSatisfy({ $0.target != nil }),
            Set(source.rules.map(\.id)).count == source.rules.count
        else { return source }
        var result = source
        result.schemaVersion = 4
        result.lists = []
        result.rules = []
        let issues = LegacyRuleValidator.validate(source)
        let suppressed = Set(
            issues.compactMap { id, issues in
                issues.contains {
                    if case .duplicate = $0 { return true }
                    return false
                } ? id : nil
            })
        let exits: [RuleTarget] =
            source.tunnels.map { .tunnel($0.id) } + source.groups.map { .group($0.id) }
        let known = Set(exits + [.direct])
        let unknown = source.rules.compactMap(\.target).filter { !known.contains($0) }
            .reduce(into: [RuleTarget]()) { if !$0.contains($1) { $0.append($1) } }
        let normal = source.rules.filter { !suppressed.contains($0.id) }
        func add(_ rows: [Rule], target: RuleTarget, suffix: String = "", paused: Bool = false) {
            guard let first = rows.first else { return }
            let base =
                target.exitID.flatMap(source.exitName(id:))
                ?? (target.isDirect ? "Direct" : "Unknown exit")
            let name = result.availableListName(String(base.prefix(40 - suffix.count)) + suffix)
            result.lists.append(
                RuleList(
                    id: first.id, name: name, target: .exit(target), isEnabled: !paused,
                    showInMenu: !paused))
            result.rules.append(
                contentsOf: rows.map { row in
                    var row = row
                    row.listID = first.id
                    row.target = nil
                    return row
                })
        }
        add(normal.filter { $0.target == .direct }, target: .direct)
        for target in exits {
            let rows = normal.filter { $0.target == target }
            let narrowed = RuleNetwork.allCases.flatMap { network in
                rows.filter { $0.network == network }
            }
            add(
                narrowed, target: target,
                suffix: rows.contains { $0.network == nil } ? " — TCP/UDP" : "")
        }
        for target in exits {
            add(normal.filter { $0.target == target && $0.network == nil }, target: target)
        }
        for target in unknown { add(normal.filter { $0.target == target }, target: target) }
        for target in [.direct] + exits + unknown {
            add(
                source.rules.filter { $0.target == target && suppressed.contains($0.id) },
                target: target,
                suffix: " — Previously inactive", paused: true)
        }
        return result
    }
}
