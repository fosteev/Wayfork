package service

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"wayfork/service/internal/core"
)

// clashHTTPClient talks to sing-box's Clash API on loopback only — never through a proxy.
func clashHTTPClient(timeout time.Duration) *http.Client {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.MaxConnsPerHost = 1
	return &http.Client{Transport: transport, Timeout: timeout}
}

func clashRequest(ctx context.Context, client *http.Client, method, url string, endpoint core.ClashAPIEndpoint) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, method, url, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+endpoint.Secret)
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 32<<20))
	if err != nil {
		return nil, err
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("http %d", response.StatusCode)
	}
	return body, nil
}

// ConnectionCloser closes connections through sing-box's Clash API after a rule-set
// rewrite (docs/design/05-daemon.md, "Connection cut on rule change").
type ConnectionCloser struct {
	client *http.Client
}

// NewConnectionCloser makes a closer with a 2 s request timeout.
func NewConnectionCloser() *ConnectionCloser {
	return &ConnectionCloser{client: clashHTTPClient(2 * time.Second)}
}

// Close closes the connections `change` covers — every connection when the change is
// unknown (nil) — and returns how many there were.
func (c *ConnectionCloser) Close(ctx context.Context, endpoint core.ClashAPIEndpoint, change *core.RuleSetSelectors) (int, error) {
	body, err := clashRequest(ctx, c.client, http.MethodGet, endpoint.ConnectionsURL(), endpoint)
	if err != nil {
		return 0, err
	}
	decoded, err := core.DecodeClashConnections(body)
	if err != nil {
		return 0, err
	}
	if change == nil {
		if _, err := clashRequest(ctx, c.client, http.MethodDelete, endpoint.ConnectionsURL(), endpoint); err != nil {
			return 0, err
		}
		return len(decoded.Connections), nil
	}
	closed := 0
	for _, connection := range decoded.Connections {
		if !change.Matches(connection.Host, connection.DestinationIP, connection.ProcessPath) {
			continue
		}
		if _, err := clashRequest(ctx, c.client, http.MethodDelete, endpoint.ConnectionsURL()+"/"+connection.ID, endpoint); err != nil {
			return closed, err
		}
		closed++
	}
	return closed, nil
}

const (
	samplerInterval       = time.Second
	samplerRequestTimeout = 900 * time.Millisecond
)

// TrafficSampler polls the Clash API once a second while sing-box runs and pushes
// per-exit aggregates to the subscribed clients (docs/design/05-daemon.md, "Traffic
// sampling"). Totals survive sing-box restarts (Pause + Start) and go back to zero on
// Reset (Turn Off).
type TrafficSampler struct {
	hub    *Hub
	clock  Clock
	client *http.Client

	mu          sync.Mutex
	accumulator *core.TrafficAccumulator
	prober      *LatencyProber
	// Domains that took the default route (F15); cleared with the connection map.
	recent      *core.RecentHosts
	defaultExit core.TrafficExit
	// Groups the plan routes (F16); each is asked once a second which member it uses.
	routedGroups []string
	// `Blocked N today` (F18): fed by the engine's log relay; reported only while counting.
	blocked       core.BlockCounter
	blockCounting bool
	// Connections that could not be established (F19), from the same relay.
	failed     *core.FailedConnections
	cancel     context.CancelFunc
	generation int
	failing    bool
	// Tunnels warned about one-way UDP flows; cleared when their count returns to zero,
	// so each streak logs once (H3).
	oneWayWarned map[string]bool
}

// NewTrafficSampler makes an idle sampler.
func NewTrafficSampler(hub *Hub, clock Clock) *TrafficSampler {
	if clock == nil {
		clock = SystemClock
	}
	return &TrafficSampler{
		hub: hub, clock: clock, client: clashHTTPClient(samplerRequestTimeout),
		accumulator: core.NewTrafficAccumulator(), oneWayWarned: map[string]bool{},
		prober: NewLatencyProber(hub, clock), recent: core.NewRecentHosts(),
		failed: core.NewFailedConnections(),
	}
}

// Prober is the latency prober the sampler starts and pauses with itself (F14).
func (s *TrafficSampler) Prober() *LatencyProber { return s.prober }

// SetDefaultExit sets where a flow no rule matched leaves (`route.final`); per plan.
func (s *TrafficSampler) SetDefaultExit(exit core.TrafficExit) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.defaultExit = exit
}

// SetRoutedGroups sets the groups in the plan (`RuntimePlan.RoutedGroupIDs`); per plan.
func (s *TrafficSampler) SetRoutedGroups(ids []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.routedGroups = ids
}

// SetBlockCounting says whether the plan has the block list and a log level that prints
// its matches (F18).
func (s *TrafficSampler) SetBlockCounting(enabled bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.blockCounting = enabled
	if !enabled {
		s.blocked.Reset()
	}
}

// Observe feeds one sing-box log line to the block counter and the failed-connection join.
func (s *TrafficSampler) Observe(line string, level core.LogLevel) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if core.IsBlockedLine(line) {
		s.blocked.Record(s.clock.Now())
	}
	message := core.SingBoxLogMessage(line)
	if core.IsInterestingLogLine(message) {
		s.failed.Ingest(message, level, s.clock.Now())
	}
}

// Start (re)starts polling `endpoint`; the per-connection map starts over.
func (s *TrafficSampler) Start(endpoint core.ClashAPIEndpoint) {
	s.Pause()
	s.mu.Lock()
	s.accumulator.RestartConnections(s.clock.Now())
	s.recent.Clear()
	s.generation++
	generation := s.generation
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.mu.Unlock()
	s.prober.Start(endpoint)
	go s.poll(ctx, endpoint, generation)
}

// Pause stops polling, keeps the totals.
func (s *TrafficSampler) Pause() {
	s.mu.Lock()
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	s.failing = false
	s.oneWayWarned = map[string]bool{}
	s.mu.Unlock()
	s.prober.Pause()
}

// Reset stops and forgets everything.
func (s *TrafficSampler) Reset() {
	s.Pause()
	s.prober.Reset()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.accumulator.Reset()
	s.recent.Clear()
	s.blocked.Reset()
	s.failed.Clear()
}

func (s *TrafficSampler) poll(ctx context.Context, endpoint core.ClashAPIEndpoint, generation int) {
	ticker := time.NewTicker(samplerInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		s.sample(ctx, endpoint, generation)
	}
}

func (s *TrafficSampler) sample(ctx context.Context, endpoint core.ClashAPIEndpoint, generation int) {
	body, err := clashRequest(ctx, s.client, http.MethodGet, endpoint.ConnectionsURL(), endpoint)
	var decoded core.ClashConnections
	if err == nil {
		decoded, err = core.DecodeClashConnections(body)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	// Paused or restarted while the request was in flight: drop the sample.
	if generation != s.generation || s.cancel == nil {
		return
	}
	if err != nil {
		if !s.failing && !errors.Is(err, context.Canceled) {
			s.failing = true
			s.hub.Log(core.LogLevelWarning, "traffic: clash api unreachable ("+err.Error()+")")
		}
		return
	}
	now := s.clock.Now()
	snapshot := s.accumulator.Ingest(decoded.Connections, now)
	snapshot.Latency = s.prober.Current()
	s.recent.Ingest(decoded.Connections, s.defaultExit, now)
	snapshot.RecentHosts = s.recent.Snapshot()
	routedGroups := append([]string(nil), s.routedGroups...)
	if s.blockCounting {
		blocked := s.blocked.Value(now)
		snapshot.BlockedToday = &blocked
	}
	snapshot.FailedHosts = s.failed.Snapshot()
	snapshot.Exits = s.failed.Exits()
	if s.failing {
		s.failing = false
		s.hub.Log(core.LogLevelInfo, "traffic: clash api reachable again")
	}
	s.warnAboutOneWayUDP(snapshot)
	s.mu.Unlock()
	// The group states are more requests: taken outside the lock like the sample itself.
	snapshot.Groups = s.groupStates(ctx, endpoint, routedGroups)
	s.mu.Lock()
	if generation != s.generation || s.cancel == nil {
		return
	}
	s.hub.PushTraffic(snapshot)
}

// groupStates asks `GET /proxies/g-<id>` for every routed group: the member sing-box is
// using right now (F16). A group that does not answer gets an entry without a member.
func (s *TrafficSampler) groupStates(ctx context.Context, endpoint core.ClashAPIEndpoint, ids []string) map[string]core.GroupState {
	states := make(map[string]core.GroupState, len(ids))
	for _, id := range ids {
		state := core.GroupState{}
		body, err := clashRequest(ctx, s.client, http.MethodGet, endpoint.ProxyURL(core.GroupOutboundTag(id)), endpoint)
		if err == nil {
			if proxy, err := core.DecodeClashProxy(body); err == nil {
				if member, ok := core.TunnelIDFromOutboundTag(proxy.Now); ok {
					state.ActiveMember = &member
				}
			}
		}
		states[id] = state
	}
	return states
}

// warnAboutOneWayUDP logs one WARNING per tunnel per streak when its one-way UDP count
// leaves zero — counts only, the flows' addresses stay with sing-box's own log (H3).
// Callers hold s.mu.
func (s *TrafficSampler) warnAboutOneWayUDP(snapshot core.TrafficSnapshot) {
	for id, counters := range snapshot.Tunnels {
		if counters.OneWayUDPFlows > 0 {
			if s.oneWayWarned[id] {
				continue
			}
			s.oneWayWarned[id] = true
			s.hub.Log(core.LogLevelWarning, fmt.Sprintf(
				"traffic: %d one-way udp flow(s) via t-%s — sending for %d s+ with nothing received; the server may be dropping UDP",
				counters.OneWayUDPFlows, id, int(core.OneWayUDPGrace/time.Second)))
		} else {
			delete(s.oneWayWarned, id)
		}
	}
}
