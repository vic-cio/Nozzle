# ADR 0001: Keep printer ownership in the app for local CLI control

Status: accepted

The Nozzle app owns the USB serial connection. `nozzle-cli live` talks to the app over
a user-only Unix domain socket at `~/Library/Application Support/Nozzle/control.sock`.
Requests use versioned newline-delimited JSON and return a complete printer snapshot.

This avoids a second process opening the same serial device, keeps GUI and CLI state in
one `PrinterController`, and reuses the app's homing, bounds, temperature, extrusion,
operation-serialization, and dangerous-command checks. The socket is local, lives in a
0700 directory, and has mode 0600. The CLI fails clearly when the app is not running.

The current design requires the app to be open and is intended for short supervised
operations. A later daemon can become the sole serial owner when unattended printing,
survival across app restarts, or multiple front ends justify the added lifecycle,
installation, upgrade, logging, and recovery machinery. That migration should keep the
typed request/response protocol and move `PrinterController`'s device-owning work behind
the daemon; both the app and CLI would then become clients.
