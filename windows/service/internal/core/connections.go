package core

import "time"

// Connection is one entry of a connections snapshot: everything `wayforkctl connections`
// needs to answer "where does X's traffic go, by which rule, and is it one-way" (#2,
// docs/roadmap/versioned-app-paths-and-ctl-connections.md).
type Connection struct {
	ID              string
	Network         string
	Host            string
	DestinationIP   string
	DestinationPort int
	ProcessPath     string
	// Exit is the wire label: a tunnel id, a group id, "direct" or "block" (ExitLabel).
	Exit   string
	Chains []string
	// The rule sing-box matched and its payload, straight from the Clash API.
	Rule        string
	RulePayload string
	Upload      uint64
	Download    uint64
	Start       time.Time
	// OneWay is IsOneWayUDP for this connection's own firstSeenAt — the same rule
	// TrafficAccumulator.Ingest uses for an exit's aggregate oneWayUDPFlows, so the two
	// agree for the same sample.
	OneWay bool
}

// MarshalJSON never emits a null chains array.
func (c Connection) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"id": c.ID, "network": c.Network, "host": c.Host,
		"destinationIP": c.DestinationIP, "destinationPort": c.DestinationPort,
		"processPath": c.ProcessPath, "exit": c.Exit, "chains": nonNilSlice(c.Chains),
		"rule": c.Rule, "rulePayload": c.RulePayload, "upload": c.Upload, "download": c.Download,
		"start": NewTimestamp(c.Start), "oneWay": c.OneWay,
	})
}

// ConnectionsSnapshot is `wayforkctl connections`' reply: the sampler's last decoded
// sample, reduced to the wire shape. The zero value is the "not running yet" snapshot.
type ConnectionsSnapshot struct {
	SampledAt   Timestamp
	Connections []Connection
}

// MarshalJSON never emits a null connections array.
func (s ConnectionsSnapshot) MarshalJSON() ([]byte, error) {
	return MarshalWire(map[string]any{
		"sampledAt": s.SampledAt, "connections": nonNilSlice(s.Connections),
	})
}

// BuildConnectionsSnapshot turns one decoded `/connections` sample into the wire
// snapshot: each connection's exit (ExitLabel) and its own one-way flag (IsOneWayUDP),
// using firstSeenAt per connection id (TrafficAccumulator.FirstSeenAtByID) — a connection
// missing from firstSeenAt (first sight this sample) counts its age from sampledAt itself.
func BuildConnectionsSnapshot(connections []ClashConnection, firstSeenAt map[string]time.Time, sampledAt time.Time) ConnectionsSnapshot {
	result := make([]Connection, 0, len(connections))
	for _, connection := range connections {
		first, ok := firstSeenAt[connection.ID]
		if !ok {
			first = sampledAt
		}
		result = append(result, Connection{
			ID: connection.ID, Network: connection.Network, Host: connection.Host,
			DestinationIP: connection.DestinationIP, DestinationPort: connection.DestinationPort,
			ProcessPath: connection.ProcessPath, Exit: ExitLabel(connection.Chains),
			Chains: connection.Chains, Rule: connection.Rule, RulePayload: connection.RulePayload,
			Upload: connection.Upload, Download: connection.Download, Start: connection.Start,
			OneWay: IsOneWayUDP(connection, first, sampledAt),
		})
	}
	return ConnectionsSnapshot{SampledAt: NewTimestamp(sampledAt), Connections: result}
}
