//go:build !windows

package main

import "errors"

func run(args []string) error {
	return errors.New("runs on Windows only")
}
