# system-updates tests

`run.sh` is the entry point: it runs the static guard first and then the
behavioral test, so one command covers both.

```bash
packages/system-updates/tests/run.sh
# -> PASS SystemUpdatesService.qml: ... every root.<name> assignment resolves
# -> system-updates logic test: PASS
```

## `check-root-refs.py` — static guard

Fails when a file ASSIGNS a `root.<name>` it never declares. QML only reports
that as `Cannot assign to non-existent property "<name>"` at runtime, and only
when the assigning code path runs — so a callback the behavioral test never
exercises (a `Process`'s `onExited`, for instance) hides it completely. This
guard is what caught the missing `miseProbed`/`miseAvailable` pair that the
behavioral test passed straight through.

Assignment-only on purpose: reads of inherited members (the card's
`root.open()`/`root.close()` from `BarPopup`) are legal.

```bash
tests/check-root-refs.py overlays/modules/services/SystemUpdatesService.qml
```

Falsifiable: deleting a property declaration the file assigns to fails the run.

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
