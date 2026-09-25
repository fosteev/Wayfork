package core

import (
	"slices"
	"testing"
)

const selectorsFile = "rules-t-x.json"

// The shapes the generator emits (fixtures/singbox/*/rules-*.json).
func domainRules(domains, suffixes []string) string {
	return `{"rules":[{"domain":` + jsonStrings(domains) + `,"domain_suffix":` + jsonStrings(suffixes) + `}],"version":3}`
}

func jsonStrings(items []string) string {
	out := "["
	for index, item := range items {
		if index > 0 {
			out += ","
		}
		out += `"` + item + `"`
	}
	return out + "]"
}

func selectorsChange(t *testing.T, before, after string) RuleSetSelectors {
	t.Helper()
	change, ok := RuleSetChange(map[string]string{selectorsFile: before}, map[string]string{selectorsFile: after}, []string{selectorsFile})
	if !ok {
		t.Fatalf("change from %s to %s is unknown", before, after)
	}
	return change
}

func TestChangeCoversOnlyTheMatchersThatDiffer(t *testing.T) {
	before := domainRules([]string{"example.com"}, []string{".example.com"})
	after := domainRules([]string{"example.com", "2ip.io"}, []string{".example.com", ".2ip.io"})
	added := selectorsChange(t, before, after)
	if !slices.Equal(added.Domain.Sorted(), []string{"2ip.io"}) || !slices.Equal(added.DomainSuffix.Sorted(), []string{".2ip.io"}) {
		t.Errorf("added = %+v", added)
	}
	if !added.Matches("2ip.io", "188.40.167.81", "") || !added.Matches("www.2IP.io", "", "") {
		t.Error("the added domain must match")
	}
	if added.Matches("example.com", "", "") || added.Matches("my2ip.io", "", "") || added.Matches("", "188.40.167.81", "") {
		t.Error("unrelated connections must not match")
	}
	// Removing is a change too; same file twice is none.
	if !selectorsChange(t, after, before).Equal(added) {
		t.Error("removal must produce the same change")
	}
	if !selectorsChange(t, after, after).IsEmpty() {
		t.Error("an unchanged file is no change")
	}
}

func TestAppWildcardAndIPMatchersCoverTheirConnections(t *testing.T) {
	empty := `{"rules":[],"version":3}`
	app := selectorsChange(t, empty, `{"rules":[{"process_path_regex":["(?i)^C:\\\\Program Files\\\\Telegram Desktop\\\\Telegram\\.exe$"]}],"version":3}`)
	if !app.Matches("", "194.221.250.50", `C:\Program Files\Telegram Desktop\Telegram.exe`) ||
		!app.Matches("", "", `c:\program files\telegram desktop\telegram.exe`) {
		t.Error("the app rule must match its executable, case-insensitively")
	}
	if app.Matches("", "", `C:\Program Files\Telegram Desktop\Updater.exe`) || app.Matches("", "", "") {
		t.Error("other executables must not match")
	}
	macApp := selectorsChange(t, empty, `{"rules":[{"process_path_regex":["^/Applications/Telegram\\.app/"]}],"version":3}`)
	if !macApp.Matches("", "", "/Applications/Telegram.app/Contents/MacOS/Telegram") || macApp.Matches("", "", "/Applications/Safari.app/x") {
		t.Error("the bundle rule is wrong")
	}

	wildcard := selectorsChange(t, empty, `{"rules":[{"domain_regex":["^[^.]+\\.cdn\\.example\\.com$"]}],"version":3}`)
	if !wildcard.Matches("a.cdn.example.com", "", "") || wildcard.Matches("cdn.example.com", "", "") {
		t.Error("the wildcard rule is wrong")
	}
	invalid := selectorsChange(t, empty, `{"rules":[{"domain_regex":["("]}],"version":3}`)
	if invalid.Matches("(", "", "") {
		t.Error("an invalid regex never matches")
	}

	ip := selectorsChange(t, `{"rules":[{"ip_cidr":[]}],"version":3}`, `{"rules":[{"ip_cidr":["93.184.216.0/24","10.8.0.1"]}],"version":3}`)
	if !ip.Matches("", "93.184.216.34", "") || !ip.Matches("", "10.8.0.1", "") {
		t.Error("the CIDR rule must match its addresses")
	}
	if ip.Matches("", "93.184.217.1", "") || ip.Matches("", "2606:2800::1", "") || ip.Matches("", "not an ip", "") {
		t.Error("other addresses must not match")
	}
}

func TestOnlyTheListedFilesCount(t *testing.T) {
	empty := domainRules(nil, nil)
	a := domainRules([]string{"a.example"}, nil)
	b := domainRules([]string{"b.example"}, nil)
	selectors, ok := RuleSetChange(map[string]string{"a.json": empty, "b.json": empty}, map[string]string{"a.json": a, "b.json": b}, []string{"a.json"})
	if !ok || !slices.Equal(selectors.Domain.Sorted(), []string{"a.example"}) {
		t.Errorf("listed files = %+v, %v", selectors, ok)
	}
	// A file that did not exist before counts as empty.
	created, ok := RuleSetChange(map[string]string{}, map[string]string{"a.json": a}, []string{"a.json"})
	if !ok || !slices.Equal(created.Domain.Sorted(), []string{"a.example"}) {
		t.Errorf("created file = %+v, %v", created, ok)
	}
	// Two files' changes add up.
	both, ok := RuleSetChange(map[string]string{}, map[string]string{"a.json": a, "b.json": b}, []string{"a.json", "b.json"})
	if !ok || !slices.Equal(both.Domain.Sorted(), []string{"a.example", "b.example"}) {
		t.Errorf("both files = %+v, %v", both, ok)
	}
}

func TestUnexpectedFileShapesAreUnknown(t *testing.T) {
	empty := domainRules(nil, nil)
	for _, text := range []string{"{}", `{"version": 3, "rules": [{"port": 53}]}`, `{"version": 3, "rules": [{"network": "udp"}]}`, `{"rules": [{"domain": 5}]}`, "not json", "[]"} {
		if _, ok := RuleSetChange(map[string]string{selectorsFile: empty}, map[string]string{selectorsFile: text}, []string{selectorsFile}); ok {
			t.Errorf("%s must be unknown", text)
		}
	}
	// A single string is accepted where the generator writes a list, and case is folded.
	selectors, ok := ParseRuleSetSelectors(`{"rules":[{"domain":"Example.COM","domain_suffix":".B.example"}]}`)
	if !ok || !selectors.Domain.Has("example.com") || !selectors.DomainSuffix.Has(".b.example") {
		t.Errorf("single-string matchers = %+v, %v", selectors, ok)
	}
	// The real fixtures parse.
	fixture, ok := ParseRuleSetSelectors(readFixture(t, "singbox", "app-rules", RuleSet(idA)))
	if !ok || !fixture.ProcessPathRegex.Has(`^/Applications/Telegram\.app/`) || !fixture.Domain.Has("api.other.com") {
		t.Errorf("fixture selectors = %+v, %v", fixture, ok)
	}
}
