package core

import (
	"reflect"
	"testing"
	"time"
)

func TestBuildConnectionsSnapshotSetsExitAndOneWayFromFirstSeenAt(t *testing.T) {
	decoded, err := DecodeClashConnections([]byte(readFixture(t, "clash", "connections.json")))
	if err != nil {
		t.Fatal(err)
	}
	accumulator := NewTrafficAccumulator()
	accumulator.RestartConnections(t0)
	accumulator.Ingest(decoded.Connections, t0.Add(2*time.Second))
	later := t0.Add(12 * time.Second)
	accumulator.Ingest(decoded.Connections, later)
	snapshot := BuildConnectionsSnapshot(decoded.Connections, accumulator.FirstSeenAtByID(), later)
	if !snapshot.SampledAt.Equal(later) || len(snapshot.Connections) != len(decoded.Connections) {
		t.Fatalf("snapshot = %+v", snapshot)
	}
	byID := map[string]Connection{}
	for _, connection := range snapshot.Connections {
		byID[connection.ID] = connection
	}
	first := byID["0f8a9c8e-1d2b-4c3a-9e8f-7a6b5c4d3e2f"]
	if first.Exit != clashTunnelA || first.OneWay || first.DestinationPort != 443 || first.Rule != "rule_set=rules-t-"+clashTunnelA {
		t.Errorf("tcp connection = %+v", first)
	}
	oneWay := byID["d5c4b3a2-1f0e-4d9c-8b7a-6e5f4d3c2b1a"]
	if oneWay.Exit != clashTunnelA || !oneWay.OneWay || oneWay.Network != "udp" {
		t.Errorf("one-way connection = %+v", oneWay)
	}
	direct := byID["b3d2c1a0-7e6f-4d5c-8b9a-1f2e3d4c5b6a"]
	if direct.Exit != "direct" || direct.OneWay {
		t.Errorf("direct connection = %+v", direct)
	}
	nullChains := byID["9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d"]
	if nullChains.Exit != "direct" || nullChains.Chains == nil || len(nullChains.Chains) != 0 {
		t.Errorf("chain-less connection = %+v", nullChains)
	}
}

func TestBuildConnectionsSnapshotFirstSeenThisSampleIsNeverOneWay(t *testing.T) {
	// A UDP flow absent from firstSeenAt (never sampled before) ages from sampledAt
	// itself, so it cannot already be past OneWayUDPGrace.
	connection := ClashConnection{ID: "c1", Network: "udp", Upload: 500, Chains: []string{"direct"}}
	snapshot := BuildConnectionsSnapshot([]ClashConnection{connection}, map[string]time.Time{}, t0)
	if snapshot.Connections[0].OneWay {
		t.Error("a connection first seen this sample must not be one-way yet")
	}
}

func TestExitLabelPicksGroupOverTunnelOverBlockOverDirect(t *testing.T) {
	cases := map[string]string{
		"g-grp":             "grp",
		"t-" + clashTunnelA: clashTunnelA,
		"block":             "block",
		"direct":            "direct",
		"dns-out":           "direct",
	}
	for tag, want := range cases {
		if got := ExitLabel([]string{tag}); got != want {
			t.Errorf("ExitLabel([%q]) = %q, want %q", tag, got, want)
		}
	}
	if got := ExitLabel([]string{"t-" + clashTunnelA, "g-grp"}); got != "grp" {
		t.Errorf("group must win over tunnel in a chain: %q", got)
	}
	if got := ExitLabel(nil); got != "direct" {
		t.Errorf("ExitLabel(nil) = %q, want direct", got)
	}
}

func TestConnectionMarshalJSONNeverEmitsNullChains(t *testing.T) {
	connection := Connection{ID: "x", Exit: "direct"}
	data, err := MarshalWire(connection)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(string(data), `{"chains":[],"destinationIP":"","destinationPort":0,"download":0,"exit":"direct","host":"","id":"x","network":"","oneWay":false,"processPath":"","rule":"","rulePayload":"","start":"0001-01-01T00:00:00Z","upload":0}`) {
		t.Errorf("connection wire = %s", data)
	}
	empty := ConnectionsSnapshot{}
	data, err = MarshalWire(empty)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(string(data), `{"connections":[],"sampledAt":"0001-01-01T00:00:00Z"}`) {
		t.Errorf("empty snapshot wire = %s", data)
	}
}
