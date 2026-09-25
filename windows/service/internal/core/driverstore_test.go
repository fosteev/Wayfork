package core_test

import (
	"testing"

	"wayfork/service/internal/core"
)

const englishStore = `Microsoft PnP Utility

Published Name:     oem9.inf
Original Name:      oemvista.inf
Provider Name:      OpenVPN Technologies, Inc.
Class Name:         Network adapters
Class GUID:         {4d36e972-e325-11ce-bfc1-08002be10318}
Driver Version:     05/28/2024 9.27.0.0
Signer Name:        Microsoft Windows Hardware Compatibility Publisher

Published Name:     oem10.inf
Original Name:      ovpn-dco.inf
Provider Name:      OpenVPN Inc.
Class Name:         Network adapters
Class GUID:         {4d36e972-e325-11ce-bfc1-08002be10318}
Driver Version:     08/05/2026 2.8.4.0
Signer Name:        Microsoft Windows Hardware Compatibility Publisher
`

// The same store on a Russian Windows: only the labels change.
const russianStore = `Программа Microsoft PnP

Опубликованное имя:  oem10.inf
Исходное имя:        ovpn-dco.inf
Имя поставщика:      OpenVPN Inc.
Имя класса:          Сетевые адаптеры
Версия драйвера:     05.08.2026 2.8.4.0
`

func TestParseDriverStoreReadsRecordsByValue(t *testing.T) {
	packages := core.ParseDriverStore(englishStore)
	if len(packages) != 2 {
		t.Fatalf("packages = %+v, want 2", packages)
	}
	want := core.DriverPackage{PublishedName: "oem10.inf", OriginalName: "ovpn-dco.inf", Version: "2.8.4.0"}
	if packages[1] != want {
		t.Fatalf("packages[1] = %+v, want %+v", packages[1], want)
	}
	localised := core.ParseDriverStore(russianStore)
	if len(localised) != 1 || localised[0] != want {
		t.Fatalf("localised = %+v, want [%+v]", localised, want)
	}
}

func TestParseDriverStoreIgnoresIncompleteRecords(t *testing.T) {
	packages := core.ParseDriverStore("Microsoft PnP Utility\n\nPublished Name: oem4.inf\n\nOriginal Name: lonely.inf\n")
	if len(packages) != 0 {
		t.Fatalf("packages = %+v, want none", packages)
	}
}

func TestFindDriverPackagesMatchesCaseInsensitively(t *testing.T) {
	packages := core.ParseDriverStore(englishStore)
	found := core.FindDriverPackages(packages, "OVPN-DCO.INF")
	if len(found) != 1 || found[0].PublishedName != "oem10.inf" {
		t.Fatalf("found = %+v", found)
	}
	if other := core.FindDriverPackages(packages, "wintun.inf"); len(other) != 0 {
		t.Fatalf("found = %+v, want none", other)
	}
}

func TestNewlyPublishedClaimsOnlyWhatTheStoreGained(t *testing.T) {
	before := core.ParseDriverStore(englishStore)
	after := append(append([]core.DriverPackage{}, before...), core.DriverPackage{
		PublishedName: "oem12.inf", OriginalName: "ovpn-dco.inf", Version: "2.8.4.0",
	})
	published, ok := core.NewlyPublished(before, after, core.DriverOriginalName)
	if !ok || published.PublishedName != "oem12.inf" {
		t.Fatalf("published = %+v, ok = %v", published, ok)
	}
	if _, ok := core.NewlyPublished(before, before, core.DriverOriginalName); ok {
		t.Fatal("an unchanged store must not be claimed")
	}
	if _, ok := core.NewlyPublished(nil, before, "wintun.inf"); ok {
		t.Fatal("another package must not be claimed")
	}
}

func TestInfDriverVersionReadsTheVersionAfterTheDate(t *testing.T) {
	inf := "[Version]\r\nSignature = \"$Windows NT$\"\r\nClass = Net\r\n" +
		"Provider = %OpenVPN%\r\nCatalogFile = ovpn-dco.cat\r\nDriverVer = 08/05/2026,2.8.4.0\r\n"
	if got := core.InfDriverVersion(inf); got != "2.8.4.0" {
		t.Fatalf("InfDriverVersion = %q, want 2.8.4.0", got)
	}
	if got := core.InfDriverVersion("[Version]\nClass = Net\n"); got != "" {
		t.Fatalf("InfDriverVersion = %q, want empty", got)
	}
}
