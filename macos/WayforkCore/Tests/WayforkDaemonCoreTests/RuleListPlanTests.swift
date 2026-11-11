import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let rowID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
private let tunnelID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

private func rowPlanStore() -> Store {
    let work = Tunnel(
        id: tunnelID, name: "Work", slot: 0,
        kind: .openVPN(
            .init(remotes: [], needsCredentials: false, needsKeyPassphrase: false, configHash: "a"))
    )
    let home = Tunnel(id: otherID, name: "Home", slot: 1, kind: work.kind)
    let list = RuleList(name: "Work", target: .exit(.tunnel(tunnelID)))
    let other = RuleList(name: "Home", target: .exit(.tunnel(otherID)))
    return Store(
        tunnels: [work, home],
        rules: [
            Rule(id: rowID, pattern: "example.com", listID: list.id),
            Rule(pattern: "other.example", listID: other.id),
        ], lists: [list, other])
}

private func rowPlan(_ store: Store) -> RuntimePlan {
    RuntimePlanBuilder.build(
        store: store,
        secrets: .init(openVPNConfigs: [tunnelID: "client", otherID: "client"]),
        bundlePath: "/Applications/Wayfork.app"
    ).plan
}

@Test func rowPlanValidationRetainsLegacyNamesAndRejectsUnsafeRowNames() throws {
    let plan = rowPlan(rowPlanStore())
    try PlanValidator.validate(plan)
    let file = "rules-r-" + rowID.uuidString.lowercased() + ".json"
    #expect(plan.singBox.ruleSets[file] != nil)
    #expect(PlanValidator.rowRuleSetID(fromFileName: file) == rowID.uuidString.lowercased())
    #expect(RunLayout.isRuleSet(file))
    for unsafe in [
        "../" + file, file + "/../x", "rules-r-../etc/passwd.json",
        "rules-r-AAAAAAAA-0000-4000-8000-000000000101.json",
        "rules-r-" + rowID.uuidString.lowercased() + "-ip.json", "rules-r-not-a-uuid.json",
    ] {
        var changed = plan
        changed.singBox.ruleSets[unsafe] = "{}"
        #expect(throws: DaemonError.self) { try PlanValidator.validate(changed) }
        #expect(!RunLayout.isRuleSet(unsafe))
    }
    var legacy = plan
    legacy.singBox.ruleSets = [
        "rules-t-" + tunnelID.uuidString.lowercased() + ".json": "{}", "rules-direct-ip.json": "{}",
    ]
    try PlanValidator.validate(legacy)
    #expect(
        legacy.routedTunnelIDs == [tunnelID, otherID].map { $0.uuidString.lowercased() }.sorted())
}

@Test func rowPlansDiscoverAndProbeExitsWithoutRules() {
    var store = rowPlanStore()
    store.rules = []
    let group = TunnelGroup(name: "Group", members: [tunnelID, otherID], policy: .firstLive)
    store.groups = [group]
    let plan = rowPlan(store)
    #expect(plan.singBox.ruleSets.keys.sorted() == ["rules-direct.json"])
    #expect(
        plan.routedTunnelIDs == [tunnelID, otherID].map { $0.uuidString.lowercased() }.sorted())
    #expect(plan.routedGroupIDs == [group.id.uuidString.lowercased()])
    #expect(
        plan.singBox.groupOutbounds[group.id.uuidString.lowercased()]?.members
            == [tunnelID, otherID].map { $0.uuidString.lowercased() })
}

@Test func rowPlanReconcileDistinguishesPatternTargetOrderAndRemoval() throws {
    let store = rowPlanStore()
    let old = rowPlan(store)
    let state = ReconcileState(
        singBoxRunning: true, singBoxConfigHash: old.singBox.configHash,
        ruleSets: old.singBox.ruleSets)
    let file = "rules-r-" + rowID.uuidString.lowercased() + ".json"
    var pattern = store
    pattern.rules[0].pattern = "changed.example"
    let updated = rowPlan(pattern)
    #expect(updated.singBox.configHash == old.singBox.configHash)
    #expect(updated.planHash != old.planHash)
    #expect(rowPlan(pattern).planHash == updated.planHash)
    #expect(
        ReconcilePlanner.plan(from: state, to: updated).singBox == .rewriteRuleSets(files: [file]))
    let affected = try #require(
        RuleSetSelectors.change(
            from: old.singBox.ruleSets, to: updated.singBox.ruleSets, files: [file]))
    #expect(affected.matches(host: "api.example.com", destinationIP: "", processPath: ""))
    #expect(affected.matches(host: "changed.example", destinationIP: "", processPath: ""))
    #expect(!affected.matches(host: "unrelated.example", destinationIP: "", processPath: ""))
    var target = store
    try target.updateList(target.lists[0].id) { $0.target = .exit(.tunnel(otherID)) }
    #expect(ReconcilePlanner.plan(from: state, to: rowPlan(target)).singBox == .restart)
    var ordered = store
    try ordered.reorderList(ordered.lists[1].id, to: 0)
    #expect(ReconcilePlanner.plan(from: state, to: rowPlan(ordered)).singBox == .restart)
    var removed = store
    try removed.deleteList(removed.lists[0].id)
    let actions = ReconcilePlanner.plan(from: state, to: rowPlan(removed))
    #expect(actions.singBox == .restart)
    #expect(actions.staleRuleSets == [file])
}

@Test func singleRowSelectorsKeepExistingAppIPAndDomainMatcherShapes() throws {
    for rule in [
        Rule(pattern: "example.com", target: .direct),
        Rule(pattern: "/Applications/Chat.app", match: .app, target: .direct, network: .udp),
        Rule(pattern: "203.0.113.0/24", match: .ip, target: .direct, network: .tcp),
    ] {
        let text = try #require(RuleSetGenerator.renderRow(rule))
        let selectors = try #require(RuleSetSelectors.parse(text))
        switch rule.match {
        case .app:
            #expect(
                selectors.matches(
                    host: "", destinationIP: "",
                    processPath: "/Applications/Chat.app/Contents/MacOS/Chat"))
        case .ip:
            #expect(selectors.matches(host: "", destinationIP: "203.0.113.42", processPath: ""))
        default:
            #expect(selectors.matches(host: "api.example.com", destinationIP: "", processPath: ""))
        }
    }
}
