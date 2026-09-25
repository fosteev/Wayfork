package main

import (
	"reflect"
	"testing"

	"wayfork/service/internal/core"
)

func testConnections() []core.Connection {
	return []core.Connection{
		{ID: "tcp-tunnel", Network: "tcp", Exit: "tunnel-a", ProcessPath: `C:\Discord\Discord.exe`},
		{ID: "udp-tunnel-oneway", Network: "udp", Exit: "tunnel-a", OneWay: true, ProcessPath: `C:\Discord\Discord.exe`},
		{ID: "udp-tunnel-twoway", Network: "udp", Exit: "tunnel-a", OneWay: false, ProcessPath: `C:\Steam\steam.exe`},
		{ID: "tcp-direct", Network: "tcp", Exit: "direct", ProcessPath: `C:\Windows\System32\svchost.exe`},
		{ID: "udp-block", Network: "udp", Exit: "block", OneWay: true},
	}
}

func ids(connections []core.Connection) []string {
	result := make([]string, len(connections))
	for i, c := range connections {
		result[i] = c.ID
	}
	return result
}

func TestFilterConnectionsNoFilterKeepsEverything(t *testing.T) {
	got := filterConnections(testConnections(), connectionsFilter{})
	if !reflect.DeepEqual(ids(got), ids(testConnections())) {
		t.Errorf("got = %v", ids(got))
	}
}

func TestFilterConnectionsByProcessSubstringCaseInsensitive(t *testing.T) {
	got := filterConnections(testConnections(), connectionsFilter{process: "discord"})
	if !reflect.DeepEqual(ids(got), []string{"tcp-tunnel", "udp-tunnel-oneway"}) {
		t.Errorf("got = %v", ids(got))
	}
}

func TestFilterConnectionsByExit(t *testing.T) {
	if got := filterConnections(testConnections(), connectionsFilter{exit: "direct"}); !reflect.DeepEqual(ids(got), []string{"tcp-direct"}) {
		t.Errorf("direct = %v", ids(got))
	}
	if got := filterConnections(testConnections(), connectionsFilter{exit: "block"}); !reflect.DeepEqual(ids(got), []string{"udp-block"}) {
		t.Errorf("block = %v", ids(got))
	}
}

func TestFilterConnectionsUDPOnly(t *testing.T) {
	got := filterConnections(testConnections(), connectionsFilter{udp: true})
	if !reflect.DeepEqual(ids(got), []string{"udp-tunnel-oneway", "udp-tunnel-twoway", "udp-block"}) {
		t.Errorf("got = %v", ids(got))
	}
}

func TestFilterConnectionsOneWayOnly(t *testing.T) {
	got := filterConnections(testConnections(), connectionsFilter{oneWay: true})
	if !reflect.DeepEqual(ids(got), []string{"udp-tunnel-oneway", "udp-block"}) {
		t.Errorf("got = %v", ids(got))
	}
}

func TestFilterConnectionsCombinesEveryCriterion(t *testing.T) {
	got := filterConnections(testConnections(), connectionsFilter{exit: "tunnel-a", udp: true, oneWay: true})
	if !reflect.DeepEqual(ids(got), []string{"udp-tunnel-oneway"}) {
		t.Errorf("got = %v", ids(got))
	}
}

func TestFilterConnectionsNeverReturnsNil(t *testing.T) {
	if got := filterConnections(nil, connectionsFilter{}); got == nil {
		t.Error("filterConnections(nil, ...) must not be nil")
	}
	if got := filterConnections(testConnections(), connectionsFilter{process: "nomatch"}); got == nil || len(got) != 0 {
		t.Errorf("no-match filter = %#v", got)
	}
}
