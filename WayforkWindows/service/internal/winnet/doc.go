// Package winnet wraps the Win32 networking calls the service needs (adapters by name,
// interface-scoped routes, NRPT) on top of golang.zx2c4.com/wireguard/windows/tunnel/winipcfg.
// Every file except this one is Windows-only; internal/core never imports it.
package winnet
