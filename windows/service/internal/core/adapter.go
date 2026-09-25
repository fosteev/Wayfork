package core

import (
	"fmt"
	"regexp"
)

// MaxSlots is the number of OpenVPN adapters the service pre-creates at most: Wayfork-1 …
// Wayfork-32 (docs/design/08-windows.md, Adapters). Slots are 0-based like the macOS utun
// slots; the adapter number is slot+1.
const MaxSlots = 32

// TUNAdapterName is sing-box's own TUN adapter (interface_name).
const TUNAdapterName = "Wayfork"

var adapterNamePattern = regexp.MustCompile(`^Wayfork-([1-9]|[12][0-9]|3[0-2])$`)

// AdapterName returns the name of the OpenVPN adapter for a tunnel slot.
func AdapterName(slot int) (string, error) {
	if slot < 0 || slot >= MaxSlots {
		return "", fmt.Errorf("adapter slot %d out of range 0…%d", slot, MaxSlots-1)
	}
	return fmt.Sprintf("Wayfork-%d", slot+1), nil
}

// IsAdapterName reports whether name is one of the service's own OpenVPN adapters. Route
// and adapter operations refuse any other name so that a corrupt plan can never touch a
// foreign interface.
func IsAdapterName(name string) bool {
	return adapterNamePattern.MatchString(name)
}
