// Package winproc runs the service's children on Windows: detached, without a window,
// inside one job object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (docs/design/08-windows.md,
// "Components and trust boundary"). It implements service.ProcessRunner; every file but
// this one is Windows-only.
package winproc
