# Milestone 5 — implementation draft

Status: **planned, not started; first-print gate passed 2026-08-10**. This is the
implementation contract, not a claim that the features below exist yet.

The first physical print completed successfully and is recorded in `HARDWARE-TESTS.md`.
Targeted interactive-control and Pause/Stop checks remain; their findings take priority
over this draft before the related areas are implemented.

## Goal

Make the last risky, unfamiliar part of starting a print — manually levelling a bed with
four adjustment knobs — a guided operation, then make failures throughout the app easier
to understand and recover from.

Nozzle will guide and position. The user will turn the knobs and decide when the paper
drag feels right. There is no probe on this printer, so the app must never imply that it
measured or certified the bed.

## 5A. Guided manual bed levelling

### User flow

Add a **Level the bed…** button to Prepare. It opens a sheet with one task at a time:

1. **Prepare.** Ask for a clean, cool nozzle, a clean bed and one sheet of ordinary
   printer paper. The bed must be clear of a print or tools. Offer to heat the bed to the
   profile's PLA temperature; do not heat the nozzle automatically.
2. **Home.** Explain that all three axes will move, then home all axes. Read the position
   back rather than assuming where home is.
3. **Visit the four screws.** Move to front-left, front-right, rear-right and rear-left,
   always lifting to a clearance height before crossing the bed and lowering only after
   X/Y has stopped.
4. **Adjust.** At each point, tell the user which nearby knob to turn and ask them to slide
   the paper until it has light, even drag. No automatic movement occurs while they are
   touching the knob.
5. **Repeat the four corners.** Adjusting one corner changes the others. A second circuit
   is mandatory rather than presenting one pass as finished.
6. **Check the centre.** Move to the centre for a read-only consistency check. If the
   centre feels substantially different, explain that the bed may be warped; do not tell
   the user to compensate by ruining the four corners.
7. **Finish.** Lift clear and offer either **Keep the bed warm for printing** or **Cool
   down**. Leave the axes homed and the motors engaged so the result is not immediately
   invalidated.

The sheet must always show the current step, the next physical movement, a Cancel button,
and the live X/Y/Z position. “Next” means “I have finished adjusting this point,” never
“the app measured this point.”

### Geometry and commands

The initial Ender-5 Pro points are 30 mm in from the configured build-volume edges:

| Point | X | Y |
|---|---:|---:|
| Front-left | `minX + 30` | `minY + 30` |
| Front-right | `maxX - 30` | `minY + 30` |
| Rear-right | `maxX - 30` | `maxY - 30` |
| Rear-left | `minX + 30` | `maxY - 30` |
| Centre | midpoint | midpoint |

The inset must be clamped for smaller profiles and exposed as `levelingInset` in
`PrinterProfile`, with tolerant decoding for older JSON. The first implementation uses a
5 mm travel clearance and a 0.1 mm paper height, also profile values so they can be tuned
without changing code.

Every transition to a point is planned in `MovePlanner`, in this order:

```text
G90
G0 Z<clearance> F<Z feedrate>
G0 X<point X> Y<point Y> F<XY feedrate>
M400
G0 Z<paper height> F<Z feedrate>
M400
M114
```

The plan must refuse unknown positions, out-of-volume geometry and a paper height outside
the configured Z range. It must not disable software endstops, use `G92`, release the
motors, or heat the nozzle.

Cancellation lifts to the clearance height and stops there. If the link is already lost,
the UI says that Nozzle could not perform the lift and tells the user not to turn a knob
until they have checked the nozzle is clear.

### Code shape

- `NozzleCore/Model/BedLevelPoint.swift`
  - Value describing the point name, coordinates, pass and whether it is an adjustment
    or centre check.
- `NozzleCore/Model/BedLevelSession.swift`
  - Pure state machine for prepare → home → two corner passes → centre → finish.
  - No SwiftUI, port or clock, so transitions can be exhaustively tested.
- `MovePlanner`
  - `bedLevelPoints(profile:)`
  - `moveForBedLevelling(to:from:profile:)`
  - `finishBedLevelling(from:profile:)`
- `PrinterProfile`
  - `levelingInset`, `levelingClearanceZ`, `levelingPaperZ`, all decoded tolerantly.
- `PrinterController`
  - Own the active session and sequence plans through the existing single-operation slot.
  - Abort the session on disconnect, printer reset, print start or lost position.
- `Views/BedLevelingView.swift`
  - Sheet UI only; it asks the controller to advance and never constructs G-code.
- `PrepareView`
  - Entry card/button and a short explanation that this is manual, not measured levelling.

### Safety rules

- Connected and idle only; never during a print, pause, heat operation or another move.
- Home all axes at the start even if the UI currently says they are homed.
- Move Z to clearance before every X/Y crossing.
- Keep motors on throughout the wizard.
- Abort on reset, disconnect, unreadable `M114`, or any command error.
- Show the exact next movement before the user authorises it.
- Do not call the result “level” or “calibrated”; say the guide is complete.
- The simulator must exercise the same plans and state transitions as real hardware.

## 5B. Error handling and recovery

Replace isolated generic alerts with actionable recovery where the app knows what to do:

1. **Connection loss during an operation or print** — keep the failure visible on the
   affected screen, preserve the reason, stop sleep prevention, and offer Reconnect.
2. **Printer reset** — clear homing/position, end any levelling session, and link directly
   to Home all.
3. **Stale temperature data** — after three expected reporting intervals, label the
   reading stale instead of continuing to display it as live.
4. **Unreadable position** — explain that movement is blocked because a safe destination
   cannot be calculated; offer Read position and then Home all if that still fails.
5. **Print failure** — distinguish file/protocol failure from USB disconnect and firmware
   halt. Keep the loaded file available for inspection, but never offer to resume from a
   guessed line.
6. **Stop expectations** — keep Stop's confirmation and explicitly say acknowledged
   moves may continue briefly before the park sequence begins.
7. **Persistent print diagnostics** — stream each print's traffic and phase changes to a
   bounded log in Application Support instead of relying on the 5,000-line memory buffer.
   Keep the newest five sessions, cap total storage, record whether the log is complete,
   and provide Reveal/Copy actions. Logging must never block serial I/O or grow without
   limit.

Implementation should introduce a small `UserFacingIssue` value (title, explanation and
recovery kind) in the app target. Protocol errors remain typed in NozzleCore; views still
do not parse Marlin strings or touch the connection.

## 5C. Polish

- Give every movement button a complete accessibility label and keyboard focus order.
- Keep destructive and primary buttons in consistent positions across sheets.
- Make narrow-window layouts wrap progress statistics instead of clipping them.
- Add empty/loading/stale states to the temperature graph.
- Add a visible Demo badge so simulator actions cannot be mistaken for hardware actions.
- Review every disabled control: it must retain a nearby plain-language reason.
- Run the full app in light mode, dark mode and the minimum supported window size.

This milestone does not include slicing, remote access, webcam monitoring, automatic mesh
levelling, firmware updates or resuming a failed print from the middle of a G-code file.

## Tests

### NozzleCore

- Point generation stays inside normal, offset and unusually small build volumes.
- The session visits all four corners twice, then the centre, with no skipped or repeated
  transition when Next is pressed quickly.
- Every point transition lifts before X/Y and lowers only afterwards.
- Unknown/out-of-range positions are refused with a useful reason.
- Cancel/finish plans lift but do not release motors or silently alter modal state.
- Legacy profile JSON receives safe levelling defaults.

### Mock-printer integration

- Complete the wizard and assert every reported point and final position.
- Inject a resend during a corner move without visiting the point twice.
- Disconnect and reset at each moving/adjusting phase; each must terminate safely.
- Verify no levelling command is sent while a print is active.

### Manual UI and hardware

- Demo: complete, cancel and restart the wizard; inspect all phases at minimum width,
  light mode and dark mode.
- Hardware: perform the guide with the bed cold first, watching every move before testing
  the optional heated-bed path.
- Print a one-layer bed test after levelling. The guide passes only if the first-layer
  lines adhere consistently at all four corners and the centre.

## Definition of done

- `swift test` and the release app build pass.
- The demo wizard passes its UI smoke test.
- No movement/heating logic lives in a SwiftUI view.
- Every new protocol or movement path has a mock-printer test.
- The real printer completes the guide and a one-layer validation print with the user's
  explicit approval.
- README and working notes state exactly what was and was not hardware-tested.

## First-print gate — passed; targeted checks remain

Victor drives the UI and retains control of the power switch. Nozzle/Codex only observes
the UI descriptions and the results Victor reports.

1. Confirm the bed is clear, the printer is attended and the power switch is reachable.
2. Connect in hardware mode and confirm the UI identifies the expected printer/port.
3. Home all; compare the UI position with the machine.
4. Jog X, Y and Z by 10 mm one at a time and confirm the physical direction/distance.
5. Heat the nozzle to 210 °C, then extrude 5 mm; turn the heaters off if anything looks
   or smells wrong.
6. Level the bed manually, load the calibration cube and review all warnings before Print.
7. Watch the first layer continuously. Stop from the UI for poor adhesion, scraping,
   unexpected direction, unusual noise, smoke or a temperature fault; use the physical
   power switch for an actual emergency.
8. A few layers in, Pause. Report the phase text, parked X/Y/Z, whether heaters remain on
   and whether the motors remain engaged.
9. Resume and inspect the wall at the resume point for a blob, seam or missing extrusion.
10. On a later safe run, leave it paused for five minutes before Resume to verify this
    firmware's temperature polling really prevents stepper idle timeout.
11. Confirm the final park, heater targets of zero and released motors after completion or
    a deliberate Stop.

The end-to-end print portion passed on 2026-08-10 with a solid, correctly proportioned
part. Steps that specifically exercise interactive controls, Pause/Resume and Stop remain
open in `HARDWARE-TESTS.md`. Record those observations before changing the related code;
real behavior overrides every assumption in this draft.
