# Wayfork for Windows (app)

Flutter front end of the Windows client; the privileged half is the Go service in
`../service`. Design: `docs/design/08-windows.md` (deltas from the macOS design in
`docs/design/00–07`); roadmap: `docs/ROADMAP-windows.md`.

Toolchain pins live in `../versions.env`; run `flutter pub get`, then `dart format .`,
`dart analyze --fatal-infos`, `flutter test`. `flutter build windows` needs Windows with the
Visual Studio C++ workload; the runner under `windows/` is committed, its
`generated_plugin*` files are written by `flutter pub get` there.
