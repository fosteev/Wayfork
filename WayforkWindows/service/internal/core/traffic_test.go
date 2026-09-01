package core

import (
	"testing"
	"time"
)

var t0 = time.Unix(1_756_140_000, 0).UTC()

func connection(id string, chains []string, up, down uint64) ClashConnection {
	return ClashConnection{ID: id, Chains: chains, Upload: up, Download: down}
}

func TestAccumulatorAttributesTheFixtureAndRatesTheFirstSample(t *testing.T) {
	decoded, err := DecodeClashConnections([]byte(readFixture(t, "clash", "connections.json")))
	if err != nil {
		t.Fatal(err)
	}
	accumulator := NewTrafficAccumulator()
	accumulator.RestartConnections(t0)
	snapshot := accumulator.Ingest(decoded.Connections, t0.Add(2*time.Second))
	if snapshot.Interval != 2 || !snapshot.SampledAt.Equal(t0.Add(2*time.Second)) {
		t.Errorf("interval %v at %v", snapshot.Interval, snapshot.SampledAt)
	}
	a := snapshot.CountersForTunnel(clashTunnelA)
	if a.DownTotal != 1048576 || a.UpTotal != 4096+15360 || a.DownBytesPerSecond != 524288 || a.UpBytesPerSecond != 2048+7680 || a.Connections != 2 {
		t.Errorf("tunnel A = %+v", a)
	}
	// The one-way UDP flow is younger than the grace on the first sample.
	if a.OneWayUDPFlows != 0 {
		t.Errorf("tunnel A one-way = %d", a.OneWayUDPFlows)
	}
	b := snapshot.CountersForTunnel(clashTunnelB)
	if b.DownTotal != 524288 || b.Connections != 1 {
		t.Errorf("tunnel B = %+v", b)
	}
	// direct + dns-out + the chain-less one
	if snapshot.Direct.DownTotal != 65536+128 || snapshot.Direct.UpTotal != 512+64 || snapshot.Direct.Connections != 3 {
		t.Errorf("direct = %+v", snapshot.Direct)
	}
	if snapshot.CountersForTunnel("missing") != (TrafficCounters{}) || len(snapshot.Tunnels) != 2 {
		t.Errorf("tunnels = %+v", snapshot.Tunnels)
	}

	// Ten seconds on: the same up-only UDP flow through tunnel A is now one-way.
	later := accumulator.Ingest(decoded.Connections, t0.Add(12*time.Second))
	if later.CountersForTunnel(clashTunnelA).OneWayUDPFlows != 1 ||
		later.CountersForTunnel(clashTunnelB).OneWayUDPFlows != 0 || later.Direct.OneWayUDPFlows != 0 {
		t.Errorf("one-way counts = %+v / %+v", later.Tunnels, later.Direct)
	}
}

func TestAccumulatorFlagsOneWayUDPOnlyAfterTheGraceAndClearsOnReplies(t *testing.T) {
	accumulator := NewTrafficAccumulator()
	accumulator.RestartConnections(t0)
	udp := func(down uint64, at time.Duration) TrafficCounters {
		connections := []ClashConnection{{
			ID: "c1", Chains: []string{"t-" + clashTunnelA}, Upload: 500, Download: down, Network: "udp",
		}}
		return accumulator.Ingest(connections, t0.Add(at)).CountersForTunnel(clashTunnelA)
	}
	if udp(0, 1*time.Second).OneWayUDPFlows != 0 {
		t.Error("flagged on first sight")
	}
	if udp(0, 10*time.Second).OneWayUDPFlows != 0 {
		t.Error("flagged at age 9 s")
	}
	if udp(0, 11*time.Second).OneWayUDPFlows != 1 {
		t.Error("not flagged at age 10 s")
	}
	// A single byte back clears it for the connection's lifetime.
	if udp(1, 12*time.Second).OneWayUDPFlows != 0 || udp(1, 30*time.Second).OneWayUDPFlows != 0 {
		t.Error("still flagged after a reply")
	}
}

func TestAccumulatorIgnoresTCPAndRestartsTheOneWayClockForReusedIDs(t *testing.T) {
	accumulator := NewTrafficAccumulator()
	accumulator.RestartConnections(t0)
	tcp := ClashConnection{ID: "c1", Chains: []string{"t-" + clashTunnelA}, Upload: 500, Network: "tcp"}
	accumulator.Ingest([]ClashConnection{tcp}, t0.Add(1*time.Second))
	if got := accumulator.Ingest([]ClashConnection{tcp}, t0.Add(20*time.Second)); got.CountersForTunnel(clashTunnelA).OneWayUDPFlows != 0 {
		t.Error("tcp flagged")
	}
	// A UDP flow whose counters shrank is a reused id: its age starts over.
	udp := ClashConnection{ID: "c2", Chains: []string{"t-" + clashTunnelA}, Upload: 500, Network: "udp"}
	accumulator.Ingest([]ClashConnection{tcp, udp}, t0.Add(21*time.Second))
	reused := udp
	reused.Upload = 5
	if got := accumulator.Ingest([]ClashConnection{tcp, reused}, t0.Add(32*time.Second)); got.CountersForTunnel(clashTunnelA).OneWayUDPFlows != 0 {
		t.Error("reused id kept its age")
	}
	// A one-way UDP flow on Direct is counted there, not on any tunnel.
	fresh := NewTrafficAccumulator()
	fresh.RestartConnections(t0)
	direct := ClashConnection{ID: "c3", Chains: []string{"direct"}, Upload: 64, Network: "udp"}
	fresh.Ingest([]ClashConnection{direct}, t0.Add(1*time.Second))
	later := fresh.Ingest([]ClashConnection{direct}, t0.Add(11*time.Second))
	if later.Direct.OneWayUDPFlows != 1 || len(later.Tunnels) != 0 {
		t.Errorf("direct one-way = %+v / %+v", later.Direct, later.Tunnels)
	}
}

func TestAccumulatorUsesDeltasForConnectionsSeenBefore(t *testing.T) {
	accumulator := NewTrafficAccumulator()
	accumulator.RestartConnections(t0)
	accumulator.Ingest([]ClashConnection{connection("c1", []string{"t-" + clashTunnelA}, 100, 1000)}, t0.Add(time.Second))
	second := accumulator.Ingest([]ClashConnection{
		connection("c1", []string{"t-" + clashTunnelA}, 150, 1500),
		connection("c2", []string{"direct"}, 10, 20),
	}, t0.Add(3*time.Second))
	if second.Interval != 2 {
		t.Errorf("interval = %v", second.Interval)
	}
	a := second.CountersForTunnel(clashTunnelA)
	if a.DownTotal != 1500 || a.UpTotal != 150 || a.DownBytesPerSecond != 250 || a.UpBytesPerSecond != 25 {
		t.Errorf("tunnel A = %+v", a)
	}
	if second.Direct.DownTotal != 20 || second.Direct.DownBytesPerSecond != 10 || second.Direct.Connections != 1 {
		t.Errorf("direct = %+v", second.Direct)
	}
	// c1 closed: nothing more is added, the rate drops to zero, totals stay.
	third := accumulator.Ingest([]ClashConnection{connection("c2", []string{"direct"}, 10, 20)}, t0.Add(4*time.Second))
	a3 := third.CountersForTunnel(clashTunnelA)
	if a3.DownTotal != 1500 || !a3.IsIdle() || a3.Connections != 0 {
		t.Errorf("closed tunnel A = %+v", a3)
	}
	if !third.Direct.IsIdle() || third.Direct.Connections != 1 {
		t.Errorf("direct = %+v", third.Direct)
	}
}

func TestAccumulatorTotalsSurviveRestartsAndResetOnStop(t *testing.T) {
	accumulator := NewTrafficAccumulator()
	accumulator.RestartConnections(t0)
	accumulator.Ingest([]ClashConnection{connection("c1", []string{"t-" + clashTunnelA}, 100, 1000)}, t0.Add(time.Second))
	// sing-box restarted: the same id reappears with smaller counters → counted in full.
	accumulator.RestartConnections(t0.Add(5 * time.Second))
	afterRestart := accumulator.Ingest([]ClashConnection{connection("c1", []string{"t-" + clashTunnelA}, 5, 50)}, t0.Add(6*time.Second))
	if afterRestart.Interval != 1 || afterRestart.CountersForTunnel(clashTunnelA).DownTotal != 1050 || afterRestart.CountersForTunnel(clashTunnelA).DownBytesPerSecond != 50 {
		t.Errorf("after restart = %+v", afterRestart)
	}
	accumulator.Reset()
	accumulator.RestartConnections(t0.Add(10 * time.Second))
	fresh := accumulator.Ingest(nil, t0.Add(11*time.Second))
	if len(fresh.Tunnels) != 0 || fresh.Direct != (TrafficCounters{}) {
		t.Errorf("after reset = %+v", fresh)
	}
}

func TestAccumulatorHandlesReusedIDsAndExitChanges(t *testing.T) {
	accumulator := NewTrafficAccumulator()
	accumulator.RestartConnections(t0)
	accumulator.Ingest([]ClashConnection{connection("c1", []string{"t-" + clashTunnelA}, 100, 1000)}, t0.Add(time.Second))
	// Counter went backwards under the same id: treated as a new connection.
	reused := accumulator.Ingest([]ClashConnection{connection("c1", []string{"t-" + clashTunnelA}, 10, 20)}, t0.Add(2*time.Second))
	if reused.CountersForTunnel(clashTunnelA).DownTotal != 1020 {
		t.Errorf("reused = %+v", reused.CountersForTunnel(clashTunnelA))
	}
	// Same id now on another exit: full count on the new exit, nothing on the old one.
	moved := accumulator.Ingest([]ClashConnection{connection("c1", []string{"direct"}, 10, 30)}, t0.Add(3*time.Second))
	if moved.CountersForTunnel(clashTunnelA).DownTotal != 1020 || !moved.CountersForTunnel(clashTunnelA).IsIdle() || moved.Direct.DownTotal != 30 {
		t.Errorf("moved = %+v / %+v", moved.CountersForTunnel(clashTunnelA), moved.Direct)
	}
}

func TestAccumulatorWithoutAStartTimeReportsZeroRates(t *testing.T) {
	accumulator := NewTrafficAccumulator()
	snapshot := accumulator.Ingest([]ClashConnection{connection("c1", []string{"direct"}, 1, 2)}, t0)
	if snapshot.Interval != 0 || !snapshot.Direct.IsIdle() || snapshot.Direct.DownTotal != 2 {
		t.Errorf("snapshot = %+v", snapshot)
	}
	if got := mustMarshal(t, snapshot); got != `{"direct":{"connections":1,"downBytesPerSecond":0,"downTotal":2,"oneWayUDPFlows":0,"upBytesPerSecond":0,"upTotal":1},"interval":0,"sampledAt":"2025-08-25T16:40:00Z","tunnels":{}}` {
		t.Errorf("snapshot wire = %s", got)
	}
}
