package core

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strconv"
	"time"
)

// LatencyTracker is the per-tunnel probe history behind the service's prober (F14,
// docs/design/05-daemon.md, "Tunnel latency"): pure bookkeeping, so the rounds stay a
// thin loop.
type LatencyTracker struct {
	samples map[string]LatencySample
}

// LatencyTransition is a state change one probe caused.
type LatencyTransition struct {
	Tunnel string
	// BecameUnreachable when true; recovered otherwise.
	BecameUnreachable bool
	Failures          int
	Milliseconds      int
}

// NewLatencyTracker returns an empty tracker.
func NewLatencyTracker() *LatencyTracker {
	return &LatencyTracker{samples: map[string]LatencySample{}}
}

// Record stores one probe (nil = failed) and reports the transition it caused, if any.
func (t *LatencyTracker) Record(tunnel string, milliseconds *int, now time.Time) *LatencyTransition {
	sample := t.samples[tunnel]
	wasUnreachable := sample.Unreachable
	sample.History = append(sample.History, milliseconds)
	if len(sample.History) > ProbeHistoryLength {
		sample.History = sample.History[len(sample.History)-ProbeHistoryLength:]
	}
	sample.Milliseconds = milliseconds
	if milliseconds != nil {
		sample.FailedInARow = 0
		stamp := NewTimestamp(now)
		sample.LastSuccess = &stamp
	} else {
		sample.FailedInARow++
	}
	sample.Unreachable = sample.FailedInARow >= ProbeFailureThreshold
	t.samples[tunnel] = sample
	if sample.Unreachable && !wasUnreachable {
		return &LatencyTransition{Tunnel: tunnel, BecameUnreachable: true, Failures: sample.FailedInARow}
	}
	if wasUnreachable && milliseconds != nil {
		return &LatencyTransition{Tunnel: tunnel, Milliseconds: *milliseconds}
	}
	return nil
}

// ResetStreak lets the next round decide afresh (Retry / reconnect from the card).
func (t *LatencyTracker) ResetStreak(tunnel string) {
	sample, ok := t.samples[tunnel]
	if !ok {
		return
	}
	sample.FailedInARow = 0
	sample.Unreachable = false
	t.samples[tunnel] = sample
}

// Retain drops tunnels that left the plan.
func (t *LatencyTracker) Retain(tunnels map[string]bool) {
	for id := range t.samples {
		if !tunnels[id] {
			delete(t.samples, id)
		}
	}
}

// Clear forgets every history (sing-box restarted or Turn Off).
func (t *LatencyTracker) Clear() { t.samples = map[string]LatencySample{} }

// Samples returns a copy of the latest samples for the snapshot.
func (t *LatencyTracker) Samples() map[string]LatencySample {
	out := make(map[string]LatencySample, len(t.samples))
	for id, sample := range t.samples {
		out[id] = sample
	}
	return out
}

// DelayURL is `GET /proxies/<tag>/delay?url=…&timeout=<ms>`: sing-box sends one request to
// url through the outbound and answers `{"delay": <ms>}` (F14).
func (e ClashAPIEndpoint) DelayURL(outboundTag, probeURL string, timeout time.Duration) string {
	query := url.Values{}
	query.Set("url", probeURL)
	query.Set("timeout", strconv.Itoa(int(timeout.Milliseconds())))
	return "http://" + e.ExternalController() + "/proxies/" + url.PathEscape(outboundTag) + "/delay?" + query.Encode()
}

// ProxyURL is `GET /proxies/<tag>` (what a group points at) and `PUT /proxies/<tag>` (F16).
func (e ClashAPIEndpoint) ProxyURL(outboundTag string) string {
	return "http://" + e.ExternalController() + "/proxies/" + url.PathEscape(outboundTag)
}

// DecodeClashDelay reads `{"delay": 62}`; a non-200 answer means the probe failed.
func DecodeClashDelay(data []byte) (int, error) {
	var body struct {
		Delay *int `json:"delay"`
	}
	if err := json.Unmarshal(data, &body); err != nil || body.Delay == nil {
		return 0, fmt.Errorf("decoding /delay: no delay field")
	}
	return *body.Delay, nil
}

// ClashProxy is `GET /proxies/<tag>` for a selector / urltest outbound (F16).
type ClashProxy struct {
	// The member tag it currently points at; empty when none.
	Now string
	All []string
}

// DecodeClashProxy reads the `now` and `all` fields.
func DecodeClashProxy(data []byte) (ClashProxy, error) {
	var body struct {
		Now string   `json:"now"`
		All []string `json:"all"`
	}
	if err := json.Unmarshal(data, &body); err != nil {
		return ClashProxy{}, fmt.Errorf("decoding /proxies: %w", err)
	}
	return ClashProxy{Now: body.Now, All: nonNilSlice(body.All)}, nil
}

// ClashSelectBody is the body of the PUT that points a selector at memberTag.
func ClashSelectBody(memberTag string) []byte {
	data, _ := json.Marshal(map[string]string{"name": memberTag})
	return data
}

// WantedFirstLiveMember is the member a *first live* group should point at: the first in
// the group's order whose latest probe passed; "" when none did (leave the selector alone).
func WantedFirstLiveMember(order []string, samples map[string]LatencySample) string {
	for _, id := range order {
		if sample, ok := samples[id]; ok && sample.Milliseconds != nil {
			return id
		}
	}
	return ""
}
