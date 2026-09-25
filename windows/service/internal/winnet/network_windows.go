//go:build windows

package winnet

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"time"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"

	"wayfork/service/internal/core"
	"wayfork/service/internal/service"
)

// ScopedDefaultMetric is the route metric of a tunnel's default: 9999 + the adapter's
// interface metric (25 for dco) is far above the TUN (0) and the NIC, so only a socket
// bound to the adapter ever picks it (docs/design/08-windows.md, "Routes"; spike S4b).
const ScopedDefaultMetric = 9999

// DefaultHardwareID is the driver new adapters get; existing adapters keep whatever
// driver they have (tap-windows6 after a compression fallback works as well).
const DefaultHardwareID = "ovpn-dco"

var defaultPrefix = netip.MustParsePrefix("0.0.0.0/0")

// Network implements service.Network on top of winipcfg and tapctl.
type Network struct {
	tapctl string
	runner service.ProcessRunner
}

// NewNetwork uses the bundled tapctl through runner for adapter creation.
func NewNetwork(tapctlPath string, runner service.ProcessRunner) *Network {
	return &Network{tapctl: tapctlPath, runner: runner}
}

var _ service.Network = (*Network)(nil)

type adapter struct {
	name string
	luid winipcfg.LUID
	up   bool
}

func listAdapters() ([]adapter, error) {
	rows, err := winipcfg.GetAdaptersAddresses(windows.AF_UNSPEC, winipcfg.GAAFlagIncludeAllInterfaces)
	if err != nil {
		return nil, fmt.Errorf("enumerating adapters: %w", err)
	}
	adapters := make([]adapter, 0, len(rows))
	for _, row := range rows {
		adapters = append(adapters, adapter{
			name: row.FriendlyName(), luid: row.LUID, up: row.OperStatus == winipcfg.IfOperStatusUp,
		})
	}
	return adapters, nil
}

func findAdapter(name string) (adapter, bool, error) {
	adapters, err := listAdapters()
	if err != nil {
		return adapter{}, false, err
	}
	for _, candidate := range adapters {
		if candidate.name == name {
			return candidate, true, nil
		}
	}
	return adapter{}, false, nil
}

// AdapterPresent implements service.Network.
func (n *Network) AdapterPresent(name string) bool {
	found, ok, err := findAdapter(name)
	return err == nil && ok && found.up
}

// EnsureAdapters implements service.Network: `tapctl create --name Wayfork-N --hwid
// ovpn-dco` for every planned adapter that does not exist yet. tapctl refuses a duplicate
// name, which counts as "already there"; adapters of tunnels absent from the plan stay.
func (n *Network) EnsureAdapters(ctx context.Context, names []string) error {
	adapters, err := listAdapters()
	if err != nil {
		return err
	}
	present := map[string]bool{}
	for _, adapter := range adapters {
		present[adapter.name] = true
	}
	for _, name := range names {
		if !core.IsAdapterName(name) {
			return fmt.Errorf("refusing to create adapter %q", name)
		}
		if present[name] {
			continue
		}
		runCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
		result, err := n.runner.Run(runCtx, service.ProcessSpec{
			Executable: n.tapctl, Args: []string{"create", "--name", name, "--hwid", DefaultHardwareID},
		})
		cancel()
		if err != nil {
			return fmt.Errorf("tapctl create %s: %w", name, err)
		}
		if !result.Succeeded() && !strings.Contains(strings.ToLower(result.Output()), "already") {
			return fmt.Errorf("tapctl create %s failed (exit %d): %s", name, result.ExitCode, result.Output())
		}
	}
	return nil
}

// CleanupAdapters implements service.Network: leftover scoped defaults and stale
// addresses on every Wayfork-N adapter (they survive a killed OpenVPN, spike S7).
func (n *Network) CleanupAdapters(context.Context) error {
	adapters, err := listAdapters()
	if err != nil {
		return err
	}
	var problems []string
	for _, adapter := range adapters {
		if !core.IsAdapterName(adapter.name) {
			continue
		}
		if err := deleteDefaults(adapter.luid); err != nil {
			problems = append(problems, adapter.name+": "+err.Error())
		}
		if err := adapter.luid.FlushIPAddresses(windows.AF_INET); err != nil {
			problems = append(problems, adapter.name+": addresses: "+err.Error())
		}
	}
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

func deleteDefaults(luid winipcfg.LUID) error {
	rows, err := winipcfg.GetIPForwardTable2(windows.AF_INET)
	if err != nil {
		return err
	}
	for i := range rows {
		row := &rows[i]
		if row.InterfaceLUID != luid || row.DestinationPrefix.Prefix() != defaultPrefix {
			continue
		}
		if err := row.Delete(); err != nil {
			return err
		}
	}
	return nil
}

// AddScopedDefault implements service.Network.
func (n *Network) AddScopedDefault(name, gateway string) error {
	if !core.IsAdapterName(name) {
		return fmt.Errorf("refusing to route via %q", name)
	}
	found, ok, err := findAdapter(name)
	if err != nil {
		return err
	}
	if !ok {
		return fmt.Errorf("no adapter named %q", name)
	}
	nextHop := netip.IPv4Unspecified()
	if gateway != "" {
		nextHop, err = netip.ParseAddr(gateway)
		if err != nil || !nextHop.Is4() {
			return fmt.Errorf("invalid gateway %q", gateway)
		}
	}
	// A leftover from a previous attempt would make CreateIpForwardEntry2 fail.
	_ = deleteDefaults(found.luid)
	if err := found.luid.AddRoute(defaultPrefix, nextHop, ScopedDefaultMetric); err != nil {
		return fmt.Errorf("adding the default via %s on %s: %w", nextHop, name, err)
	}
	return nil
}

// DeleteScopedDefault implements service.Network.
func (n *Network) DeleteScopedDefault(name string) error {
	if !core.IsAdapterName(name) {
		return fmt.Errorf("refusing to touch %q", name)
	}
	found, ok, err := findAdapter(name)
	if err != nil {
		return err
	}
	if !ok {
		return nil
	}
	return deleteDefaults(found.luid)
}

// RouteInterface implements service.Network: the adapter of the best matching route —
// longest prefix, then lowest route + interface metric (how Windows ranks routes).
func (n *Network) RouteInterface(address string) (string, error) {
	target, err := netip.ParseAddr(address)
	if err != nil || !target.Is4() {
		return "", fmt.Errorf("invalid address %q", address)
	}
	rows, err := winipcfg.GetIPForwardTable2(windows.AF_INET)
	if err != nil {
		return "", err
	}
	interfaces, err := winipcfg.GetIPInterfaceTable(windows.AF_INET)
	if err != nil {
		return "", err
	}
	interfaceMetric := map[winipcfg.LUID]uint32{}
	connected := map[winipcfg.LUID]bool{}
	for _, row := range interfaces {
		interfaceMetric[row.InterfaceLUID] = row.Metric
		connected[row.InterfaceLUID] = row.Connected
	}
	var best *winipcfg.MibIPforwardRow2
	bestBits, bestMetric := -1, uint32(0)
	for i := range rows {
		row := &rows[i]
		prefix := row.DestinationPrefix.Prefix()
		if !prefix.Contains(target) || !connected[row.InterfaceLUID] {
			continue
		}
		metric := row.Metric + interfaceMetric[row.InterfaceLUID]
		if prefix.Bits() > bestBits || (prefix.Bits() == bestBits && metric < bestMetric) {
			best, bestBits, bestMetric = row, prefix.Bits(), metric
		}
	}
	if best == nil {
		return "", errors.New("no route")
	}
	iface, err := best.InterfaceLUID.Interface()
	if err != nil {
		return "", err
	}
	return iface.Alias(), nil
}

// Diagnostics implements service.Network with the PowerShell dumps the design lists.
func (n *Network) Diagnostics(ctx context.Context) string {
	script := "Get-NetRoute -AddressFamily IPv4 | Sort-Object DestinationPrefix | Format-Table -AutoSize DestinationPrefix, NextHop, RouteMetric, InterfaceMetric, InterfaceAlias, PolicyStore | Out-String -Width 200; " +
		"Get-NetAdapter | Format-Table -AutoSize Name, InterfaceDescription, Status, ifIndex | Out-String -Width 200; " +
		"Get-DnsClientNrptPolicy -Effective | Format-List | Out-String -Width 200"
	output, err := RunPowerShell(ctx, n.runner, script)
	if err != nil {
		output += "\n(powershell failed: " + err.Error() + ")"
	}
	runCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if result, err := n.runner.Run(runCtx, service.ProcessSpec{Executable: n.tapctl, Args: []string{"list"}}); err == nil {
		output += "\n$ tapctl list\n" + result.Output()
	}
	return output
}
