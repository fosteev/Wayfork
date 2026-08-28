//go:build windows

package winnet

import (
	"errors"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"

	"wayfork/service/internal/core"
	"wayfork/service/internal/service"
)

// Validator checks a bundled binary's Authenticode signature with WinVerifyTrust before
// every spawn and requires it to live under the install directory
// (docs/design/08-windows.md, "Components and trust boundary"). Pinning the publisher
// (rather than any valid chain) is owed with the signing setup in WM5.
type Validator struct {
	InstallDir string
}

var _ service.BinaryValidator = (*Validator)(nil)

// Validate implements service.BinaryValidator.
func (v *Validator) Validate(path string) *core.DaemonError {
	if !insideDirectory(path, v.InstallDir) {
		return core.ErrBinaryUntrusted(path)
	}
	if err := VerifyAuthenticode(path); err != nil {
		return core.ErrBinaryUntrusted(path)
	}
	return nil
}

// trustNoSignature is TRUST_E_NOSIGNATURE: the file carries no signature at all, as
// opposed to one that is broken, expired or from a publisher nobody trusts.
const trustNoSignature = 0x800B0100

// ValidateClient is the pipe's admission check. Until Wayfork has a code-signing
// certificate its own app is unsigned, so an image inside the install directory is let in
// without one — only an administrator can write there, which is the same boundary the
// service already trusts for its own binaries. A signature that *is* there must be valid:
// a tampered or expired one is a refusal, never a downgrade to the path check. The first
// return value is the warning to log when an unsigned client was accepted.
func (v *Validator) ValidateClient(path string) (string, *core.DaemonError) {
	if !insideDirectory(path, v.InstallDir) {
		return "", core.ErrBinaryUntrusted(path)
	}
	err := VerifyAuthenticode(path)
	switch {
	case err == nil:
		return "", nil
	case isUnsigned(err):
		return "unsigned client " + path + " accepted: it is inside " + v.InstallDir, nil
	default:
		return "", core.ErrBinaryUntrusted(path)
	}
}

func isUnsigned(err error) bool {
	var errno syscall.Errno
	return errors.As(err, &errno) && uint32(errno) == trustNoSignature
}

func insideDirectory(path, directory string) bool {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	root, err := filepath.Abs(directory)
	if err != nil {
		return false
	}
	return strings.HasPrefix(strings.ToLower(absolute), strings.ToLower(root)+`\`)
}

// VerifyAuthenticode runs WinVerifyTrust's generic file verification on path.
func VerifyAuthenticode(path string) error {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	fileInfo := windows.WinTrustFileInfo{
		Size:     uint32(unsafe.Sizeof(windows.WinTrustFileInfo{})),
		FilePath: name,
	}
	data := windows.WinTrustData{
		Size:                            uint32(unsafe.Sizeof(windows.WinTrustData{})),
		UIChoice:                        windows.WTD_UI_NONE,
		RevocationChecks:                windows.WTD_REVOKE_NONE,
		UnionChoice:                     windows.WTD_CHOICE_FILE,
		StateAction:                     windows.WTD_STATEACTION_VERIFY,
		FileOrCatalogOrBlobOrSgnrOrCert: unsafe.Pointer(&fileInfo),
		ProvFlags:                       windows.WTD_SAFER_FLAG | windows.WTD_CACHE_ONLY_URL_RETRIEVAL,
	}
	err = windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	data.StateAction = windows.WTD_STATEACTION_CLOSE
	_ = windows.WinVerifyTrustEx(windows.InvalidHWND, &windows.WINTRUST_ACTION_GENERIC_VERIFY_V2, &data)
	return err
}

// driverActionVerify is DRIVER_ACTION_VERIFY, {F750E6C3-38EE-11d1-85E5-00C04FC295EE}:
// the action that validates a driver catalog against the driver signing policy. The
// generic action cannot do it — a `.cat` carries no embedded signature, it *is* one.
var driverActionVerify = windows.GUID{
	Data1: 0xF750E6C3,
	Data2: 0x38EE,
	Data3: 0x11D1,
	Data4: [8]byte{0x85, 0xE5, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE},
}

// VerifyDriverCatalog checks a driver package's `.cat` before pnputil publishes it
// (docs/design/08-windows.md, "Installer").
func VerifyDriverCatalog(path string) error {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return err
	}
	fileInfo := windows.WinTrustFileInfo{
		Size:     uint32(unsafe.Sizeof(windows.WinTrustFileInfo{})),
		FilePath: name,
	}
	data := windows.WinTrustData{
		Size:                            uint32(unsafe.Sizeof(windows.WinTrustData{})),
		UIChoice:                        windows.WTD_UI_NONE,
		RevocationChecks:                windows.WTD_REVOKE_NONE,
		UnionChoice:                     windows.WTD_CHOICE_FILE,
		StateAction:                     windows.WTD_STATEACTION_VERIFY,
		FileOrCatalogOrBlobOrSgnrOrCert: unsafe.Pointer(&fileInfo),
		ProvFlags:                       windows.WTD_CACHE_ONLY_URL_RETRIEVAL,
	}
	err = windows.WinVerifyTrustEx(windows.InvalidHWND, &driverActionVerify, &data)
	data.StateAction = windows.WTD_STATEACTION_CLOSE
	_ = windows.WinVerifyTrustEx(windows.InvalidHWND, &driverActionVerify, &data)
	return err
}

// ClientImagePath resolves the executable of a process (the pipe's client).
func ClientImagePath(pid uint32) (string, error) {
	handle, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return "", err
	}
	defer windows.CloseHandle(handle)
	buffer := make([]uint16, windows.MAX_LONG_PATH)
	size := uint32(len(buffer))
	if err := windows.QueryFullProcessImageName(handle, 0, &buffer[0], &size); err != nil {
		return "", err
	}
	return windows.UTF16ToString(buffer[:size]), nil
}

// SecureDirectory gives a directory a DACL of SYSTEM + Administrators only (run\ and
// logs\ under %ProgramData%, which is world-readable by default).
func SecureDirectory(path string) error {
	descriptor, err := windows.SecurityDescriptorFromString("D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return err
	}
	dacl, _, err := descriptor.DACL()
	if err != nil {
		return err
	}
	return windows.SetNamedSecurityInfo(path, windows.SE_FILE_OBJECT,
		windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
}
