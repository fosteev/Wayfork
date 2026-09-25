//go:build windows

package ipc

import "unsafe"

func sizeOf[T any](value T) uintptr { return unsafe.Sizeof(value) }
