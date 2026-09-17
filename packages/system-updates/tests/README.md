# system-updates tests

## `run.sh` — service logic test

Runs the **real** `overlays/modules/services/SystemUpdatesService.qml` under
Quickshell and asserts the behavior the card and bar depend on:

- a never-scanned source reports `unknown` (never a green check),
- a failed scan reports `error` (never a green check),
- a successful scan with zero pending reports `up`,
- a successful scan with pending updates reports `count` + the number,
- a disabled source reports `off`,
- no updater is launched when no terminal is configured.

It copies the real service into `qml/qs/modules/services/` and stubs only the
two external singletons (`ModsService`, `TerminalService`); the code under test
is untouched source. Read-only: the service's own queries may run, but the
updater is never launched.

```bash
staging/system-updates/tests/run.sh
# -> system-updates logic test: PASS
```

Verified falsifiable: changing `sourceState()` to always return `up` makes the
run fail with exit 1.

Requires `qs` (Quickshell) on PATH. Override with `QS_BIN=/path/to/qs`.
