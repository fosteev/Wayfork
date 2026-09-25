package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"wayfork/service/internal/core"
)

const (
	// ResolverAddress is the TUN resolver every NRPT-routed query goes to
	// (docs/design/08-windows.md, "Resolver override"; the sing-box generator's
	// `resolverAddress`).
	ResolverAddress = "172.19.0.2"
	// ResolverProbeName is answered by sing-box itself with a `predefined` rule, TTL 0.
	ResolverProbeName     = "probe.wayfork.internal"
	resolverProbeTimeout  = 5 * time.Second
	resolverProbeInterval = 300 * time.Millisecond
)

// ResolverOverride makes Wayfork the system resolver while sing-box runs (F12).
// core.PlanResolverOverride decides; this type reads and writes the NRPT through
// Resolver and keeps run\dns-override.json.
type ResolverOverride struct {
	env      Environment
	hub      *Hub
	resolver Resolver
	clock    Clock
	onState  func(core.ResolverOverrideState)

	mu            sync.Mutex
	desired       bool
	engineRunning bool
	// Why the override is held off until sing-box restarts: the probe found that the
	// system resolver does not reach the TUN.
	blocked     string
	probeCancel context.CancelFunc
	state       core.ResolverOverrideState
}

// NewResolverOverride makes an inactive override; onState receives every state change.
func NewResolverOverride(env Environment, hub *Hub, resolver Resolver, clock Clock, onState func(core.ResolverOverrideState)) *ResolverOverride {
	if clock == nil {
		clock = SystemClock
	}
	return &ResolverOverride{
		env: env, hub: hub, resolver: resolver, clock: clock, onState: onState,
		state: core.NewResolverOverrideOff(),
	}
}

// SetDesired is the plan's wish (RuntimePlan.OverrideSystemDNS).
func (r *ResolverOverride) SetDesired(on bool) {
	r.mu.Lock()
	r.desired = on
	r.mu.Unlock()
	r.reconcile()
}

// SetEngineRunning follows the engine: the override is in place only while sing-box runs.
func (r *ResolverOverride) SetEngineRunning(running bool) {
	r.mu.Lock()
	if running != r.engineRunning {
		r.blocked = "" // a new sing-box deserves a new try
	}
	r.engineRunning = running
	r.mu.Unlock()
	r.reconcile()
}

// State is the current override state.
func (r *ResolverOverride) State() core.ResolverOverrideState {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.state
}

// RestoreLeftover (bootstrap): remove whatever a previous service left in the NRPT —
// the rule by its comment, the record if any — before anything else
// (docs/design/08-windows.md, "Lifecycle").
func (r *ResolverOverride) RestoreLeftover(ctx context.Context) {
	snapshot, err := r.resolver.Snapshot(ctx)
	if err != nil {
		r.hub.Log(core.LogLevelError, "system resolver: cannot read the NRPT: "+err.Error())
		return
	}
	saved := r.readRecord()
	actions, _ := core.PlanResolverOverride(false, snapshot, saved, ResolverAddress)
	if len(actions) == 0 {
		return
	}
	r.hub.Log(core.LogLevelWarning, "system resolver left overridden by a previous service; restoring")
	for _, action := range actions {
		if err := r.perform(ctx, action); err != nil {
			r.hub.Log(core.LogLevelError, "system resolver: "+err.Error())
		}
	}
}

func (r *ResolverOverride) reconcile() {
	ctx := context.Background()
	r.mu.Lock()
	active := r.desired && r.engineRunning && r.blocked == ""
	blocked, desired, engineRunning := r.blocked, r.desired, r.engineRunning
	r.mu.Unlock()

	var result core.ResolverOverrideState
	snapshot, err := r.resolver.Snapshot(ctx)
	if err != nil {
		result = core.NewResolverOverrideFailed("cannot read the NRPT: " + err.Error())
	} else {
		var actions []core.ResolverOverrideAction
		actions, result = core.PlanResolverOverride(active, snapshot, r.readRecord(), ResolverAddress)
		for _, action := range actions {
			if err := r.perform(ctx, action); err != nil {
				r.hub.Log(core.LogLevelError, "system resolver: "+err.Error())
				result = core.NewResolverOverrideFailed(err.Error())
				break
			}
		}
	}
	if blocked != "" && !active && desired && engineRunning {
		result = core.NewResolverOverrideFailed(blocked)
	}

	r.mu.Lock()
	changed := result.Kind != r.state.Kind || result.Reason != r.state.Reason || result.Service != r.state.Service
	previous := r.state
	r.state = result
	if !active && r.probeCancel != nil {
		r.probeCancel()
		r.probeCancel = nil
	}
	startProbe := result.Kind == core.ResolverOverrideActive && changed && r.probeCancel == nil
	if startProbe {
		var probeCtx context.Context
		probeCtx, r.probeCancel = context.WithCancel(context.Background())
		go r.probe(probeCtx)
	}
	r.mu.Unlock()

	if changed {
		switch result.Kind {
		case core.ResolverOverrideOff:
			if previous.Kind != core.ResolverOverrideOff {
				r.hub.Log(core.LogLevelInfo, "system resolver restored")
			}
		case core.ResolverOverrideActive:
			r.hub.Log(core.LogLevelInfo, "system resolver → "+ResolverAddress+" via "+result.Service)
		case core.ResolverOverrideFailed:
			r.hub.Log(core.LogLevelError, "system resolver override failed: "+result.Reason)
		}
		if r.onState != nil {
			r.onState(result)
		}
	}
}

// probe resolves the probe name through the system resolver every 300 ms until it
// answers; no answer within 5 s backs the override out until sing-box restarts.
func (r *ResolverOverride) probe(ctx context.Context) {
	deadline := time.NewTimer(resolverProbeTimeout)
	defer deadline.Stop()
	for {
		if r.resolver.Probe(ctx, ResolverProbeName) {
			r.mu.Lock()
			r.probeCancel = nil
			r.mu.Unlock()
			r.hub.Log(core.LogLevelInfo, "system resolver verified: "+ResolverProbeName+" answered through the TUN")
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-deadline.C:
			reason := fmt.Sprintf("%s got no answer through %s within %s", ResolverProbeName, ResolverAddress, resolverProbeTimeout)
			r.mu.Lock()
			r.probeCancel = nil
			r.blocked = reason
			r.mu.Unlock()
			r.hub.Log(core.LogLevelError, "system resolver override backed out: "+reason)
			r.reconcile()
			return
		case <-time.After(resolverProbeInterval):
		}
	}
}

func (r *ResolverOverride) perform(ctx context.Context, action core.ResolverOverrideAction) error {
	switch action.Kind {
	case core.ResolverWrite:
		// The record goes first: a crash right after the write must still be undoable.
		if err := r.writeRecord(action.Record); err != nil {
			return err
		}
		if _, err := r.resolver.AddRule(ctx, action.Rule); err != nil {
			return fmt.Errorf("cannot add the NRPT rule: %w", err)
		}
		return nil
	case core.ResolverRestore:
		if len(action.RuleNames) > 0 {
			if err := r.resolver.RemoveRules(ctx, action.RuleNames); err != nil {
				return fmt.Errorf("cannot remove the NRPT rule: %w", err)
			}
		}
		if err := os.Remove(r.recordPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("cannot delete the resolver record: %w", err)
		}
		return nil
	}
	return nil
}

func (r *ResolverOverride) recordPath() string {
	return r.env.RunPath(core.ResolverOverrideRecordFile)
}

func (r *ResolverOverride) readRecord() *core.ResolverOverrideRecord {
	data, err := os.ReadFile(r.recordPath())
	if err != nil {
		return nil
	}
	var record core.ResolverOverrideRecord
	if err := json.Unmarshal(data, &record); err != nil {
		return nil
	}
	return &record
}

func (r *ResolverOverride) writeRecord(record core.ResolverOverrideRecord) error {
	data, err := json.Marshal(record)
	if err != nil {
		return fmt.Errorf("cannot encode the resolver record: %w", err)
	}
	if err := core.WriteFileAtomic(r.recordPath(), data, 0o600); err != nil {
		return fmt.Errorf("cannot save the resolver record: %w", err)
	}
	return nil
}
