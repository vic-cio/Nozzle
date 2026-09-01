# Nozzle — working notes

Native macOS (SwiftUI) host for a Creality Ender-5 Pro over USB serial. Replaces
Pronterface. Not a slicer — it loads `.gcode` produced by Cura.

**Read `README.md` first.** It carries the architecture, the Marlin protocol gotchas and
the verified hardware findings. This file is only the state of play.

## Commands

```bash
swift build && swift test          # 126 tests, no hardware needed
./build-app.sh && open Nozzle.app  # build + run the real app
NOZZLE_DEMO=1 ./Nozzle.app/Contents/MacOS/Nozzle    # launch into the simulator
NOZZLE_REAL_PORT=/dev/cu.usbserial-1110 swift test --filter Hardware   # read-only hw check
```

## The milestones

| # | Scope | State |
|---|---|---|
| 1 | App shell, port discovery, connect/handshake, `M115`/`M105`, Console | Done, **verified on the physical printer** |
| 2 | Homing, jogging, motors off, extrude/retract, heaters, preheat presets | Code complete, **interactive hardware checks owed** |
| 3 | Load Cura G-code, validate it, stream a print with progress | Done, **verified by first physical print** |
| 4 | Pause/resume/cancel, temperature graph, sleep prevention | Code complete, **graph seen on hardware; pause/stop checks owed** |
| 5 | Guided bed levelling, polish, error handling | Planned — see `MILESTONE-5.md` |

**Milestone 1 (done).** Everything in the README's "What the actual printer reported"
section was measured on the real machine.

**Hot-plug detection (2026-08-11, verified on the physical printer).** The printer used
to have to be plugged in *before* launching Nozzle. `SerialPortMonitor` (NozzleCore) arms
IOKit attach/detach notifications and refreshes the picker by itself; Victor confirmed
both directions on the real printer — the port appears on plug-in with the app already
running, and disappears on unplug. It never auto-connects: opening the port resets a
Creality board.

**Milestone 2 (built, untested on hardware).** Homing all axes or one, jogging
0.1/1/10/100 mm, motors off, extrude/retract, per-heater targets, PLA/PETG preheat, cool
down, live position via `M400` + `M114`.

**Milestone 3 (done, hardware-verified).** `GCodeFile` loads and validates a file
against the profile; `PrintJob` streams it and reports progress; the Print screen picks a
file (button or drag-and-drop), shows what it will do, and prints it. Stop works and parks
the machine safely. On 2026-08-10 the first physical print completed successfully and
produced a solid part with the expected proportions; see `HARDWARE-TESTS.md` for the exact
evidence and what that result does not yet prove. A later print (2026-08-11) failed on its
first layer and was stopped — bed gap and a dirty bed, not the app, and a reminder that
Milestone 5's guided levelling is the thing standing between Victor and reliable prints.
A 3DBenchy then printed cleanly on 2026-08-12 once the bed was re-levelled and coated with
diluted PVA: the densest command stream Nozzle has handled, with no sign of the host
failing to keep the motion buffer fed.

**Milestone 4 (built, untested on hardware).** Pause retracts, lifts and parks the nozzle;
Resume returns in the safe reverse order and restores the file's movement, extrusion and
feedrate modes. Stop parks without relying on `M112`. The Print and Temperatures screens
show a rolling temperature graph, and Nozzle prevents Mac sleep for the life of a print.

**Simulator UI smoke check still owed.** The release app builds and launches, but the
macOS UI-capture service timed out for every app on 2026-08-10, so the Pause/Resume
controls were not clicked through visually. When UI automation is available, run
`NOZZLE_DEMO=1 ./Nozzle.app/Contents/MacOS/Nozzle`, start a simulated print, then verify
Pause parks at X10/Y10, Resume carries on, and the phase banner and graph render cleanly.

**Milestone 5 (planned).** `MILESTONE-5.md` is the implementation contract. Physical
print gate passed on 2026-08-10; targeted interactive-control and Pause/Stop checks remain,
and their real-printer findings override the draft.

## Hardware verification still owed

Milestone 3 has completed a physical print. Interactive controls in Milestone 2 and the
pause/stop paths in Milestone 4 still need targeted hardware checks. **Ask Victor before
anything physical.** The remaining checks are recorded in `HARDWARE-TESTS.md`.

1. Exercise Home, 10 mm X/Y/Z jogs, heater targets and 5 mm extrusion from their
   interactive controls.
2. Pause/Resume a safe print and inspect the resume point.
3. Test a five-minute pause on a later run.
4. Deliberately Stop a safe test and confirm the final machine state.

## Where things live

- `MovePlanner` (NozzleCore) — the decision layer for anything that moves or heats. Pure
  functions over a profile and the last known position, so every limit is testable without
  a printer. **Put new movement logic here**, not in `PrinterController` or a view.
- `GCodeFile` (NozzleCore) — parsing, layer/`;TIME_ELAPSED` indexing, and the
  profile checks behind the blocking/advisory warnings on the Print screen.
- `PrintJob` (NozzleCore) — the streaming loop and progress. Deliberately dull: send a
  line, wait for its `ok`, send the next.
- `PrinterController` (app) — the only thing SwiftUI touches. Thin on purpose; it
  sequences the above and owns UI state.

## Non-negotiables

- **The UI never touches the serial port.** Views → `PrinterController` (@MainActor)
  → `MarlinConnection` (actor) → `SerialTransport`. Keep that direction.
- **Conservative wins over clever** for anything that moves the nozzle or heats a
  heater. State the assumption in a comment rather than guessing silently.
- **Never assume firmware capability from the printer model.** Query it, and verify the
  answer actually works — see the `M155` story in the README.
- **Do not claim hardware behaviour is tested unless it was run against the real
  printer**, and ask before doing anything physical (movement, heating, or connecting
  while a print might be running).
- Every protocol change needs a test against `MockMarlinPrinter`; it can inject resends,
  mid-job disconnects, thermal faults and corrupt auto-reports.

## This machine's quirks (measured, not assumed)

- Port `/dev/cu.usbserial-1110` @ 115200. Firmware `Marlin Creality 3D`, Ender-5 Pro.
- **No emergency parser** (`Cap:EMERGENCY_PARSER:0`) — `M112` queues behind pending
  moves and is *not* an immediate stop. Stop therefore uses a safe park sequence instead.
- **`AUTOREPORT_TEMP` advertised but broken** — `M155` output arrives with every chunk
  duplicated. Nozzle verifies and falls back to `M105` polling.
- Board does **not** reset on port open (no `start` banner).
- No auto-level, no Z probe → manual bed levelling for Milestone 5.

## Filament and test print

Elegoo white PLA, 1.75 mm, 205–230 °C. The PLA preheat preset defaults to **210 °C** /
60 °C bed, not the 200 °C in the original spec.

Test file: `~/Documents/3D prints/CE5_xyzCalibration_cube.gcode` — Cura 5.13, ~42×42×20 mm,
100 layers @ 0.2 mm, ~30 min, sliced 210 °C / 50 °C. Has `;LAYER_COUNT:` and per-layer
`;TIME_ELAPSED:`, so remaining-time can be interpolated properly instead of guessed
linearly.

## Audience

Victor is new to this. Prefer plain language over Marlin jargon in the UI, explain *why*
something is blocked rather than greying it out, and keep the technical surface in
Advanced → Console.
