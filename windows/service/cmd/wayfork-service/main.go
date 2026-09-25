// wayfork-service is the privileged half of the Windows client: a LocalSystem service that
// owns sing-box, the OpenVPN processes, adapters, routes and the resolver override, driven
// by the app over a named pipe (docs/design/08-windows.md). WM2 fills it in; for now it
// only reports how it was started.
package main

import (
	"fmt"
	"os"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "wayfork-service:", err)
		os.Exit(1)
	}
}
