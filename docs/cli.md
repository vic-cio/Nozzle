# Nozzle CLI

`nozzle-cli` is a macOS 14+ command-line companion to the app. It uses NozzleCore
without launching SwiftUI, opening serial devices, moving a printer, or modifying
files. It needs the same Swift 6 toolchain as Nozzle and adds no dependencies.

```sh
swift build --product nozzle-cli
swift run --skip-build nozzle-cli --help
```

For scripts, locate the built executable with `swift build --show-bin-path` and
append `/nozzle-cli`. The name avoids a case-insensitive collision with `Nozzle`.

```sh
nozzle-cli ports
nozzle-cli profile show
nozzle-cli file inspect cube.gcode
nozzle-cli file validate cube.gcode --profile printer.json
nozzle-cli file commands cube.gcode --offset 0 --limit 20
nozzle-cli command assess 'M502'
nozzle-cli --help --json
```

- `ports` returns ranked serial candidates, with path, kind, optional product name,
  and score. `--include-dialin` includes `/dev/tty.*` counterparts. Discovery does
  not connect or reset the board; the list can change when devices are attached.
- `profile show` returns the stock Ender-5 Pro profile. `--profile PATH` reads an
  explicit JSON profile, retaining the core's defaults for omitted fields and
  rejecting malformed data, invalid build bounds, and invalid temperature limits.
  The CLI never silently loads or updates the app's preferences. To inspect them,
  explicitly pass `--profile "$HOME/Library/Application Support/Nozzle/printer-profile.json"`.
- `file inspect` returns metadata, command/layer counts, the effective profile,
  and core validation warnings with stable IDs and `advisory`/`blocking` severity.
  Unknown metadata fields are omitted, not invented. Files are loaded in memory.
- `file validate` returns the same report, but exits 3 when any warning is blocking.
  Advisory warnings alone exit 0. This checks slicer metadata and recognized heater
  commands, **not every movement or dialect**: missing/inaccurate bounds, compact
  commands, unsupported parameters, or malformed G-code may evade core checks.
  `hasBlockingWarnings: false` is not permission to print or a safety certification.
- `file commands` previews sanitized commands using Nozzle's own comment stripping.
  `--offset` is a zero-based command index, `--limit` is 1–1000 (default 100).
  Each entry has `index`, a one-based `sourceLine`, and `command`. `nextOffset` is
  omitted at EOF; offsets beyond EOF return an empty page. Preview does not execute.
- `command assess` accepts exactly one quoted line and reports the core console
  warning classification, reason when dangerous, and emergency classification.
  It is a typo guard, not a complete G-code validator; `ordinary` does not mean safe.

Every command emits one JSON document to stdout, except text help. `--json` is
accepted anywhere before `--`; help then also returns JSON. `--` ends option parsing,
so `nozzle-cli file inspect -- -part.gcode` handles a path beginning with a dash.
Unknown/duplicate options, missing values, and extra positional arguments fail.
`--help` and `-h` display the command catalog at every command level.

Successful reports have `{"schemaVersion":1,"data":...}`. JSON keys are sorted,
there are no timestamps or progress chatter, and optional values are omitted.
Input failures leave stdout empty and write
`{"schemaVersion":1,"error":{"code":"...","message":"...","exitCode":1}}`
to stderr. Codes are `usage`, `profile_input`, `gcode_input`, and `io_error`.
Do not merge stderr into stdout when parsing JSON. Schema version 1 and CLI version
1.0.0 (`--version`) describe this initial interface.

Exit codes: **0** report produced; **1** input, encoding, or I/O error;
**2** usage error; **3** blocking validation findings (report remains on stdout).

```sh
swift build
swift test
python3 scripts/smoke-cli.py "$(swift build --show-bin-path)/nozzle-cli"
```

The smoke test runs the real executable with temporary fixtures and checks JSON,
stream separation, exit codes, help, profile overrides, pagination, and discovery.
Live printing, connection/status polling, movement, and raw command execution are
outside this intentionally small surface. Use the native app for those operations.
