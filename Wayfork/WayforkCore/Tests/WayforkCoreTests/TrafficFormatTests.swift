import Foundation
import Testing

@testable import WayforkCore

@Test func trafficBytesUseDecimalUnitsWithFixedDigits() {
    #expect(TrafficFormat.bytes(0) == "0 B")
    #expect(TrafficFormat.bytes(999) == "999 B")
    #expect(TrafficFormat.bytes(1000) == "1.0 KB")
    #expect(TrafficFormat.bytes(1234) == "1.2 KB")
    #expect(TrafficFormat.bytes(9949) == "9.9 KB")
    #expect(TrafficFormat.bytes(9950) == "10 KB")
    #expect(TrafficFormat.bytes(85_000) == "85 KB")
    #expect(TrafficFormat.bytes(123_456) == "123 KB")
    #expect(TrafficFormat.bytes(999_400) == "999 KB")
    #expect(TrafficFormat.bytes(999_500) == "1.0 MB")
    #expect(TrafficFormat.bytes(1_200_000) == "1.2 MB")
    #expect(TrafficFormat.bytes(12_000_000) == "12 MB")
    #expect(TrafficFormat.bytes(88_000_000) == "88 MB")
    #expect(TrafficFormat.bytes(1_200_000_000) == "1.2 GB")
    #expect(TrafficFormat.bytes(3_500_000_000_000) == "3.5 TB")
    #expect(TrafficFormat.bytes(UInt64.max) == "18447 PB")  // units stop at PB
}

@Test func trafficRateAndLabels() {
    #expect(TrafficFormat.rate(0) == "0 B/s")
    #expect(TrafficFormat.rate(1234.4) == "1.2 KB/s")
    #expect(TrafficFormat.rate(-5) == "0 B/s")
    #expect(TrafficFormat.rate(.nan) == "0 B/s")
    #expect(TrafficFormat.rate(.infinity) == "0 B/s")
    let counters = TrafficCounters(
        downBytesPerSecond: 1_200_000, upBytesPerSecond: 85_000, downTotal: 1_200_000_000,
        upTotal: 88_000_000, connections: 14)
    #expect(TrafficFormat.rateLabel(counters) == "↓ 1.2 MB/s ↑ 85 KB/s")
    #expect(TrafficFormat.rateLabel(nil) == "↓ — ↑ —")
    #expect(TrafficFormat.tooltip(counters) == "Since Turn On: ↓ 1.2 GB ↑ 88 MB · 14 connections")
    #expect(
        TrafficFormat.tooltip(TrafficCounters(connections: 1))
            == "Since Turn On: ↓ 0 B ↑ 0 B · 1 connection")
    #expect(TrafficFormat.directRowTitle(hasDefaultTunnel: false) == "Direct")
    #expect(TrafficFormat.directRowTitle(hasDefaultTunnel: true) == "Direct · exceptions")
    #expect(TrafficCounters.zero.isIdle)
    #expect(!counters.isIdle)
}
