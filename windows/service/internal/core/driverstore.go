package core

import (
	"regexp"
	"strings"
)

const (
	// DriverOriginalName is the INF of the bundled ovpn-dco package
	// (docs/design/08-windows.md, "Installer").
	DriverOriginalName = "ovpn-dco.inf"
	// DriverRecordFile is `run\driver.json`: what --install-driver published, so
	// --uninstall-cleanup removes that package and never a copy someone else owns.
	DriverRecordFile = "driver.json"
	// DriverRecordVersion is the current record format.
	DriverRecordVersion = 1
)

// DriverPackage is one record of `pnputil /enum-drivers`.
type DriverPackage struct {
	// PublishedName is the driver store name, `oemNN.inf`.
	PublishedName string
	// OriginalName is the name the package was authored with, `ovpn-dco.inf`.
	OriginalName string
	// Version is the dotted quad of the "Driver Version" line, if it had one.
	Version string
}

// DriverRecord is `run\driver.json`.
type DriverRecord struct {
	Version       int    `json:"version"`
	PublishedName string `json:"publishedName"`
	OriginalName  string `json:"originalName"`
	DriverVersion string `json:"driverVersion"`
}

var (
	// DriverVer=08/05/2026,2.8.4.0 — the version is the part after the comma.
	infDriverVerPattern  = regexp.MustCompile(`(?im)^\s*DriverVer\s*=\s*[^,\r\n]*,\s*([0-9]+(?:\.[0-9]+)+)`)
	publishedNamePattern = regexp.MustCompile(`(?i)^oem[0-9]+\.inf$`)
	infNamePattern       = regexp.MustCompile(`(?i)^[^\\/:*?"<>|]+\.inf$`)
	driverVersionPattern = regexp.MustCompile(`[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+`)
)

// ParseDriverStore reads the output of `pnputil /enum-drivers`. pnputil localises its
// labels — "Published Name" is "Опубликованное имя" on a Russian Windows — so records are
// split on blank lines and identified by their *values*: `oemNN.inf` is the published
// name, another `.inf` is the original one and the first dotted quad is the version.
// Records without both names are dropped.
func ParseDriverStore(output string) []DriverPackage {
	var packages []DriverPackage
	var current DriverPackage
	flush := func() {
		if current.PublishedName != "" && current.OriginalName != "" {
			packages = append(packages, current)
		}
		current = DriverPackage{}
	}
	for _, line := range strings.Split(strings.ReplaceAll(output, "\r\n", "\n"), "\n") {
		if strings.TrimSpace(line) == "" {
			flush()
			continue
		}
		label, value, found := strings.Cut(line, ":")
		if !found || strings.TrimSpace(label) == "" {
			continue
		}
		value = strings.TrimSpace(value)
		switch {
		case publishedNamePattern.MatchString(value):
			current.PublishedName = strings.ToLower(value)
		case infNamePattern.MatchString(value):
			current.OriginalName = strings.ToLower(value)
		case current.Version == "" && driverVersionPattern.MatchString(value):
			current.Version = driverVersionPattern.FindString(value)
		}
	}
	flush()
	return packages
}

// FindDriverPackages returns the records whose original name is originalName.
func FindDriverPackages(packages []DriverPackage, originalName string) []DriverPackage {
	wanted := strings.ToLower(originalName)
	var found []DriverPackage
	for _, candidate := range packages {
		if candidate.OriginalName == wanted {
			found = append(found, candidate)
		}
	}
	return found
}

// NewlyPublished is the package `pnputil /add-driver` added: the one record of
// originalName that the store gained. Nothing new means the package was already
// published — by an OpenVPN install, or by an earlier run of this installer — and
// Wayfork must not claim it, or uninstalling would take somebody else's driver with it.
func NewlyPublished(before, after []DriverPackage, originalName string) (DriverPackage, bool) {
	known := map[string]bool{}
	for _, candidate := range FindDriverPackages(before, originalName) {
		known[candidate.PublishedName] = true
	}
	for _, candidate := range FindDriverPackages(after, originalName) {
		if !known[candidate.PublishedName] {
			return candidate, true
		}
	}
	return DriverPackage{}, false
}

// InfDriverVersion reads the DriverVer of an INF, so an upgrade can tell whether the
// bundled package is the one already in the store. Empty when the INF has no DriverVer.
func InfDriverVersion(inf string) string {
	match := infDriverVerPattern.FindStringSubmatch(inf)
	if len(match) != 2 {
		return ""
	}
	return match[1]
}
