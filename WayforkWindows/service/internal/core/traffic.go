package core

import "time"

// TrafficExit is where a connection left: a tunnel (by id) or everything else.
type TrafficExit struct {
	// Tunnel id; "" means Direct.
	Tunnel string
}

// DirectExit is the exit of `direct`, `block`, DNS and chain-less connections.
var DirectExit = TrafficExit{}

// ExitForChains attributes a connection: the first tunnel outbound in the chain wins.
func ExitForChains(chains []string) TrafficExit {
	for _, tag := range chains {
		if id, ok := TunnelIDFromOutboundTag(tag); ok {
			return TrafficExit{Tunnel: id}
		}
	}
	return DirectExit
}

type trafficBytes struct {
	down, up uint64
}

func (b *trafficBytes) add(other trafficBytes) {
	b.down += other.down
	b.up += other.up
}

// OneWayUDPGrace is how long a UDP flow may keep sending without a single byte back
// before it counts as one-way (H3, docs/design/05-daemon.md "Traffic sampling").
const OneWayUDPGrace = 10 * time.Second

type trafficSeen struct {
	exit     TrafficExit
	download uint64
	upload   uint64
	// When this connection id was first sampled; the dead-UDP age runs from here (H3).
	firstSeenAt time.Time
}

// TrafficAccumulator turns the cumulative per-connection counters of consecutive
// `/connections` samples into per-exit rates and running totals (docs/design/05-daemon.md,
// "Traffic sampling").
//
// A connection seen in two consecutive samples contributes `now − previous`; one seen for
// the first time contributes its full count; one that disappeared contributes nothing (at
// most a second of a closing connection's bytes is lost). Totals accumulate until Reset;
// RestartConnections forgets the per-connection map for a sing-box restart but keeps the
// totals.
type TrafficAccumulator struct {
	totals        map[TrafficExit]trafficBytes
	previous      map[string]trafficSeen
	lastSampledAt time.Time
	hasSample     bool
}

// NewTrafficAccumulator starts with nothing seen and zero totals.
func NewTrafficAccumulator() *TrafficAccumulator {
	return &TrafficAccumulator{
		totals: map[TrafficExit]trafficBytes{}, previous: map[string]trafficSeen{},
	}
}

// RestartConnections: sing-box (re)started at `at` — connection ids and counters start
// over, totals stay.
func (a *TrafficAccumulator) RestartConnections(at time.Time) {
	a.previous = map[string]trafficSeen{}
	a.lastSampledAt = at
	a.hasSample = true
}

// Reset: Turn Off — everything back to zero.
func (a *TrafficAccumulator) Reset() {
	a.totals = map[TrafficExit]trafficBytes{}
	a.previous = map[string]trafficSeen{}
	a.lastSampledAt = time.Time{}
	a.hasSample = false
}

// Ingest folds one sample in and returns the snapshot to push.
func (a *TrafficAccumulator) Ingest(connections []ClashConnection, now time.Time) TrafficSnapshot {
	interval := 0.0
	if a.hasSample {
		interval = max(0, now.Sub(a.lastSampledAt).Seconds())
	}
	deltas := map[TrafficExit]trafficBytes{}
	open := map[TrafficExit]int{}
	oneWayUDP := map[TrafficExit]int{}
	current := make(map[string]trafficSeen, len(connections))
	for _, connection := range connections {
		exit := ExitForChains(connection.Chains)
		delta := trafficBytes{down: connection.Download, up: connection.Upload}
		firstSeenAt := now
		if seen, ok := a.previous[connection.ID]; ok && seen.exit == exit {
			// Counters only grow; a smaller value means the id was reused.
			if connection.Download >= seen.download && connection.Upload >= seen.upload {
				delta = trafficBytes{down: connection.Download - seen.download, up: connection.Upload - seen.upload}
				firstSeenAt = seen.firstSeenAt
			}
		}
		total := deltas[exit]
		total.add(delta)
		deltas[exit] = total
		open[exit]++
		// Sent for OneWayUDPGrace with nothing back: a one-way UDP flow (H3).
		if connection.Network == "udp" && connection.Upload > 0 && connection.Download == 0 &&
			now.Sub(firstSeenAt) >= OneWayUDPGrace {
			oneWayUDP[exit]++
		}
		current[connection.ID] = trafficSeen{
			exit: exit, download: connection.Download, upload: connection.Upload, firstSeenAt: firstSeenAt,
		}
	}
	for exit, delta := range deltas {
		total := a.totals[exit]
		total.add(delta)
		a.totals[exit] = total
	}
	a.previous = current
	a.lastSampledAt = now
	a.hasSample = true

	counters := func(exit TrafficExit) TrafficCounters {
		total := a.totals[exit]
		delta := deltas[exit]
		result := TrafficCounters{
			DownTotal: total.down, UpTotal: total.up, Connections: open[exit],
			OneWayUDPFlows: oneWayUDP[exit],
		}
		if interval > 0 {
			result.DownBytesPerSecond = float64(delta.down) / interval
			result.UpBytesPerSecond = float64(delta.up) / interval
		}
		return result
	}
	tunnels := map[string]TrafficCounters{}
	for exit := range a.totals {
		if exit.Tunnel != "" {
			tunnels[exit.Tunnel] = counters(exit)
		}
	}
	for exit := range open {
		if exit.Tunnel != "" {
			tunnels[exit.Tunnel] = counters(exit)
		}
	}
	return TrafficSnapshot{
		SampledAt: NewTimestamp(now), Interval: interval, Tunnels: tunnels, Direct: counters(DirectExit),
	}
}
