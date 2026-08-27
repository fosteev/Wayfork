// wayforkctl is the developer tool for driving wayfork-service without the app:
// `wayforkctl plan|status|stop` (the macOS `WayforkDaemon --dev-apply` counterpart,
// docs/ROADMAP-windows.md WM2).
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: wayforkctl plan|status|stop")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "plan", "status", "stop":
		fmt.Fprintf(os.Stderr, "wayforkctl %s: not implemented yet (WM2)\n", os.Args[1])
		os.Exit(1)
	default:
		fmt.Fprintf(os.Stderr, "wayforkctl: unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}
