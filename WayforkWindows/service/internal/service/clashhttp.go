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
	cancel      context.CancelFunc
	generation  int
	failing     bool
}

// NewTrafficSampler makes an idle sampler.
func NewTrafficSampler(hub *Hub, clock Clock) *TrafficSampler {
	if clock == nil {
		clock = SystemClock
	}
	return &TrafficSampler{
		hub: hub, clock: clock, client: clashHTTPClient(samplerRequestTimeout),
		accumulator: core.NewTrafficAccumulator(),
	}
}

// Start (re)starts polling `endpoint`; the per-connection map starts over.
func (s *TrafficSampler) Start(endpoint core.ClashAPIEndpoint) {
	s.Pause()
	s.mu.Lock()
	s.accumulator.RestartConnections(s.clock.Now())
	s.generation++
	generation := s.generation
	ctx, cancel := context.WithCancel(context.Background())
	s.cancel = cancel
	s.mu.Unlock()
	go s.poll(ctx, endpoint, generation)
}

// Pause stops polling, keeps the totals.
func (s *TrafficSampler) Pause() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	s.failing = false
}

// Reset stops and forgets everything.
func (s *TrafficSampler) Reset() {
	s.Pause()
	s.mu.Lock()
	defer s.mu.Unlock()
	s.accumulator.Reset()
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
	snapshot := s.accumulator.Ingest(decoded.Connections, s.clock.Now())
	if s.failing {
		s.failing = false
		s.hub.Log(core.LogLevelInfo, "traffic: clash api reachable again")
	}
	s.hub.PushTraffic(snapshot)
}
