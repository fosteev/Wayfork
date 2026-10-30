import Foundation
import Testing
import WayforkCore

@testable import WayforkDaemonCore

private let idA = "aaaaaaaa-0000-0000-0000-000000000001"
private let idB = "aaaaaaaa-0000-0000-0000-000000000002"

private func plan(_ xray: [XrayRuntime]) -> RuntimePlan {
    RuntimePlan(singBox: SingBoxPlan(config: "{}", ruleSets: [:]), openVPN: [], xray: xray)
}

private func reason(of plan: RuntimePlan) -> String? {
    do {
        try PlanValidator.validate(plan)
        return nil
    } catch {
        if case .planInvalid(let reason) = error { return reason }
        return "other error"
    }
}

@Test func validXrayRuntimesPass() {
    #expect(reason(of: plan([])) == nil)
    #expect(
        reason(
            of: plan([
                XrayRuntime(id: idA, port: 47100, config: "{}"),
                XrayRuntime(id: idB, port: 47131, config: "{}"),
            ])) == nil)
}

@Test func xrayPortsOutsideTheSlotRangeAreRefused() throws {
    for port in [0, 1081, 47099, 47132, 65535] {
        let text = try #require(reason(of: plan([XrayRuntime(id: idA, port: port, config: "{}")])))
        #expect(text.contains("xray port \(port)"), "port \(port): \(text)")
    }
}

@Test func xrayRuntimesMustBeUniqueAndWellFormed() throws {
    let samePort = try #require(
        reason(
            of: plan([
                XrayRuntime(id: idA, port: 47100, config: "{}"),
                XrayRuntime(id: idB, port: 47100, config: "{}"),
            ])))
    #expect(samePort.contains("used twice"))
    let sameID = try #require(
        reason(
            of: plan([
                XrayRuntime(id: idA, port: 47100, config: "{}"),
                XrayRuntime(id: idA, port: 47101, config: "{}"),
            ])))
    #expect(sameID.contains("duplicate"))
    let badID = try #require(
        reason(of: plan([XrayRuntime(id: "../etc/passwd", port: 47100, config: "{}")])))
    #expect(badID.contains("not a lowercase UUID"))
    let upper = try #require(
        reason(of: plan([XrayRuntime(id: idA.uppercased(), port: 47100, config: "{}")])))
    #expect(upper.contains("not a lowercase UUID"))
}

@Test func xrayConfigSizeIsBounded() throws {
    let empty = try #require(reason(of: plan([XrayRuntime(id: idA, port: 47100, config: "")])))
    #expect(empty.contains("empty"))
    let nul = try #require(reason(of: plan([XrayRuntime(id: idA, port: 47100, config: "a\0b")])))
    #expect(nul.contains("NUL"))
    let huge = String(repeating: "x", count: RuntimePlan.maxConfigBytes + 1)
    let big = try #require(reason(of: plan([XrayRuntime(id: idA, port: 47100, config: huge)])))
    #expect(big.contains("limit"))
}

@Test func tooManyXrayRuntimesAreRefused() throws {
    let many = (0...RuntimePlan.maxTunnels).map { index in
        XrayRuntime(
            id: String(format: "aaaaaaaa-0000-0000-0000-%012x", index), port: 47100 + index % 32,
            config: "{}")
    }
    let text = try #require(reason(of: plan(many)))
    #expect(text.contains("exceed the limit"))
}
