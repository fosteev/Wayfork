package core

import "testing"

func TestAdapterName(t *testing.T) {
	for slot, want := range map[int]string{0: "Wayfork-1", 9: "Wayfork-10", 31: "Wayfork-32"} {
		got, err := AdapterName(slot)
		if err != nil || got != want {
			t.Errorf("AdapterName(%d) = %q, %v; want %q", slot, got, err, want)
		}
	}
	for _, slot := range []int{-1, 32, 100} {
		if _, err := AdapterName(slot); err == nil {
			t.Errorf("AdapterName(%d) accepted an out-of-range slot", slot)
		}
	}
}

func TestIsAdapterName(t *testing.T) {
	for _, name := range []string{"Wayfork-1", "Wayfork-32"} {
		if !IsAdapterName(name) {
			t.Errorf("%q rejected", name)
		}
	}
	for _, name := range []string{"Wayfork", "Wayfork-0", "Wayfork-33", "wayfork-1", "Wayfork-1 ", "Ethernet"} {
		if IsAdapterName(name) {
			t.Errorf("%q accepted", name)
		}
	}
}
