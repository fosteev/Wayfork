//go:build windows

package main

import (
	"errors"

	"golang.org/x/sys/windows/svc"
)

func run(args []string) error {
	inService, err := svc.IsWindowsService()
	if err != nil {
		return err
	}
	if inService {
		return errors.New("service host not implemented yet (WM2)")
	}
	return errors.New("not implemented yet (WM2); install and start the Wayfork service")
}
