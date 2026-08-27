//go:build windows

package winnet

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"regexp"
	"strings"
	"time"

	"wayfork/service/internal/core"
	"wayfork/service/internal/service"
)

// Resolver implements service.Resolver with the DnsClient NRPT cmdlets — the mechanism
// the spike proved airtight (docs/design/08-windows.md, "Resolver override").
type Resolver struct {
	runner service.ProcessRunner
}

// NewResolver runs PowerShell through runner.
func NewResolver(runner service.ProcessRunner) *Resolver { return &Resolver{runner: runner} }

var _ service.Resolver = (*Resolver)(nil)

var (
	nrptNamePattern    = regexp.MustCompile(`^\{[0-9A-Fa-f-]{36}\}$`)
	nrptAddressPattern = regexp.MustCompile(`^[0-9.]{7,15}$`)
	nrptCommentPattern = regexp.MustCompile(`^[A-Za-z0-9 _-]{1,64}$`)
)

// nrptRuleWire is Get-DnsClientNrptRule | ConvertTo-Json: single values come as
// scalars, several as arrays.
type nrptRuleWire struct {
	Name        string          `json:"Name"`
	Namespace   json.RawMessage `json:"Namespace"`
	NameServers json.RawMessage `json:"NameServers"`
	Comment     string          `json:"Comment"`
}

func scalarOrList(raw json.RawMessage) []string {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var single string
	if json.Unmarshal(raw, &single) == nil {
		return []string{single}
	}
	var list []string
	if json.Unmarshal(raw, &list) == nil {
		return list
	}
	return nil
}

// Snapshot implements service.Resolver.
func (r *Resolver) Snapshot(ctx context.Context) (core.ResolverSnapshot, error) {
	output, err := RunPowerShell(ctx, r.runner,
		"$rules = @(Get-DnsClientNrptRule | Select-Object Name, Namespace, NameServers, Comment); ConvertTo-Json -Compress -InputObject $rules")
	if err != nil {
		return core.ResolverSnapshot{}, err
	}
	output = strings.TrimSpace(output)
	if output == "" || output == "null" {
		return core.ResolverSnapshot{Rules: []core.NRPTRule{}}, nil
	}
	var wire []nrptRuleWire
	if err := json.Unmarshal([]byte(output), &wire); err != nil {
		var single nrptRuleWire
		if err := json.Unmarshal([]byte(output), &single); err != nil {
			return core.ResolverSnapshot{}, fmt.Errorf("decoding the NRPT: %w", err)
		}
		wire = []nrptRuleWire{single}
	}
	rules := make([]core.NRPTRule, 0, len(wire))
	for _, entry := range wire {
		namespaces := scalarOrList(entry.Namespace)
		namespace := ""
		if len(namespaces) > 0 {
			namespace = namespaces[0]
		}
		rules = append(rules, core.NRPTRule{
			Name: entry.Name, Namespace: namespace, NameServers: scalarOrList(entry.NameServers), Comment: entry.Comment,
		})
	}
	return core.ResolverSnapshot{Rules: rules}, nil
}

// AddRule implements service.Resolver.
func (r *Resolver) AddRule(ctx context.Context, rule core.NRPTRule) (core.NRPTRule, error) {
	if rule.Namespace != core.NRPTNamespace || !nrptCommentPattern.MatchString(rule.Comment) || len(rule.NameServers) == 0 {
		return rule, errors.New("refusing to add an NRPT rule outside the service's shape")
	}
	for _, server := range rule.NameServers {
		if !nrptAddressPattern.MatchString(server) {
			return rule, fmt.Errorf("refusing NRPT name server %q", server)
		}
	}
	script := fmt.Sprintf("Add-DnsClientNrptRule -Namespace '.' -NameServers %s -Comment '%s'",
		"'"+strings.Join(rule.NameServers, "','")+"'", rule.Comment)
	if _, err := RunPowerShell(ctx, r.runner, script); err != nil {
		return rule, err
	}
	snapshot, err := r.Snapshot(ctx)
	if err != nil {
		return rule, err
	}
	for _, candidate := range snapshot.Rules {
		if candidate.IsWayfork() && len(candidate.NameServers) == len(rule.NameServers) {
			return candidate, nil
		}
	}
	return rule, nil
}

// RemoveRules implements service.Resolver.
func (r *Resolver) RemoveRules(ctx context.Context, names []string) error {
	for _, name := range names {
		if !nrptNamePattern.MatchString(name) {
			return fmt.Errorf("refusing to remove NRPT rule %q", name)
		}
		if _, err := RunPowerShell(ctx, r.runner, "Remove-DnsClientNrptRule -Name '"+name+"' -Force"); err != nil {
			return err
		}
	}
	return nil
}

// Probe implements service.Resolver: one lookup through the system resolver (Go uses
// GetAddrInfoW on Windows, which honours the NRPT).
func (r *Resolver) Probe(ctx context.Context, host string) bool {
	lookupCtx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	addresses, err := net.DefaultResolver.LookupIPAddr(lookupCtx, host)
	return err == nil && len(addresses) > 0
}
