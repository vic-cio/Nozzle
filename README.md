# Nozzle

A native macOS app for controlling a Creality Ender-5 Pro (or any Marlin printer) over
USB, and printing G-code sliced in Cura. It replaces Pronterface for everyday use.

Nozzle is **not** a slicer. Keep slicing in Cura; Nozzle loads the `.gcode` it produces.

---

## Building and running

You need Xcode installed (any recent version). Then, in Terminal:

```bash
cd nozzle
./build-app.sh
open Nozzle.app
```

That produces `Nozzle.app` in the project folder — a normal macOS app you can
double-click, drag to `/Applications`, or keep in the Dock.

To run the tests (they need no printer attached):

```bash
swift test
```

To look around the app without a printer, turn on the **Demo** switch in the header. It
connects to a built-in simulated Marlin printer. You can also launch straight into it:

```bash
NOZZLE_DEMO=1 ./Nozzle.app/Contents/MacOS/Nozzle
```

### Command-line tools

Use `swift run nozzle-cli --help` for file inspection, validation, command previews,
profile inspection, serial discovery, and local control of the running app. Reports
are JSON by default. The app remains the only process that opens the printer connection,
so CLI commands can work alongside the GUI. See [CLI usage](docs/cli.md) for commands,
exit codes, and validation limits.

### Why there is no `.xcodeproj`

Nozzle is a Swift Package. `swift build` and `swift test` work from the terminal, and
you can still open the folder in Xcode (`File ▸ Open`, pick the `nozzle` folder) and
build/debug normally. `build-app.sh` only exists because Swift Package Manager produces
a bare executable, and macOS wants an `.app` bundle.

---

## What it does

- **Print** — choose a `.gcode` file with the button or by dropping it on the window.
  Nozzle reads it, shows the size, layer count, estimated time, filament and temperatures,
  and checks it against your printer before offering the Print button. While printing it
  shows progress, the layer, time remaining, both temperatures and a rolling graph. Pause
  retracts, lifts and parks the nozzle; Resume safely returns to the same point. Stopping
  lifts clear, parks, turns the heaters off and releases the motors.
- **Prepare** — homing (all axes or one), jogging in 0.1/1/10/100 mm steps, quick moves
  to positions 30 mm inside each bed corner for manual levelling, motors off, extrude and
  retract, live position. Corner moves change X before Y to clear the side-mounted bed
  clips and deliberately leave Z untouched.
- **Temperatures** — a target for each heater, PLA and PETG preheat presets, cool down,
  and a rolling temperature-history graph.
- **Console** — send any command by hand, with a confirmation on the risky ones.

### Real-world Marlin/Creality findings

Testing against a Creality-firmware Ender-5 Pro at 115200 baud surfaced two quirks that
shape how Nozzle talks to the printer:

1. **`Cap:EMERGENCY_PARSER:0`** — this firmware has no emergency parser, so `M112` is
   *not* immediate: it only runs once the queued moves ahead of it finish. Nozzle warns
   about this on connect. For a genuine emergency, the power switch is faster. This also
   is why Stop uses a safe park sequence instead of `M112`.
2. **`Cap:AUTOREPORT_TEMP:1` is advertised, but the auto-reports are corrupt.** Replies
   to commands are clean, but `M155` output arrives with every chunk duplicated:

   ```
   ok T:25.91 /0.00 B:26.85 /0.00 @:0 B@:0          ← M105 reply, fine
     TT::25.9125.91  //0.000.00  BB::26.8526.85     ← M155 auto-report, unreadable
   ```

   This is a known quirk of Creality builds that compile in a second serial port: Marlin
   writes the report to both ports and both land on the same UART. Nozzle therefore
   *verifies* auto-reporting rather than trusting the capability flag — if no readable
   report arrives within a few seconds it sends `M155 S0` and falls back to `M105`
   polling, with an explanation in the Console. Without that check the temperature
   readout would have silently frozen after connecting.

Point `NOZZLE_REAL_PORT` at your printer's serial device to re-run this check against
real hardware:

```bash
NOZZLE_REAL_PORT=/dev/cu.usbserial-XXXX swift test --filter Hardware
```

---

## How it is put together

```
SerialTransport (protocol)  ──┬── PosixSerialTransport   real port: termios + poll()
   bytes in / bytes out       └── MockMarlinPrinter      simulated firmware
            │
MarlinConnection (actor)     command queue, line numbers + checksums, resend
            │                recovery, acknowledgement tracking, timeouts
   AsyncStream<MarlinEvent>
            │
PrinterController (@MainActor @Observable)   the only thing SwiftUI touches
            │
   PrinterState / PrinterProfile / TrafficLog
```

The rules that keep this safe:

- **The UI never touches the serial port.** Views call `PrinterController`, which awaits
  into the `MarlinConnection` actor. All serial I/O happens off the main thread.
- **The transport knows nothing about Marlin**, and the protocol layer knows nothing
  about ports. Either can be tested alone, and `MockMarlinPrinter` is a drop-in for the
  real thing.
- **A transport is single-use.** Reconnecting builds a new one, which removes any chance
  of a stale reader thread from a previous connection.
- **The port list is never a launch-time snapshot.** `SerialPortMonitor` arms IOKit
  attach/detach notifications, so plugging the printer in with Nozzle already running
  refills the picker on its own. IOKit only says *when*; the list is still rebuilt from
  `/dev` by `SerialPortDiscovery`, so there is one source of truth rather than two that
  can drift apart. Detection never auto-connects: opening the port asserts DTR and
  resets a Creality board, which is not something to do unasked.

### Dependencies

None beyond Apple's own frameworks. The serial layer is POSIX `termios` plus `poll()`,
with IOKit used to look up friendly USB product names and to watch for devices being
plugged in. ORSSerialPort was considered
and rejected: it is Objective-C and delegate-based with no Swift 6 concurrency audit, and
non-standard baud rates need a raw `ioctl` regardless, so it would have added a
dependency without removing any real work.

---

## Notes on the Marlin protocol

Things that are easy to get wrong, and how Nozzle handles them:

- **Checksums.** Every queued command is sent as `N<line><command>*<checksum>`, where the
  checksum is the XOR of every byte of `N<line><command>`. This is what makes resend
  recovery possible; without it a corrupted line is simply lost.
- **`M110` must be queued, not written raw.** Writing it directly produces an `ok` that no
  queued command owns, and the next command consumes it — leaving every acknowledgement
  from then on off by one, so the host runs permanently one command ahead of the
  printer's buffer. (This bug existed briefly during development and is covered by tests.)
- **Marlin sends `ok` *after* `Resend: N`.** That `ok` means "ready for the replay", not
  "your command succeeded". Crediting it to a queued command would mark a command complete
  that the printer never ran.
- **`echo:busy: processing` is not an acknowledgement.** It is a keepalive, and it must
  postpone the command timeout — otherwise every heat-up looks like a stall.
- **`ok N42 P15 B4` versus `ok B:59.7 /60.0`.** In the first, `B4` is free buffer slots;
  in the second, `B:` is the bed temperature. The colon is the only thing telling them
  apart.
- **Opening the port resets the board.** Creality boards reset when DTR is asserted, so
  connecting waits for the `start` banner before doing anything. `HUPCL` is cleared so
  that *closing* the port does not reset the printer.
- **One command in flight at a time**, by default — the same thing Pronterface and
  OctoPrint do. A wider window is faster but is the classic cause of serial buffer
  overruns. It is a setting (`maxInFlightCommands`, 1–4) to be tuned with real prints.
- **Temperature reporting never blocks the print stream.** Where the firmware supports
  `Cap:AUTOREPORT_TEMP`, Nozzle sends `M155 S2` and the printer reports on its own,
  costing no queue slots. Otherwise it polls `M105`, and never queues a second poll while
  one is outstanding.
- **Jogging is relative (`G91`), never absolute.** A relative nudge is correct even when
  the host's idea of the position has drifted — say the user moved the printer from its
  own screen. An absolute move computed from a stale position goes somewhere nobody asked
  for. Every jog restores `G90` immediately afterwards, and the extruder gets `M83`/`M82`
  for the same reason, because `G91` and `M83` are separate flags in Marlin.
- **`M114` alone reports where the nozzle is *going*.** Marlin answers with the position
  at the end of everything already queued, so asking straight after a jog returns the
  destination rather than the current location. Nozzle sends `M400` first — "tell me when
  the queued moves have finished" — so the number on screen is where the nozzle actually
  is.
- **Interactive heating uses `M104`/`M140`, never `M109`/`M190`.** The blocking forms hold
  the command queue until the target is reached, which on a cold bed is several minutes
  during which nothing else gets through — including turning the heater back off. Files
  that ask for the blocking form during a print still get it.
- **Where "home" is, is not assumed.** After `G28` Nozzle asks `M114` rather than writing
  0, 0, 0 into its own state: the answer depends on the machine's endstop positions and
  the firmware's home offset, and this is exactly the kind of guess the `M155` story
  warns against.
- **A `start` banner mid-session invalidates the position.** The board has rebooted, so it
  no longer knows where its axes are. The connection reports this as an event and the
  homed state is dropped; continuing to show "homed" would invite a jog into the frame.
- **A layer ends at its `;TIME_ELAPSED:` marker, not at the next `;LAYER:`.** Cura writes
  that marker where the layer's timed work finishes. Running each layer's span to the
  start of the next one sweeps the file's footer — cool the heaters, park, disable the
  steppers — into the final layer, and the progress bar stops short of 100%. (This bug
  existed during development and is covered by tests.)
- **Progress is measured in time, not in lines.** A dense infill layer has far more
  commands than a tall thin one: on the calibration cube, halfway through the file by line
  count is 57% through by time. Interpolating inside the layers Cura already timed gives a
  countdown that does not lurch.
- **The print stream must never go through `CommandSafety`.** That check is for hand-typed
  console commands. Cura's header legitimately contains `M201` and `M203`, both of which
  are on the dangerous list, and a confirmation sheet mid-print would be absurd.
- **A file's own header does the preheat and homing.** Cura emits `M190`/`M109`/`G28`
  before the first layer, so Nozzle must not do it as well. The blocking heats are fine
  here: they get Marlin's long timeout, and `echo:busy: processing` postpones it.
- **Pause tracks the file's modal state.** Parking uses `G91` to lift, `G90` to move to
  the park point and its own feedrates. Before streaming resumes, Nozzle restores the
  exact `G90`/`G91`, `M82`/`M83` and last `F` value the file was using. Leaving any one
  behind would move the next line to the wrong place, alter its extrusion, or print the
  rest of the layer at parking speed.
- **Pause reads the real position before it moves.** It sends `M400` then `M114`, and
  refuses to pause if that reply cannot be read. A pause with no trustworthy return point
  cannot be resumed safely, so continuing the print is the conservative choice.
- **Pause order is retract → lift → park; Resume mirrors it.** Resume crosses the bed in
  XY while still lifted, lowers Z only above the saved point, then primes by exactly the
  amount it retracted. Lowering before crossing could drag through the part; priming at
  the park point would leave a blob there.
- **Stop is tidy, not instantaneous.** Marlin may already have roughly a planner-buffer's
  worth of acknowledged motion, and it finishes that before processing Nozzle's retract,
  lift, park, heaters-off and motors-off sequence. This firmware has no emergency parser,
  so `M112` would wait too and then halt the board until it is power-cycled. For a genuine
  emergency, use the printer's power switch.
- **250000 baud is unreliable on macOS.** It is not a standard `termios` speed and needs
  the `IOSSIOSPEED` ioctl; several USB-serial drivers silently stay at 9600 instead of
  failing. Nozzle reads the rate back and refuses to pretend it worked. 115200 is a
  standard rate and is unaffected.

### Safety

- **Nothing moves until the printer has been homed** — all three axes, not just the one
  being jogged. Marlin only enforces its software endstops on a homed axis, and on this
  machine homing Z depends on where X and Y are.
- **Every jog is checked against the build volume** before it is sent. A move that would
  leave the volume is shortened to stop at the edge, and the user is told what happened
  rather than watching the axis stop early for no visible reason.
- **Motors off (`M84`) clears the homed state.** With the steppers released the axes can
  be pushed by hand, so the firmware's position becomes a guess and so does Nozzle's.
- **A blocked control explains itself** instead of being greyed out in silence — why the
  nozzle is too cold to extrude, which axes still need homing, what the limit is.
- The connection is dropped and reported as an **error**, never silently, if the printer
  stops responding, halts itself (thermal runaway, `MINTEMP`/`MAXTEMP`), resets
  unexpectedly, or requests too many resends in a row.
- A failure state is never downgraded to a plain "Disconnected", so the reason survives.
- Marlin's own thermal protection is never touched.
- `M112` and other emergency commands bypass the queue. Nozzle checks
  `Cap:EMERGENCY_PARSER` and warns you when the firmware lacks it, because without it
  `M112` only takes effect once queued moves finish — it is not a real emergency stop.
- Risky console commands (`M502`, `M851`, `G29`, `M112`, …) require a confirmation that
  explains what will happen.

---

## The printer profile

Defaults are for a stock Ender-5 Pro: 220 × 220 × 300 mm, 0.4 mm nozzle, 1.75 mm
filament, 115200 baud. Every value is editable, and stored as readable JSON at:

```
~/Library/Application Support/Nozzle/printer-profile.json
```

These are starting points, not assumptions. Where Marlin can tell us the truth — via
`M115` capabilities — the firmware wins over anything in the profile.

It also holds the jog feedrates (3000 mm/min for X and Y, 600 for the Z leadscrew, 300
for filament) and the PLA preheat preset, which defaults to 210 °C.

The file is decoded tolerantly: any key it does not contain falls back to the default, so
a profile written by an older version of Nozzle keeps the port and build volume you had
set instead of being discarded wholesale. Editing it by hand is meant to be safe.
