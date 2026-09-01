import Foundation

/// A real macOS serial port, driven with POSIX `termios` and `poll()`.
///
/// Threading model:
///  - One dedicated reader `Thread` blocks in `poll()` and pushes bytes into `events`.
///    A self-pipe lets `close()` wake that thread immediately instead of waiting for a timeout.
///  - Writes happen on whatever thread calls `write(_:)`, serialised by `writeLock`.
///  - The file descriptor is guarded by `stateLock`.
///
/// `@unchecked Sendable` is deliberate and justified: every mutable field is either
/// behind `stateLock`/`writeLock` or only touched by the reader thread.
public final class PosixSerialTransport: SerialTransport, @unchecked Sendable {

    public let path: String
    public let baudRate: Int
    public var displayPath: String { path }

    public let events: AsyncStream<SerialEvent>
    private let eventSink: AsyncStream<SerialEvent>.Continuation

    private let stateLock = NSLock()
    private let writeLock = NSLock()

    private var fd: Int32 = -1
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var readerThread: Thread?
    private var closing = false

    public var isOpen: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return fd >= 0
    }

    public init(path: String, baudRate: Int) {
        self.path = path
        self.baudRate = baudRate
        // .unbounded: dropping printer output is never acceptable — a lost `ok`
        // would stall the queue, and a lost `Resend:` would desynchronise the job.
        let (stream, continuation) = AsyncStream<SerialEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.eventSink = continuation
    }

    // MARK: - Open

    public func open() throws {
        stateLock.lock()
        guard fd < 0 else { stateLock.unlock(); throw SerialError.alreadyOpen }
        stateLock.unlock()

        // O_NONBLOCK so open() returns immediately even if DCD is low; we use poll() anyway.
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SerialError.cannotOpen(path: path, code: errno)
        }

        do {
            // Ask the kernel for exclusive access so a second copy of Nozzle — or
            // Pronterface — cannot start interleaving commands into the same printer.
            if ioctl(descriptor, TIOCEXCL) == -1 {
                throw SerialError.configurationFailed(step: "exclusive access", code: errno)
            }
            try configure(descriptor)
            try makeWakePipe()
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        stateLock.lock()
        fd = descriptor
        closing = false
        stateLock.unlock()

        // Discard anything the adapter buffered before we showed up (e.g. a partial
        // line from a previous session) so our first parsed line is a whole line.
        tcflush(descriptor, TCIOFLUSH)

        let thread = Thread { [weak self] in self?.readLoop(descriptor) }
        thread.name = "com.nozzle.serial-reader"
        thread.qualityOfService = .userInitiated
        readerThread = thread
        thread.start()

        eventSink.yield(.opened)
    }

    private func configure(_ descriptor: Int32) throws {
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            throw SerialError.configurationFailed(step: "tcgetattr", code: errno)
        }

        // Raw mode: no echo, no line editing, no CR/LF translation. Marlin speaks bytes.
        cfmakeraw(&options)

        options.c_cflag |= tcflag_t(CREAD | CLOCAL)   // receive; ignore modem control lines
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)              // 8 data bits
        options.c_cflag &= ~tcflag_t(PARENB)          // no parity
        options.c_cflag &= ~tcflag_t(CSTOPB)          // 1 stop bit
        options.c_cflag &= ~tcflag_t(CRTSCTS)         // no hardware flow control
        // HUPCL would drop DTR on close, which hard-resets Creality boards. Leaving it
        // off means quitting Nozzle does not reboot a printer mid-anything.
        options.c_cflag &= ~tcflag_t(HUPCL)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)  // no software flow control

        withUnsafeMutableBytes(of: &options.c_cc) { raw in
            raw[Int(VMIN)] = 0   // poll() decides when to read; never block inside read()
            raw[Int(VTIME)] = 0
        }

        let standard = Self.standardSpeed(for: baudRate)
        let speedToSet = standard ?? speed_t(B9600)
        guard cfsetispeed(&options, speedToSet) == 0, cfsetospeed(&options, speedToSet) == 0 else {
            throw SerialError.configurationFailed(step: "cfsetspeed", code: errno)
        }
        guard tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            throw SerialError.configurationFailed(step: "tcsetattr", code: errno)
        }

        if standard == nil {
            // Non-standard rates (250000) are not expressible in termios on macOS and
            // must go through IOSSIOSPEED *after* tcsetattr, which resets the speed.
            var requested = speed_t(baudRate)
            guard ioctl(descriptor, Self.iossiospeed, &requested) != -1 else {
                throw SerialError.configurationFailed(step: "IOSSIOSPEED (\(baudRate) baud)", code: errno)
            }
            // Several macOS USB-serial drivers silently stay at 9600 for rates >= 250000
            // instead of failing. Read the speed back and refuse to pretend it worked.
            var check = termios()
            if tcgetattr(descriptor, &check) == 0 {
                let actual = Int(cfgetospeed(&check))
                // A driver that accepted the rate reports it back verbatim.
                if actual != baudRate && actual != 0 && actual < baudRate / 2 {
                    throw SerialError.baudRateRejected(requested: baudRate, actual: actual)
                }
            }
        }
    }

    /// `_IOW('T', 2, speed_t)` from `<IOKit/serial/ioss.h>`.
    ///
    /// Computed rather than hard-coded, because the constant encodes
    /// `MemoryLayout<speed_t>.size`, and published magic numbers for it disagree.
    private static var iossiospeed: UInt {
        let iocIn: UInt32 = 0x8000_0000
        let paramMask: UInt32 = 0x1fff
        let size = UInt32(MemoryLayout<speed_t>.size) & paramMask
        let group = UInt32(UInt8(ascii: "T"))
        return UInt(iocIn | (size << 16) | (group << 8) | 2)
    }

    private static func standardSpeed(for baud: Int) -> speed_t? {
        switch baud {
        case 9_600:   return speed_t(B9600)
        case 19_200:  return speed_t(B19200)
        case 38_400:  return speed_t(B38400)
        case 57_600:  return speed_t(B57600)
        case 115_200: return speed_t(B115200)
        case 230_400: return speed_t(B230400)
        default:      return nil   // 250000 and friends need IOSSIOSPEED
        }
    }

    private func makeWakePipe() throws {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            throw SerialError.configurationFailed(step: "wake pipe", code: errno)
        }
        wakeRead = fds[0]
        wakeWrite = fds[1]
    }

    // MARK: - Read

    private func readLoop(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var failure: SerialError?

        loop: while true {
            var fds = [
                pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
            ]

            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                failure = .readFailed(code: errno)
                break loop
            }

            // Asked to shut down.
            if fds[1].revents != 0 { break loop }

            let revents = Int32(fds[0].revents)
            if revents & (POLLHUP | POLLERR | POLLNVAL) != 0 {
                failure = .deviceDisconnected
                break loop
            }
            guard revents & POLLIN != 0 else { continue }

            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, raw.count)
            }

            if count > 0 {
                eventSink.yield(.data(Array(buffer[0..<count])))
            } else if count == 0 {
                failure = .deviceDisconnected   // EOF: the device node went away
                break loop
            } else {
                if errno == EINTR || errno == EAGAIN { continue }
                failure = (errno == ENXIO || errno == EIO) ? .deviceDisconnected : .readFailed(code: errno)
                break loop
            }
        }

        // Distinguish "we asked it to stop" from "the printer vanished". Only the
        // latter is an error the user needs to see.
        stateLock.lock()
        let deliberate = closing
        stateLock.unlock()

        teardown(reportedError: deliberate ? nil : failure)
    }

    // MARK: - Write

    public func write(_ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }

        writeLock.lock()
        defer { writeLock.unlock() }

        stateLock.lock()
        let descriptor = fd
        stateLock.unlock()
        guard descriptor >= 0 else { throw SerialError.notOpen }

        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    // The adapter's TX buffer is momentarily full. Back off briefly.
                    usleep(500)
                    continue
                }
                throw (errno == ENXIO || errno == EIO)
                    ? SerialError.deviceDisconnected
                    : SerialError.writeFailed(code: errno)
            }
        }
    }

    // MARK: - Close

    public func close() {
        stateLock.lock()
        guard fd >= 0, !closing else { stateLock.unlock(); return }
        closing = true
        let wake = wakeWrite
        stateLock.unlock()

        // Nudge the self-pipe so the reader leaves poll() now rather than eventually.
        if wake >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wake, &byte, 1)
        }
    }

    /// Runs exactly once, on the reader thread, after the loop exits.
    private func teardown(reportedError: SerialError?) {
        stateLock.lock()
        let descriptor = fd
        let r = wakeRead, w = wakeWrite
        fd = -1
        wakeRead = -1
        wakeWrite = -1
        stateLock.unlock()

        if descriptor >= 0 {
            tcflush(descriptor, TCIOFLUSH)
            Darwin.close(descriptor)
        }
        if r >= 0 { Darwin.close(r) }
        if w >= 0 { Darwin.close(w) }

        eventSink.yield(.closed(reportedError))
        eventSink.finish()
    }

    deinit {
        stateLock.lock()
        let descriptor = fd
        stateLock.unlock()
        if descriptor >= 0 { Darwin.close(descriptor) }
    }
}
