package main

import (
	"strings"

	"wayfork/service/internal/core"
)

// connectionsFilter is `wayforkctl connections`' client-side filter (#2's decisions: the
// pipe returns everything, wayforkctl narrows it down).
type connectionsFilter struct {
	// Process substring, case-insensitive; "" matches every process.
	process string
	// Exit id, or "direct"/"block"; "" matches every exit.
	exit string
	// UDP-only.
	udp bool
	// One-way UDP flows only.
	oneWay bool
}

// filterConnections keeps the connections that match every set criterion.
func filterConnections(connections []core.Connection, filter connectionsFilter) []core.Connection {
	result := make([]core.Connection, 0, len(connections))
	process := strings.ToLower(filter.process)
	for _, connection := range connections {
		if process != "" && !strings.Contains(strings.ToLower(connection.ProcessPath), process) {
			continue
		}
		if filter.exit != "" && connection.Exit != filter.exit {
			continue
		}
		if filter.udp && connection.Network != "udp" {
			continue
		}
		if filter.oneWay && !connection.OneWay {
			continue
		}
		result = append(result, connection)
	}
	return result
}
