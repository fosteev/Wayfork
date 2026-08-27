package core

import (
	"path/filepath"
	"testing"
)

func TestRunLayout(t *testing.T) {
	layout := DefaultLayout(filepath.Join("C:", "ProgramData"))
	if want := filepath.Join("C:", "ProgramData", "Wayfork", "run"); layout.Dir != want {
		t.Errorf("run dir = %s, want %s", layout.Dir, want)
	}
	if want := filepath.Join("C:", "ProgramData", "Wayfork", "logs"); layout.LogDir != want {
		t.Errorf("log dir = %s, want %s", layout.LogDir, want)
	}
	if want := filepath.Join(layout.Dir, "sing-box.json"); layout.Path(SingBoxConfig) != want {
		t.Errorf("config path = %s, want %s", layout.Path(SingBoxConfig), want)
	}
	if want := filepath.Join(layout.LogDir, "openvpn-"+idA+".log"); layout.LogPath("openvpn:"+idA) != want {
		t.Errorf("log path = %s, want %s", layout.LogPath("openvpn:"+idA), want)
	}

	names := map[string]string{
		OpenVPNConfig(idA):          "t-" + idA + ".ovpn",
		ManagementPasswordFile(idA): "t-" + idA + ".mgmt",
		RuleSet(idA):                "rules-t-" + idA + ".json",
		IPRuleSet(idA):              "rules-t-" + idA + "-ip.json",
		ChildLog("openvpn:" + idA):  "openvpn-" + idA + ".log",
		ChildLog("sing-box"):        "sing-box.log",
		ChildLog("daemon"):          "daemon.log",
	}
	for got, want := range names {
		if got != want {
			t.Errorf("name %q, want %q", got, want)
		}
	}
	for _, name := range []string{SingBoxConfig, RuleSet(idA), OpenVPNConfig(idA), ManagementPasswordFile(idA), DirectRuleSet} {
		if !IsTransient(name) {
			t.Errorf("%s must be transient", name)
		}
	}
	for _, name := range []string{CacheFile, ResolverOverrideRecordFile} {
		if IsTransient(name) {
			t.Errorf("%s must survive stop", name)
		}
	}
	if !IsRuleSet(RuleSet(idA)) || !IsRuleSet(IPRuleSet(idA)) || IsRuleSet(DirectRuleSet) || IsRuleSet(SingBoxConfig) {
		t.Error("IsRuleSet is wrong")
	}
}
