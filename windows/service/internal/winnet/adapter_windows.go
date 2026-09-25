//go:build windows

package winnet

import (
	"fmt"
	"sort"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"

	"wayfork/service/internal/core"
)

// InterfaceLUID resolves an adapter by its friendly name. Adapters are keyed by name and
// never by ifIndex, which changes across reboots (docs/design/08-windows.md, Adapters).
func InterfaceLUID(alias string) (winipcfg.LUID, error) {
	adapters, err := winipcfg.GetAdaptersAddresses(windows.AF_UNSPEC, winipcfg.GAAFlagIncludeAllInterfaces)
	if err != nil {
		return 0, fmt.Errorf("enumerating adapters: %w", err)
	}
	for _, adapter := range adapters {
		if adapter.FriendlyName() == alias {
			return adapter.LUID, nil
		}
	}
	return 0, fmt.Errorf("no adapter named %q", alias)
}

// WayforkAdapterNames lists the `Wayfork-N` adapters currently on the machine, sorted.
// Uninstall deletes them before the driver package: `pnputil /delete-driver /uninstall`
// leaves the root devnodes behind, and the next install re-binds them as "Local Area
// Connection N" with new GUIDs (spike S2.2).
func WayforkAdapterNames() ([]string, error) {
	adapters, err := winipcfg.GetAdaptersAddresses(windows.AF_UNSPEC, winipcfg.GAAFlagIncludeAllInterfaces)
	if err != nil {
		return nil, fmt.Errorf("enumerating adapters: %w", err)
	}
	var names []string
	for _, adapter := range adapters {
		if name := adapter.FriendlyName(); core.IsAdapterName(name) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names, nil
}
