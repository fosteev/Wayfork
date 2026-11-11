import Foundation
import Testing

@testable import WayforkCore

@Suite struct RuleListControlTests {
    @Test func pendingListBindingSurvivesRoundtripAndPreservesGUIFields() throws {
        let first = RuleList(name: "First", target: .exit(.direct))
        let second = RuleList(name: "Second", target: .everythingElse)
        let pin = Rule(pattern: "pin.example", target: .tunnel(UUID()), listID: first.id)
        var store = Store.empty
        store.lists = [first, second]
        store.rules = [pin]
        let pending = PendingControlChange(
            edit: .setListTarget(id: first.id, from: first.target, to: .everythingElse),
            description: "switch", deadline: Date(timeIntervalSince1970: 1000))
        let decoded = try JSONDecoder().decode(
            PendingControlChange.self,
            from: JSONEncoder().encode(pending))
        #expect(decoded == pending)
        #expect(decoded.edit.apply(to: &store) == nil)
        try store.updateList(first.id) {
            $0.name = "Renamed"
            $0.color = 3
            $0.showInMenu = false
        }
        try store.reorderList(first.id, to: 1)
        #expect(decoded.edit.inverse.apply(to: &store) == nil)
        #expect(store.lists.map(\.id) == [second.id, first.id])
        #expect(store.list(id: first.id)?.name == "Renamed")
        #expect(store.list(id: first.id)?.color == 3)
        #expect(store.list(id: first.id)?.showInMenu == false)
        #expect(store.list(id: first.id)?.target == first.target)
        #expect(store.rules == [pin])
        #expect(decoded.edit.apply(to: &store) == nil)
        try store.updateList(first.id) { $0.target = .exit(.group(UUID())) }
        let newer = store
        #expect(decoded.edit.inverse.apply(to: &store) != nil)
        #expect(store == newer)
        try store.deleteList(first.id)
        let deleted = store
        #expect(decoded.edit.inverse.apply(to: &store) != nil)
        #expect(store == deleted)
    }

    @Test func removedRowReturnsToItsOwnListNeighborAndNeverResurrectsAList() throws {
        let list = RuleList(name: "Selected", target: .everythingElse)
        let other = RuleList(name: "Other", target: .exit(.direct))
        var store = Store.empty
        store.lists = [list, other]
        let rows = ["a", "b", "c"].map { Rule(pattern: "\($0).example", listID: list.id) }
        store.rules = rows + [Rule(pattern: "b.example", listID: other.id)]
        let removal = StoreEdit.removal(of: rows[1], in: store)
        #expect(removal.apply(to: &store) == nil)
        try store.reorderList(list.id, to: 1)
        #expect(removal.inverse.apply(to: &store) == nil)
        #expect(store.rules(in: list.id) == rows)
        #expect(removal.apply(to: &store) == nil)
        try store.deleteList(list.id)
        let deleted = store
        #expect(removal.inverse.apply(to: &store) == "rule list is gone")
        #expect(store == deleted)
    }

    @Test func implicitListRollbackKeepsAnAdoptedShellAndIsAtomicOnChangedRow() throws {
        let list = RuleList(name: "Implicit", target: .exit(.direct))
        let row = Rule(pattern: "a.example", listID: list.id)
        let edit = StoreEdit.batch([.insertList(list), .insertRule(row, before: nil)])
        var store = Store.empty
        #expect(edit.apply(to: &store) == nil)
        try store.updateList(list.id) { $0.name = "Adopted" }
        #expect(edit.inverse.apply(to: &store) == nil)
        #expect(store.rules.isEmpty)
        #expect(store.list(id: list.id)?.name == "Adopted")
        store = .empty
        #expect(edit.apply(to: &store) == nil)
        store.rules[0].note = "GUI change"
        let changed = store
        #expect(edit.inverse.apply(to: &store) != nil)
        #expect(store == changed)
    }

    @Test func multiMoveRemovesTheWholeSelectionBeforeComputingInsertion() throws {
        let list = RuleList(name: "A", target: .everythingElse)
        let other = RuleList(name: "B", target: .exit(.direct))
        var store = Store.empty
        store.lists = [list, other]
        let rows = ["a", "b", "c", "d", "e"].map { Rule(pattern: "\($0).example", listID: list.id) }
        store.rules = rows
        try store.moveRules([rows[0].id, rows[1].id], to: list.id, before: rows[4].id)
        #expect(
            store.rules(in: list.id).map(\.pattern) == [
                "c.example", "d.example", "a.example", "b.example", "e.example",
            ])
        store.rules = rows
        try store.moveRules([rows[1].id, rows[3].id], to: list.id, before: rows[2].id)
        #expect(
            store.rules(in: list.id).map(\.pattern) == [
                "a.example", "b.example", "d.example", "c.example", "e.example",
            ])
        try store.pinRule(rows[1].id, to: .tunnel(UUID()))
        let pin = store.rules.first { $0.id == rows[1].id }?.target
        try store.moveRules([rows[1].id, rows[3].id], to: other.id)
        #expect(store.rules(in: other.id).map(\.id) == [rows[1].id, rows[3].id])
        #expect(store.rules(in: other.id).first?.target == pin)
        try store.validateMembership()
    }

    @Test func quickAddScopesUpdatesToMembershipAndClearsOnlyThatPin() throws {
        let list = RuleList(name: "A", target: .everythingElse)
        let other = RuleList(name: "B", target: .exit(.direct))
        let elsewhere = Rule(pattern: "example.com", target: .direct, listID: other.id)
        var store = Store.empty
        store.lists = [list, other]
        store.rules = [elsewhere]
        guard
            case .add(let added) = QuickAdd.evaluate(
                input: "example.com", listID: list.id, store: store)
        else {
            Issue.record("equal pattern in another list must not be updated")
            return
        }
        #expect(added.listID == list.id)
        store.rules.append(added)
        try store.pinRule(added.id, to: .tunnel(UUID()))
        guard
            case .update(let updated) = QuickAdd.evaluate(
                input: "example.com", listID: list.id, store: store)
        else {
            Issue.record("selected membership must update")
            return
        }
        #expect(updated.id == added.id)
        #expect(updated.target == nil)
        #expect(store.rules.first == elsewhere)
        let info = ControlRuleInfo(updated, via: "direct", store: store)
        #expect(info.listID == list.id && info.listName == "A")
        #expect(info.pinned == false && info.declaredTarget == .everythingElse)
    }

    @Test func listMethodsAndSelectionHaveExplicitWireIdentity() throws {
        let request = ControlRequest(
            method: .rulesAdd,
            params: ControlParams(pattern: "example.com", list: "Selected"))
        #expect(try ControlWire.decodeRequest(ControlWire.encodeRequest(request)) == request)
        let set = ControlRequest(
            method: .listsSet, params: ControlParams(via: "default", list: "Selected"))
        #expect(try ControlWire.decodeRequest(ControlWire.encodeRequest(set)) == set)
        #expect(ControlMethod.listsList.rawValue == "lists.list")
        #expect(throws: ControlError.self) {
            try ControlWire.decodeRequest(
                Data(#"{"id":1,"method":"future.method","params":{}}"#.utf8))
        }
    }
}

extension RuleListControlTests {
    @Test func confirmOwnsTheJournalUntilDurableAndDeadlineCannotRevertConcurrently() {
        let list = UUID()
        let pending = PendingControlChange(
            edit: .setListTarget(id: list, from: .exit(.direct), to: .everythingElse),
            description: "switch", deadline: Date(timeIntervalSince1970: 1000))
        var gate = ControlResolutionGate()
        let began1 = gate.begin(.confirm, pending: pending)
        #expect(began1)
        // The deadline fires while confirm awaits the disk. It must wait, not undo.
        let began2 = gate.begin(.revert, pending: pending)
        #expect(!began2)
        let began3 = gate.begin(.confirm, pending: pending)
        #expect(!began3)
        #expect(gate.owns(pending, current: pending))
        gate.end(pending)
        #expect(!gate.isBusy)
        #expect(!gate.owns(pending, current: nil))
        // A failed confirm releases ownership; the still-pending deadline may retry.
        let began4 = gate.begin(.revert, pending: pending)
        #expect(began4)
        #expect(gate.action == .revert)
    }

    @Test func staleFinalizationCannotClearOrReleaseANewerJournal() {
        let pending = PendingControlChange(
            edit: .setLogLevel(from: .info, to: .debug), description: "old",
            deadline: Date(timeIntervalSince1970: 1000))
        let newer = PendingControlChange(
            edit: .setLogLevel(from: .debug, to: .warning), description: "new",
            deadline: Date(timeIntervalSince1970: 2000))
        var gate = ControlResolutionGate()
        let began5 = gate.begin(.revert, pending: pending)
        #expect(began5)
        #expect(!gate.owns(pending, current: newer))
        gate.end(pending)
        let began6 = gate.begin(.confirm, pending: newer)
        #expect(began6)
        gate.end(pending)
        #expect(gate.isBusy)
        #expect(gate.owns(newer, current: newer))
        #expect(!gate.owns(pending, current: newer))
    }
}
