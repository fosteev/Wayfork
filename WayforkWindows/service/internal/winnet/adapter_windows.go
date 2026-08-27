//go:build windows

package winnet

import (
	"fmt"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
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
