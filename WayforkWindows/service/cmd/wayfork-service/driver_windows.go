//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"wayfork/service/internal/core"
	"wayfork/service/internal/service"
	"wayfork/service/internal/winnet"
	"wayfork/service/internal/winproc"
)

// The two installer subcommands (docs/design/08-windows.md, "Installer"). The MSI is
// deliberately thin: publishing the ovpn-dco package and undoing everything Wayfork left
// on the machine are Windows plumbing, which belongs here — with tests — rather than in a
// custom action.

// driverToolTimeout bounds pnputil and tapctl; a driver install is seconds, not minutes.
const driverToolTimeout = 3 * time.Minute

// installDriver publishes the bundled ovpn-dco package with pnputil after checking its
// catalog signature, and records what it published so uninstall removes that package and
// only that one.
func installDriver() error {
	env, err := installerEnvironment()
	if err != nil {
		return err
	}
	inf := env.DriverInfPath()
	contents, err := os.ReadFile(inf)
	if err != nil {
		return fmt.Errorf("driver package: %w", err)
	}
	if err := verifyDriverCatalogs(filepath.Dir(inf)); err != nil {
		return err
	}
	runner, err := winproc.NewRunner()
	if err != nil {
		return err
	}
	defer runner.Close()
	ctx, cancel := context.WithTimeout(context.Background(), driverToolTimeout)
	defer cancel()

	before, err := driverStore(ctx, runner)
	if err != nil {
		return err
	}
	// An upgrade must not re-publish the same package: after a pnputil re-install OpenVPN
	// reports the driver missing until a reboot (spike gotcha).
	version := core.InfDriverVersion(string(contents))
	for _, candidate := range core.FindDriverPackages(before, core.DriverOriginalName) {
		if version != "" && candidate.Version == version {
			fmt.Printf("ovpn-dco %s is already in the driver store as %s\n",
				version, candidate.PublishedName)
			return nil
		}
	}
	result, err := runner.Run(ctx, service.ProcessSpec{
		Executable: pnputilPath(), Args: []string{"/add-driver", inf, "/install"},
	})
	if err != nil {
		return fmt.Errorf("pnputil /add-driver: %w", err)
	}
	// 3010 is "installed, reboot required"; the dco package does not need one, but a
	// machine that asks is not a failure.
	if !result.Succeeded() && result.ExitCode != 3010 {
		return fmt.Errorf("pnputil /add-driver failed (exit %d): %s", result.ExitCode, result.Output())
	}
	after, err := driverStore(ctx, runner)
	if err != nil {
		return err
	}
	published, ok := core.NewlyPublished(before, after, core.DriverOriginalName)
	if !ok {
		fmt.Println("ovpn-dco was already in the driver store; leaving it there on uninstall")
		return nil
	}
	record := core.DriverRecord{
		Version:       core.DriverRecordVersion,
		PublishedName: published.PublishedName,
		OriginalName:  published.OriginalName,
		DriverVersion: published.Version,
	}
	if err := writeDriverRecord(env, record); err != nil {
		return err
	}
	fmt.Printf("published %s as %s\n", core.DriverOriginalName, published.PublishedName)
	return nil
}

// uninstallCleanup undoes what Wayfork left on the machine: the Wayfork-N adapters first,
// then the driver package this installer published, then the NRPT rule. It reports
// problems but always exits 0 — an uninstall that fails halfway is worse than one that
// leaves a stray adapter behind.
func uninstallCleanup() error {
	env, err := installerEnvironment()
	if err != nil {
		fmt.Fprintln(os.Stderr, "cleanup:", err)
		return nil
	}
	runner, err := winproc.NewRunner()
	if err != nil {
		fmt.Fprintln(os.Stderr, "cleanup:", err)
		return nil
	}
	defer runner.Close()
	ctx, cancel := context.WithTimeout(context.Background(), driverToolTimeout)
	defer cancel()

	for _, step := range []func(context.Context, service.Environment, *winproc.Runner) error{
		deleteAdapters, deleteDriverPackage, removeResolverOverride, removeRunDirectory,
	} {
		if err := step(ctx, env, runner); err != nil {
			fmt.Fprintln(os.Stderr, "cleanup:", err)
		}
	}
	return nil
}

// deleteAdapters removes every Wayfork-N adapter with the bundled tapctl. They must go
// before the driver package: `pnputil /delete-driver /uninstall` leaves the root devnodes
// behind and the next install re-binds them under other names (spike S2.2).
func deleteAdapters(ctx context.Context, env service.Environment, runner *winproc.Runner) error {
	names, err := winnet.WayforkAdapterNames()
	if err != nil {
		return err
	}
	if len(names) == 0 {
		return nil
	}
	tapctl := env.TapctlPath()
	if _, err := os.Stat(tapctl); err != nil {
		return fmt.Errorf("cannot delete %s: %w", strings.Join(names, ", "), err)
	}
	var problems []string
	for _, name := range names {
		result, err := runner.Run(ctx, service.ProcessSpec{
			Executable: tapctl, Args: []string{"delete", name},
		})
		switch {
		case err != nil:
			problems = append(problems, fmt.Sprintf("tapctl delete %s: %v", name, err))
		case !result.Succeeded():
			problems = append(problems, fmt.Sprintf(
				"tapctl delete %s (exit %d): %s", name, result.ExitCode, result.Output()))
		default:
			fmt.Println("deleted adapter", name)
		}
	}
	return joinProblems(problems)
}

// deleteDriverPackage removes the package `--install-driver` recorded, if it is still in
// the store. Without a record nothing is touched: the copy on the machine then belongs to
// an OpenVPN install or to an installer that ran before this one.
func deleteDriverPackage(ctx context.Context, env service.Environment, runner *winproc.Runner) error {
	record, err := readDriverRecord(env)
	if err != nil {
		return err
	}
	if record == nil {
		return nil
	}
	packages, err := driverStore(ctx, runner)
	if err != nil {
		return err
	}
	present := false
	for _, candidate := range core.FindDriverPackages(packages, record.OriginalName) {
		if candidate.PublishedName == record.PublishedName {
			present = true
			break
		}
	}
	if present {
		result, err := runner.Run(ctx, service.ProcessSpec{
			Executable: pnputilPath(),
			Args:       []string{"/delete-driver", record.PublishedName, "/uninstall"},
		})
		switch {
		case err != nil:
			return fmt.Errorf("pnputil /delete-driver: %w", err)
		case !result.Succeeded() && result.ExitCode != 3010:
			return fmt.Errorf("pnputil /delete-driver %s failed (exit %d): %s",
				record.PublishedName, result.ExitCode, result.Output())
		default:
			fmt.Println("removed driver package", record.PublishedName)
		}
	}
	if err := os.Remove(env.RunPath(core.DriverRecordFile)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// removeResolverOverride drops the NRPT rule and its record. The service restores the
// override when it stops, and the MSI stops it first, so this is the crash path.
func removeResolverOverride(ctx context.Context, env service.Environment, runner *winproc.Runner) error {
	resolver := winnet.NewResolver(runner)
	snapshot, err := resolver.Snapshot(ctx)
	if err != nil {
		return err
	}
	var names []string
	for _, rule := range snapshot.Rules {
		if rule.IsWayfork() {
			names = append(names, rule.Name)
		}
	}
	if len(names) > 0 {
		if err := resolver.RemoveRules(ctx, names); err != nil {
			return err
		}
		fmt.Println("removed the NRPT rule")
	}
	if err := os.Remove(env.RunPath(core.ResolverOverrideRecordFile)); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// removeRunDirectory drops `%ProgramData%\Wayfork\run` — configurations, rule sets and
// the records above. The logs next to it stay: they are what a bug report is made of.
func removeRunDirectory(_ context.Context, env service.Environment, _ *winproc.Runner) error {
	if err := os.RemoveAll(env.Layout.Dir); err != nil {
		return err
	}
	return nil
}

// verifyDriverCatalogs checks the Authenticode signature of every catalog in the package
// directory; `pnputil` would refuse an untrusted package as well, but the installer says
// so before Windows does, and with our own message.
func verifyDriverCatalogs(directory string) error {
	catalogs, err := filepath.Glob(filepath.Join(directory, "*.cat"))
	if err != nil {
		return err
	}
	if len(catalogs) == 0 {
		return fmt.Errorf("no catalog next to %s", core.DriverOriginalName)
	}
	for _, catalog := range catalogs {
		if err := winnet.VerifyDriverCatalog(catalog); err != nil {
			return fmt.Errorf("%s is not signed by a trusted publisher: %w", filepath.Base(catalog), err)
		}
	}
	return nil
}

func driverStore(ctx context.Context, runner *winproc.Runner) ([]core.DriverPackage, error) {
	result, err := runner.Run(ctx, service.ProcessSpec{
		Executable: pnputilPath(), Args: []string{"/enum-drivers"},
	})
	if err != nil {
		return nil, fmt.Errorf("pnputil /enum-drivers: %w", err)
	}
	if !result.Succeeded() {
		return nil, fmt.Errorf("pnputil /enum-drivers failed (exit %d)", result.ExitCode)
	}
	return core.ParseDriverStore(result.Output()), nil
}

func writeDriverRecord(env service.Environment, record core.DriverRecord) error {
	if err := env.PrepareDirectories(); err != nil {
		return err
	}
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	return core.WriteFileAtomic(env.RunPath(core.DriverRecordFile), data, 0o600)
}

func readDriverRecord(env service.Environment) (*core.DriverRecord, error) {
	data, err := os.ReadFile(env.RunPath(core.DriverRecordFile))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var record core.DriverRecord
	if err := json.Unmarshal(data, &record); err != nil {
		return nil, fmt.Errorf("%s: %w", core.DriverRecordFile, err)
	}
	if record.PublishedName == "" || record.OriginalName == "" {
		return nil, fmt.Errorf("%s names no driver package", core.DriverRecordFile)
	}
	return &record, nil
}

// pnputilPath is the native pnputil; the service is never the emulated x64 build, so
// System32 is the right directory on ARM64 too.
func pnputilPath() string {
	if root := os.Getenv("SystemRoot"); root != "" {
		return filepath.Join(root, "System32", "pnputil.exe")
	}
	return "pnputil.exe"
}

func joinProblems(problems []string) error {
	if len(problems) == 0 {
		return nil
	}
	return errors.New(strings.Join(problems, "; "))
}
