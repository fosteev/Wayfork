package service

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"sort"
	"sync"
	"time"

	"wayfork/service/internal/core"
)

// LatencyProber measures every connected tunnel through sing-box's Clash API delay endpoint
// once per probe interval (F14, docs/design/05-daemon.md, "Tunnel latency") and, after
// every round, points each *first live* group at the first member whose probe passed (F16).
// The results ride in the traffic snapshot; the sampler starts and pauses the prober.
type LatencyProber struct {
	hub    *Hub
	clock  Clock
	client *http.Client

	mu         sync.Mutex
	tracker    *core.LatencyTracker
	tunnels    func() []string
	groups     func() map[string][]string
	cancel     context.CancelFunc
	generation int
}

// NewLatencyProber makes an idle prober.
func NewLatencyProber(hub *Hub, clock Clock) *LatencyProber {
	if clock == nil {
		clock = SystemClock
	}
	return &LatencyProber{
		hub: hub, clock: clock,
		// sing-box enforces the probe timeout itself; the request budget is a little wider.
		client:  clashHTTPClient(time.Duration(core.ProbeTimeoutSeconds+2) * time.Second),
		tracker: core.NewLatencyTracker(),
		tunnels: func() []string { return nil },
		groups:  func() map[string][]string { return nil },
	}
}

// SetTunnelSource sets who to probe: routed by the plan, connected when OpenVPN.
func (p *LatencyProber) SetTunnelSource(source func() []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.tunnels = source
}

// SetGroupSource sets the *first live* groups (selector outbounds) with their members.
func (p *LatencyProber) SetGroupSource(source func() map[string][]string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.groups = source
}

// Start (re)starts the rounds; histories start over, the first round runs at once.
func (p *LatencyProber) Start(endpoint core.ClashAPIEndpoint) {
	p.Pause()
	p.mu.Lock()
	p.tracker.Clear()
	p.generation++
	generation := p.generation
	ctx, cancel := context.WithCancel(context.Background())
	p.cancel = cancel
	p.mu.Unlock()
	go p.rounds(ctx, endpoint, generation)
}

// Pause stops the rounds; histories are cleared on the next start.
func (p *LatencyProber) Pause() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cancel != nil {
		p.cancel()
		p.cancel = nil
	}
}

// Reset stops and forgets everything.
func (p *LatencyProber) Reset() {
	p.Pause()
	p.mu.Lock()
	defer p.mu.Unlock()
	p.tracker.Clear()
}

// Current returns the latest samples for the snapshot.
func (p *LatencyProber) Current() map[string]core.LatencySample {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.tracker.Samples()
}

// Retry lets the next round decide afresh for one tunnel.
func (p *LatencyProber) Retry(tunnel string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.tracker.ResetStreak(tunnel)
}

func (p *LatencyProber) rounds(ctx context.Context, endpoint core.ClashAPIEndpoint, generation int) {
	for {
		p.round(ctx, endpoint, generation)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Duration(core.ProbeIntervalSeconds) * time.Second):
		}
	}
}

func (p *LatencyProber) alive(generation int) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return generation == p.generation && p.cancel != nil
}

func (p *LatencyProber) round(ctx context.Context, endpoint core.ClashAPIEndpoint, generation int) {
	p.mu.Lock()
	ids := p.tunnels()
	retained := make(map[string]bool, len(ids))
	for _, id := range ids {
		retained[id] = true
	}
	p.tracker.Retain(retained)
	p.mu.Unlock()
	for _, id := range ids {
		if !p.alive(generation) {
			return
		}
		milliseconds := p.probe(ctx, id, endpoint)
		if !p.alive(generation) {
			return
		}
		p.mu.Lock()
		transition := p.tracker.Record(id, milliseconds, p.clock.Now())
		p.mu.Unlock()
		if transition == nil {
			continue
		}
		if transition.BecameUnreachable {
			p.hub.Log(core.LogLevelWarning, fmt.Sprintf("probe: t-%s unreachable after %d failures", id, transition.Failures))
		} else {
			p.hub.Log(core.LogLevelInfo, fmt.Sprintf("probe: t-%s reachable again (%d ms)", id, transition.Milliseconds))
		}
	}
	p.selectFirstLive(ctx, endpoint, generation)
}

// probe is one request through the tunnel; nil when sing-box reports a failure or a timeout.
func (p *LatencyProber) probe(ctx context.Context, id string, endpoint core.ClashAPIEndpoint) *int {
	url := endpoint.DelayURL(core.OutboundTag(id), core.ProbeURL, time.Duration(core.ProbeTimeoutSeconds)*time.Second)
	body, err := clashRequest(ctx, p.client, http.MethodGet, url, endpoint)
	if err == nil {
		var delay int
		if delay, err = core.DecodeClashDelay(body); err == nil {
			return &delay
		}
	}
	p.hub.Log(core.LogLevelDebug, fmt.Sprintf("probe: t-%s failed (%s)", id, err.Error()))
	return nil
}

// selectFirstLive points every *first live* group at the first member whose latest probe
// passed — only when sing-box's `now` differs (docs/design/05-daemon.md, "Group selection").
func (p *LatencyProber) selectFirstLive(ctx context.Context, endpoint core.ClashAPIEndpoint, generation int) {
	p.mu.Lock()
	groups := p.groups()
	samples := p.tracker.Samples()
	p.mu.Unlock()
	ids := make([]string, 0, len(groups))
	for id := range groups {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if !p.alive(generation) {
			return
		}
		wanted := core.WantedFirstLiveMember(groups[id], samples)
		if wanted == "" {
			continue
		}
		tag := core.GroupOutboundTag(id)
		wantedTag := core.OutboundTag(wanted)
		body, err := clashRequest(ctx, p.client, http.MethodGet, endpoint.ProxyURL(tag), endpoint)
		if err != nil {
			p.hub.Log(core.LogLevelDebug, fmt.Sprintf("group: %s state unavailable (%s)", tag, err.Error()))
			continue
		}
		proxy, err := core.DecodeClashProxy(body)
		if err != nil || proxy.Now == wantedTag {
			continue
		}
		if err := p.put(ctx, endpoint, tag, wantedTag); err != nil {
			p.hub.Log(core.LogLevelWarning, fmt.Sprintf("group: %s could not switch to %s (%s)", tag, wantedTag, err.Error()))
			continue
		}
		p.hub.Log(core.LogLevelInfo, fmt.Sprintf("group: %s now via %s (was %s)", tag, wantedTag, proxy.Now))
	}
}

func (p *LatencyProber) put(ctx context.Context, endpoint core.ClashAPIEndpoint, tag, memberTag string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodPut, endpoint.ProxyURL(tag), bytes.NewReader(core.ClashSelectBody(memberTag)))
	if err != nil {
		return err
	}
	request.Header.Set("Authorization", "Bearer "+endpoint.Secret)
	request.Header.Set("Content-Type", "application/json")
	response, err := p.client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("http %d", response.StatusCode)
	}
	return nil
}
