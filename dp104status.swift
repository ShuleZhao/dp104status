// SPDX-License-Identifier: GPL-3.0-only
//
// dp104status — agent activity on a Ticktype DP104 keyboard screen
// Copyright (C) 2026 Shule Zhao
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the
// Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program. If not, see <https://www.gnu.org/licenses/>.
//
// The DP104 protocol was reverse-engineered rather than documented; see
// NOTICE.md for where it came from and what it is derived from.
//
//   dp104status hook <claude|codex>   read one hook event from stdin, record it, exit
//   dp104status daemon                own the keyboard and render the aggregate state
//   dp104status status                print what the daemon would render
//   dp104status restore               put the keyboard back the way the user had it
//   dp104status hooks <claude|codex>  print the hook config to install
//
// Two states per product, as specified: WORK (busy) and DONE (finished).
// PermissionRequest lands in the not-busy bucket as WAIT — an agent blocked on
// approval is stalled, and showing WORK there would tell you to stay away.
//
// Protocol notes live in DP104-PROTOCOL.md. The short version: everything here
// is VIA CUSTOM_MENU_SET_VALUE (0x07), which is RAM-only and takes effect
// immediately. CUSTOM_MENU_SAVE (0x09) is never sent, so nothing wears flash.

import Foundation
import IOKit
import IOKit.hid

// MARK: - Device constants

let VID = 0xe560, PID = 0xe104, USAGE_PAGE = 0xFF60, USAGE = 0x61
let REPORT = 32

let CH_SCREEN: UInt8 = 26          // MATRIX LED channel
let VAL_BRIGHTNESS: UInt8 = 1
let VAL_EFFECT: UInt8 = 2
let VAL_TEXT: UInt8 = 5
let TEXT_SLOTS = 5

let screenModes: [String: UInt8] = ["off": 0, "type": 1, "custom": 2, "info": 3,
                                    "spark": 4, "audio": 5, "scroll": 6]
let MODE_SCROLL: UInt8 = 6         // text display
let MODE_CUSTOM: UInt8 = 2         // pixel display
let MODE_INFO: UInt8 = 3           // default resting mode
let TEXT_LEN = 30                  // "EVO 104".matrixLighting.texts.length

// The pixel screen. Frame data goes over USB CDC, not raw HID — the firmware
// answers 0xff to the HID block-transfer commands. Uploading a frame takes
// effect immediately; a mode round-trip must NOT be done afterwards, because
// re-entering CUSTOM reloads the frame the keyboard has stored and throws the
// freshly uploaded one away.
let SCREEN_ROWS = 8, SCREEN_COLS = 24
let SERIAL_BUF = 64
let SERIAL_CHUNK = SERIAL_BUF - 8  // [cmd, offset(4), len] + payload
let CMD_FRAME_HEADER: UInt8 = 0xC0
let CMD_FRAME_DATA: UInt8 = 0xC1

let WORK_TTL: TimeInterval = 3600  // a stuck "working" owner is reaped after an hour
let DONE_TTL: TimeInterval = 30    // how long DONE stays on screen before going idle
let POLL_INTERVAL: TimeInterval = 0.4
let MODE_CHECK_INTERVAL: TimeInterval = 3.0   // how often to look at the mode — the user may have changed it
let HID_REPLY_TIMEOUT: TimeInterval = 0.5     // how long one HID request waits for its reply
let SLEEP_BACKOFF_MIN: TimeInterval = 2       // probing a keyboard that stopped answering:
let SLEEP_BACKOFF_MAX: TimeInterval = 5       //   so a redraw follows within seconds of it waking
let CDC_RETRY_MIN: TimeInterval = 15          // retrying a pixel link that stopped answering:
let CDC_RETRY_MAX: TimeInterval = 300         //   doubling, so a dead link is not hammered
let IDLE_KEY = "(idle)"                       // cache key for the dim dashboard frame
let EVENT_LOG_MAX_BYTES = 256 * 1024         // events.log is a debugging aid, not an archive

// MARK: - Paths

let home = FileManager.default.homeDirectoryForCurrentUser
/// DP104STATUS_HOME points everything — state, config, logs, locks — somewhere
/// else, e.g. to drive a test daemon without the live hooks writing into it.
let stateDir = ProcessInfo.processInfo.environment["DP104STATUS_HOME"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? home.appendingPathComponent(".dp104status")
let stateURL = stateDir.appendingPathComponent("state.json")
let stateLockURL = stateDir.appendingPathComponent("state.lock")
let takeoverURL = stateDir.appendingPathComponent("takeover.json")
let configURL = stateDir.appendingPathComponent("config.json")
let serialLockURL = stateDir.appendingPathComponent("serial.lock")

func ensureStateDir() throws {
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
}

// MARK: - Config

enum Display: String, Codable {
    case mixed     // icons while the pixel link answers, scrolling text while it doesn't
    case pixel     // icons only — with the pixel link down, the screen is left alone
    case text      // scrolling text only: raw HID alone, the most robust
}

/// What the screen does is otherwise decided by the user's own screen mode, not
/// by settings here — see Renderer.
struct Config: Codable {
    var display: Display = .mixed

    /// Loopback port for remote sessions to report on, or nil to listen for
    /// none. Off by default: opening a socket should be something you asked for.
    var remotePort: UInt16? = nil

    private enum CodingKeys: String, CodingKey { case display, remotePort }

    init() {}

    /// Lenient: a missing or unrecognised key keeps its default rather than
    /// discarding the whole file. Older configs carry keys this version dropped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = (try? c.decodeIfPresent(Display.self, forKey: .display)) ?? .mixed
        remotePort = (try? c.decodeIfPresent(UInt16.self, forKey: .remotePort)) ?? nil
    }

    static func load() -> Config {
        (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
            ?? Config()
    }

    func save() throws {
        try ensureStateDir()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: configURL)
    }
}

// MARK: - Model

enum Activity: String, Codable {
    case working, waiting, done

    var label: String {           // 4 chars keeps any combination inside 30
        switch self {
        case .working: return "WORK"
        case .waiting: return "WAIT"
        case .done:    return "DONE"
        }
    }

    var rank: Int {               // waiting outranks working: it needs you *now*
        switch self {
        case .waiting: return 3
        case .working: return 2
        case .done:    return 1
        }
    }
}

struct Owner: Codable {
    var product: String
    var activity: Activity
    var updatedAt: Double
    var expiresAt: Double?

    func alive(_ now: Double) -> Bool { expiresAt.map { $0 > now } ?? true }
}

struct State: Codable {
    var owners: [String: Owner] = [:]

    /// Highest-ranked live activity per product; absent product == idle.
    func aggregate(_ now: Double = Date().timeIntervalSince1970) -> [String: Activity] {
        var out: [String: Activity] = [:]
        for owner in owners.values where owner.alive(now) {
            if let cur = out[owner.product], cur.rank >= owner.activity.rank { continue }
            out[owner.product] = owner.activity
        }
        return out
    }
}

let products: Set<String> = ["claude", "codex"]
let productNames = ["claude": "CLAUDE", "codex": "CODEX"]
let productOrder = ["claude", "codex"]

/// e.g. "CLAUDE WORK  CODEX WAIT" — empty when everything is idle.
func render(_ agg: [String: Activity]) -> String {
    let parts = productOrder.compactMap { key -> String? in
        guard let a = agg[key] else { return nil }
        return "\(productNames[key] ?? key.uppercased()) \(a.label)"
    }
    return String(parts.joined(separator: "  ").prefix(TEXT_LEN))
}

// MARK: - Durable state (short exclusive lock, atomic replace)

func withState<T>(_ body: (inout State) throws -> T) throws -> T {
    try ensureStateDir()
    // Lock a stable inode, not state.json itself. state.json is atomically
    // replaced after every update, so a flock held on that file would protect
    // only the old inode and concurrent Claude/Codex hooks could lose updates.
    let fd = open(stateLockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
    guard fd >= 0 else { throw NSError(domain: "dp104", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "cannot open state"]) }
    guard flock(fd, LOCK_EX) == 0 else {
        close(fd)
        throw NSError(domain: "dp104", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "cannot lock state"])
    }
    defer { flock(fd, LOCK_UN); close(fd) }

    var state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    let result = try body(&state)

    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let data = try enc.encode(state)
    let tmp = stateURL.appendingPathExtension("tmp")
    try data.write(to: tmp)
    _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: tmp)
    return result
}

func loadState() -> State {
    (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
}

// MARK: - Hook events

struct HookEvent: Decodable {
    let hook_event_name: String?
    let session_id: String?
    let agent_id: String?
}

/// What one lifecycle event does to the owner set. Only structured event names
/// are consulted — never prompt text, tool output or transcripts.
func apply(event name: String, product: String, session: String, agent: String,
           to state: inout State, now: Double) {
    let key = "\(product):\(session):\(agent)"
    let sessionPrefix = "\(product):\(session):"

    func set(_ a: Activity, ttl: TimeInterval) {
        state.owners[key] = Owner(product: product, activity: a,
                                  updatedAt: now, expiresAt: now + ttl)
    }

    switch name {
    case "SessionStart", "SessionEnd":
        state.owners = state.owners.filter { !$0.key.hasPrefix(sessionPrefix) }

    case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart":
        set(.working, ttl: WORK_TTL)

    case "PermissionRequest", "Elicitation":
        set(.waiting, ttl: WORK_TTL)

    case "SubagentStop":
        state.owners.removeValue(forKey: key)

    case "Stop":
        // The turn is over: drop this session's subagents, mark the main owner done.
        state.owners = state.owners.filter { !$0.key.hasPrefix(sessionPrefix) }
        state.owners["\(product):\(session):main"] =
            Owner(product: product, activity: .done, updatedAt: now, expiresAt: now + DONE_TTL)

    default:
        break
    }
}

/// Append one line per event so the real order of a product's lifecycle can be
/// read back later. Only the structured identifiers are recorded — never prompt
/// text, tool output or transcripts — and the file is truncated when it grows
/// past the cap, so it cannot fill the disk.
func logEvent(_ product: String, _ name: String, _ session: String, _ agent: String) {
    let line = "\(stamp())  \(product)  \(name)  session=\(session.prefix(8)) agent=\(agent)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = stateDir.appendingPathComponent("events.log")
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
       size > EVENT_LOG_MAX_BYTES {
        try? FileManager.default.removeItem(at: url)
    }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url)
    }
}

/// Record one event, wherever it came from: a local hook process or a remote
/// session reporting over the loopback listener. Returns the event name so the
/// caller can log it; nil when the payload is not a usable event.
@discardableResult
func ingest(product: String, payload: Data) -> String? {
    guard products.contains(product),
          let event = try? JSONDecoder().decode(HookEvent.self, from: payload),
          let name = event.hook_event_name, !name.isEmpty else { return nil }
    let session = event.session_id.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
    let agent = event.agent_id.flatMap { $0.isEmpty ? nil : $0 } ?? "main"
    logEvent(product, name, session, agent)
    let now = Date().timeIntervalSince1970
    _ = try? withState { st in
        apply(event: name, product: product, session: session, agent: agent, to: &st, now: now)
        st.owners = st.owners.filter { $0.value.alive(now) }   // reap on the way past
    }
    return name
}

func runHook(product: String) {
    ingest(product: product, payload: FileHandle.standardInput.readDataToEndOfFile())
    exit(0)   // hooks must never block or fail the agent
}

// MARK: - HID transport

/// The keyboard's raw-HID interface, followed for as long as the process lives.
///
/// Whether the keyboard is physically there comes from IOKit's matching and
/// removal callbacks — never from a failed write. Writes fail whenever the
/// keyboard is asleep (its own idle timer: five minutes by default), and taking
/// that for an unplug is what used to drive the daemon round a reconnect loop
/// every six seconds, re-entering CUSTOM on each lap and exposing whatever frame
/// the firmware had stored.
///
/// IOKit's callbacks run on a private queue. The caller waits for a reply on a
/// semaphore instead of spinning the main run loop, so the poll timer and the
/// signal handler can never run re-entrantly in the middle of an exchange.
final class HIDLink {
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "dp104.hid")
    private let lock = NSLock()
    private let replied = DispatchSemaphore(value: 0)
    private let cancelled = DispatchSemaphore(value: 0)

    private var _device: IOHIDDevice?
    private var _generation = 0
    private var awaiting: [UInt8]?
    private var reply: [UInt8]?

    var device: IOHIDDevice? { lock.lock(); defer { lock.unlock() }; return _device }

    /// Bumped on every attach and detach. The callbacks only record the change;
    /// the renderer notices it on its next tick instead of being called back in
    /// the middle of its own work.
    var generation: Int { lock.lock(); defer { lock.unlock() }; return _generation }

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID,
            kIOHIDPrimaryUsagePageKey: USAGE_PAGE, kIOHIDPrimaryUsageKey: USAGE,
        ] as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue().detach(dev)
        }, me)
        // Registered on the manager, before activation: with a dispatch queue,
        // IOKit traps if a callback is registered on a device after activation.
        IOHIDManagerRegisterInputReportCallback(manager, { ctx, _, _, _, _, report, len in
            Unmanaged<HIDLink>.fromOpaque(ctx!).takeUnretainedValue()
                .received(Array(UnsafeBufferPointer(start: report, count: min(len, 64))))
        }, me)
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerSetCancelHandler(manager) { [cancelled] in cancelled.signal() }
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerActivate(manager)
        // Look the keyboard up synchronously as well, so one-shot commands work
        // without waiting for the matching callback to arrive.
        if let found = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.first { attach(found) }
    }

    /// A manager running on a dispatch queue may only be released once it has been
    /// cancelled and its cancel handler has run; releasing it any sooner aborts.
    deinit {
        IOHIDManagerCancel(manager)
        cancelled.wait()
    }

    private func attach(_ dev: IOHIDDevice) {
        lock.lock()
        if let current = _device, CFEqual(current, dev) { lock.unlock(); return }  // matching repeats the lookup
        _device = dev
        _generation += 1
        lock.unlock()
    }

    private func detach(_ dev: IOHIDDevice) {
        lock.lock(); defer { lock.unlock() }
        guard let current = _device, CFEqual(current, dev) else { return }
        _device = nil
        _generation += 1
    }

    /// A reply only counts if it echoes the command and its first two arguments.
    /// Anything else — a late answer to a request that already timed out, or an
    /// unsolicited report — is dropped rather than mistaken for this one's.
    private func received(_ report: [UInt8]) {
        lock.lock()
        guard let want = awaiting, report.starts(with: want) else { lock.unlock(); return }
        reply = report
        awaiting = nil
        lock.unlock()
        replied.signal()
    }

    /// One request and its reply, or nil if the keyboard did not answer — asleep,
    /// busy, or gone. A nil here is not evidence of an unplug.
    func exchange(_ cmd: UInt8, _ args: [UInt8]) -> [UInt8]? {
        guard let dev = device else { return nil }
        var p = [UInt8](repeating: 0, count: REPORT)
        p[0] = cmd
        for (i, a) in args.enumerated() where i + 1 < REPORT { p[i + 1] = a }

        while replied.wait(timeout: .now()) == .success {}   // drop a signal left by a late reply
        lock.lock(); awaiting = Array(p[0..<min(3, 1 + args.count)]); reply = nil; lock.unlock()

        let sent = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, p, p.count) == kIOReturnSuccess
        let answered = sent && replied.wait(timeout: .now() + HID_REPLY_TIMEOUT) == .success

        lock.lock(); defer { awaiting = nil; reply = nil; lock.unlock() }
        return answered ? reply : nil
    }

    // VIA custom-menu access. Everything here is CUSTOM_MENU_SET_VALUE (0x07):
    // RAM only, effective immediately, lost on a power cycle. 0x09 (save) is
    // never sent, so nothing written here outlives an unplug.

    func get(_ channel: UInt8, _ value: UInt8, _ extra: [UInt8] = []) -> [UInt8]? {
        exchange(0x08, [channel, value] + extra)
    }

    func set(_ channel: UInt8, _ value: UInt8, _ payload: [UInt8]) -> Bool {
        exchange(0x07, [channel, value] + payload) != nil
    }

    func screenMode() -> UInt8? { get(CH_SCREEN, VAL_EFFECT).flatMap { $0.count > 3 ? $0[3] : nil } }
    func setScreenMode(_ m: UInt8) -> Bool { set(CH_SCREEN, VAL_EFFECT, [m]) }

    func readText(slot: Int) -> String? {
        var out = ""
        var offset = 0
        while offset < TEXT_LEN {
            let n = min(TEXT_LEN - offset, 26)
            guard let r = get(CH_SCREEN, VAL_TEXT, [UInt8(slot), UInt8(offset), UInt8(n)]),
                  r.count >= 6 + n else { return nil }
            out += String(bytes: r[6..<(6 + n)].filter { $0 != 0 }, encoding: .ascii) ?? ""
            offset += n
        }
        return out
    }

    func readTexts() -> [String]? {
        var texts: [String] = []
        for slot in 0..<TEXT_SLOTS {
            guard let t = readText(slot: slot) else { return nil }
            texts.append(t)
        }
        return texts
    }

    /// Always writes the full 30 bytes so a shorter string cannot leave a tail behind.
    func writeText(slot: Int, _ text: String) -> Bool {
        var bytes = Array(text.uppercased().unicodeScalars.compactMap { $0.isASCII ? UInt8($0.value) : 0x20 })
        bytes = Array(bytes.prefix(TEXT_LEN))
        bytes += [UInt8](repeating: 0, count: TEXT_LEN - bytes.count)
        var offset = 0
        while offset < TEXT_LEN {
            let n = min(TEXT_LEN - offset, 26)
            guard set(CH_SCREEN, VAL_TEXT, [UInt8(slot), UInt8(offset), UInt8(n)] + Array(bytes[offset..<(offset + n)]))
            else { return false }
            offset += n
        }
        return true
    }

    func writeTexts(_ texts: [String]) -> Bool {
        for (slot, t) in texts.enumerated() where slot < TEXT_SLOTS {
            guard writeText(slot: slot, t) else { return false }
        }
        return true
    }
}

// MARK: - CDC serial transport (pixel frames)

/// Locate the keyboard's USB CDC node by walking up from each serial device to
/// its USB parent. The /dev name encodes the USB topology, so it changes when
/// the keyboard moves to another port — never hard-code it.
func findSerialPath() -> String? {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOServiceMatching("IOSerialBSDClient"),
                                       &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }
    let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
    while case let svc = IOIteratorNext(iter), svc != 0 {
        defer { IOObjectRelease(svc) }
        let vid = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "idVendor" as CFString,
                                                  kCFAllocatorDefault, opts) as? Int
        let pid = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, "idProduct" as CFString,
                                                  kCFAllocatorDefault, opts) as? Int
        guard vid == VID, pid == PID else { continue }
        if let path = IORegistryEntryCreateCFProperty(svc, "IOCalloutDevice" as CFString,
                                                      kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String { return path }
    }
    return nil
}

final class SerialPort {
    private let fd: Int32
    private let lockFd: Int32
    let path: String

    /// macOS lets several processes hold the same /dev/cu.* at once, and they
    /// then steal each other's replies — a documented hazard for this kind of
    /// request/response protocol. Every time this keyboard's CDC endpoint has
    /// died, a second process had the port open moments earlier; none of the
    /// single-process stress tests ever killed it. That is a correlation rather
    /// than a proven cause, but one writer is correct regardless, so the port is
    /// guarded by an advisory lock and a second opener is refused outright.
    init?(path: String) {
        lockFd = open(serialLockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard lockFd >= 0, flock(lockFd, LOCK_EX | LOCK_NB) == 0 else {
            if lockFd >= 0 { close(lockFd) }
            return nil
        }
        let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { flock(lockFd, LOCK_UN); close(lockFd); return nil }
        self.fd = f
        self.path = path

        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CS8) | tcflag_t(CREAD) | tcflag_t(CLOCAL)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 10         // 1.0s read timeout
        }
        guard tcsetattr(fd, TCSANOW, &t) == 0 else {
            close(f); flock(lockFd, LOCK_UN); close(lockFd); return nil
        }
        _ = fcntl(fd, F_SETFL, 0)       // back to blocking reads
        tcflush(fd, TCIOFLUSH)
    }

    deinit { close(fd); flock(lockFd, LOCK_UN); close(lockFd) }

    /// One fixed-size 64-byte packet: [cmd, args..., zero padding].
    @discardableResult
    func packet(_ cmd: UInt8, _ args: [UInt8], wantResponse: Bool = true) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: SERIAL_BUF)
        buf[0] = cmd
        for (i, a) in args.enumerated() where i + 1 < SERIAL_BUF { buf[i + 1] = a }
        guard write(fd, buf, buf.count) == buf.count else { return nil }
        guard wantResponse else { return [] }

        var got = [UInt8]()
        while got.count < SERIAL_BUF {
            var chunk = [UInt8](repeating: 0, count: SERIAL_BUF - got.count)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            got += chunk[0..<n]
        }
        return got.count == SERIAL_BUF ? got : nil
    }

    /// Does the link answer at all? Run before committing the screen to CUSTOM.
    ///
    /// A lone frame header is the probe: it is answered reliably, and a transfer
    /// cut short after it recovers on the next upload's header — which always
    /// follows straight after. The firmware query VIA uses (0xEF) gets no reply
    /// from this keyboard even with the link healthy, and 0xF0 belongs to the
    /// firmware-update sequence: not something to probe with.
    func ping() -> Bool {
        guard let r = packet(CMD_FRAME_HEADER, [1, 10, UInt8(SCREEN_ROWS), UInt8(SCREEN_COLS)]) else { return false }
        return r.count > 6 && r[5] != 0xEE
    }

    /// Upload one frame. Deliberately does not touch the screen mode: the frame
    /// renders as soon as the last chunk lands.
    func sendFrame(_ payload: [UInt8], rows: Int, cols: Int, fps: UInt8 = 10) -> Bool {
        guard let header = packet(CMD_FRAME_HEADER, [1, fps, UInt8(rows), UInt8(cols)]),
              header.count > 6, header[5] != 0xEE else { return false }
        let acked = header[6] != 0
        var offset = 0
        while offset < payload.count {
            let n = min(SERIAL_CHUNK, payload.count - offset)
            let be = [UInt8((offset >> 24) & 255), UInt8((offset >> 16) & 255),
                      UInt8((offset >> 8) & 255), UInt8(offset & 255)]
            let args = be + [UInt8(n)] + Array(payload[offset..<(offset + n)])
            if packet(CMD_FRAME_DATA, args, wantResponse: acked) == nil { return false }
            offset += n
        }
        return true
    }
}

// MARK: - Pixel rendering

/// 7x7 brand marks, one per product, drawn in the state colour:
/// the Anthropic burst and the OpenAI ring.
let glyphs: [String: [String]] = [
    "claude": ["#..#..#",
               ".#.#.#.",
               "..###..",
               "#######",
               "..###..",
               ".#.#.#.",
               "#..#..#"],
    "codex":  ["..###..",
               ".#...#.",
               "#.....#",
               "#..#..#",
               "#.....#",
               ".#...#.",
               "..###.."],
]

/// RGB per state. An idle half is drawn dim rather than black so the layout
/// stays readable — you can always see which side is which, and a state change
/// reads as a colour change instead of something appearing out of nowhere.
func color(for activity: Activity?) -> (Double, Double, Double) {
    switch activity {
    case .working: return (0, 0, 255)
    case .waiting: return (255, 132, 0)
    case .done:    return (0, 255, 0)
    case nil:      return (36, 36, 36)
    }
}

/// get256HSV — the device wants hue/sat/val, each 0-255, not RGB.
func hsv256(_ r: Double, _ g: Double, _ b: Double) -> [UInt8] {
    let rr = r / 255, gg = g / 255, bb = b / 255
    let mx = max(rr, gg, bb), mn = min(rr, gg, bb), c = mx - mn
    var h = 0.0
    if c != 0 {
        if mx == rr { h = 60 * (((gg - bb) / c).truncatingRemainder(dividingBy: 6)) }
        else if mx == gg { h = 60 * ((bb - rr) / c + 2) }
        else { h = 60 * ((rr - gg) / c + 4) }
    }
    if h < 0 { h += 360 }
    let s = mx == 0 ? 0 : c / mx
    return [UInt8((255 * h / 360).rounded()), UInt8((255 * s).rounded()), UInt8((255 * mx).rounded())]
}

/// Frame-major, row-major, column order; 3 bytes per pixel.
func buildFrame(_ agg: [String: Activity]) -> [UInt8] {
    let half = SCREEN_COLS / 2                       // 12 columns per product
    var pixels = [[UInt8]](repeating: [0, 0, 0], count: SCREEN_ROWS * SCREEN_COLS)

    for (index, product) in productOrder.enumerated() {
        guard let glyph = glyphs[product] else { continue }
        let px = hsv256(color(for: agg[product]).0,
                        color(for: agg[product]).1,
                        color(for: agg[product]).2)
        let glyphW = glyph[0].count
        let originCol = index * half + (half - glyphW) / 2
        let originRow = (SCREEN_ROWS - glyph.count) / 2
        for (r, line) in glyph.enumerated() {
            for (c, ch) in line.enumerated() where ch == "#" {
                let row = originRow + r, col = originCol + c
                guard row < SCREEN_ROWS, col < SCREEN_COLS else { continue }
                pixels[row * SCREEN_COLS + col] = px
            }
        }
    }
    return pixels.flatMap { $0 }
}

// MARK: - Takeover (what to hand back)

/// What the screen was doing when it was borrowed, so it can be handed back
/// exactly as it was.
///
/// Taken at the moment of borrowing, not at daemon startup: a snapshot from
/// startup goes stale the moment the user changes a text or a mode, and
/// restoring it would quietly overwrite their newer choice. Kept on disk while
/// held, so a daemon that dies mid-borrow is followed by one that puts the
/// screen back before doing anything else.
struct Takeover: Codable {
    /// The user's own screen mode — what the screen returns to.
    var userMode: UInt8
    /// The user's text slots, present only once ours have been written over them.
    var userTexts: [String]?

    func save() {
        try? ensureStateDir()
        try? JSONEncoder().encode(self).write(to: takeoverURL)
    }

    static func load() -> Takeover? {
        (try? Data(contentsOf: takeoverURL)).flatMap { try? JSONDecoder().decode(Takeover.self, from: $0) }
    }

    static func clear() { try? FileManager.default.removeItem(at: takeoverURL) }
}

/// Put a borrowed screen back. Returns false if the keyboard did not answer,
/// in which case nothing is assumed restored and the caller tries again later.
///
/// The mode is written only if it differs: re-entering CUSTOM makes the
/// firmware reload the frame it has stored, so even a same-value write is not
/// free.
func handBack(_ t: Takeover, via link: HIDLink) -> Bool {
    if let texts = t.userTexts, !link.writeTexts(texts) { return false }
    guard let now = link.screenMode() else { return false }
    if now != t.userMode, !link.setScreenMode(t.userMode) { return false }
    return true
}

// MARK: - Daemon

func stamp() -> String { Date().formatted(date: .omitted, time: .standard) }

// MARK: - Remote sessions

/// Hooks run wherever the agent runs. A Claude Code or Codex session opened
/// over SSH therefore executes its hooks on the remote host, which has neither
/// this binary nor the keyboard, so those sessions are invisible to a purely
/// local daemon. This listener accepts the same events over a socket so a
/// remote session can report in through an SSH reverse tunnel.
///
/// It binds the loopback address only — never a routable one — so nothing can
/// reach it except processes on this Mac and whatever `ssh -R` forwards into
/// it. Payloads are length-capped and drive nothing but the aggregate state.
final class RemoteListener {
    private let fd: Int32
    private let queue = DispatchQueue(label: "dp104.remote")
    private var source: DispatchSourceRead?

    static let maxPayload = 8 * 1024

    init?(port: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian    // 127.0.0.1, nothing else
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return nil }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // Don't let a stalled peer hold the accept loop.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while buf.count < Self.maxPayload {
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buf += chunk[0..<n]
            if buf.contains(0x0a) { break }                 // one line per connection
        }
        guard let newline = buf.firstIndex(of: 0x0a) ?? (buf.isEmpty ? nil : buf.count) else { return }
        let line = Array(buf[0..<newline])

        // "<product>\t<event json>"
        guard let tab = line.firstIndex(of: 0x09) else { return }
        let product = String(decoding: line[0..<tab], as: UTF8.self)
        let json = Data(line[(tab + 1)...])
        if let name = ingest(product: product, payload: json) {
            print("[\(stamp())] remote \(product) \(name)")
        }
    }
}

/// Drives the screen on the user's behalf, for the daemon's lifetime.
///
/// The user's own screen mode decides how, so no setting of theirs is ever
/// changed behind their back:
///
/// - Screen on CUSTOM: that is the status display. It is drawn into in place —
///   status while agents run, a dim dashboard while they don't — and the mode
///   is never touched, not even when the pixel link is down and nothing can be
///   drawn. (With display text, CUSTOM is borrowed like any other mode.)
/// - Screen on anything else: it is borrowed only while an agent is active,
///   and handed back — mode and texts exactly as they were — once all are idle.
/// - The user switching the mode while it is borrowed is them taking it back.
///   It is released at once and not borrowed again until the agents next go
///   idle. (Switching *to* CUSTOM asks for the status display instead.)
///
/// The keyboard sleeps after five idle minutes and stops answering until a key
/// wakes it. That is expected, not an unplug: the renderer backs off without
/// touching anything, and redraws once it answers again.
final class Renderer {
    private enum Surface { case pixel, text }

    private let link: HIDLink
    private let config = Config.load()

    // Presence and sleep
    private var seenGeneration: Int?
    private var asleep = false
    private var sleepBackoff = SLEEP_BACKOFF_MIN
    private var nextWakeProbe = Date.distantPast

    // The pixel (CDC) link
    private var serial: SerialPort?
    private var cdcUp = false
    private var cdcBackoff = CDC_RETRY_MIN
    private var nextCdcTry = Date.distantPast

    // Ownership of the screen
    private var surface: Surface?            // nil: the screen is the user's
    private var userMode: UInt8 = MODE_INFO  // while held: the mode it goes back to
    private var userTexts: [String]?         // while held: their slots, once ours are written over them
    private var onScreen: UInt8?             // the mode the screen was last seen or left in
    private var drawn: String?               // what our surface shows, to skip redundant writes
    private var dismissed = false            // taken back by the user; wait for the agents to go idle
    private var lastCheck = Date.distantPast
    private var lastNote: String?
    private var recovered = false

    private var holding: Bool { surface != nil }
    private var resident: Bool { holding && userMode == MODE_CUSTOM }

    init(link: HIDLink) { self.link = link }

    func update(_ agg: [String: Activity]) {
        trackPresence()
        guard link.device != nil, awake() else { return }

        if !recovered {
            // A takeover on disk now means the previous daemon died holding the
            // screen. Give it back before doing anything else.
            if let stale = Takeover.load() {
                guard handBack(stale, via: link) else { return fellAsleep() }
                Takeover.clear()
                log("handed back a screen left borrowed by a previous run")
            }
            recovered = true
        }

        let active = !agg.isEmpty
        if !active { dismissed = false }

        if Date().timeIntervalSince(lastCheck) >= MODE_CHECK_INTERVAL {
            lastCheck = Date()
            guard let mode = link.screenMode() else { return fellAsleep() }
            if holding, let expected = onScreen, mode != expected {
                return userSwitched(to: mode, active: active)
            }
            onScreen = mode
            if !holding, mode == MODE_CUSTOM, config.display != .text {
                // The user's own mode is CUSTOM: that is the status display. This is
                // also how a fresh start, or a switch to CUSTOM, picks it up — and
                // switching there is asking for it, so it undoes a dismissal.
                surface = .pixel; userMode = MODE_CUSTOM; userTexts = nil; drawn = nil
                dismissed = false
                persist()
            }
        }

        if !active { return goIdle() }
        if dismissed { return }
        if holding { refresh(agg) } else { borrow(agg) }
    }

    /// SIGTERM: give back anything borrowed. A resident screen keeps its last frame.
    func shutdown() {
        guard holding, userMode != MODE_CUSTOM || userTexts != nil else { return }
        if handBack(Takeover(userMode: userMode, userTexts: userTexts), via: link) {
            Takeover.clear()
            log("screen handed back (\(modeName(userMode)))")
        }   // otherwise it stays on disk for the next run to hand back
    }

    // MARK: Transitions

    private func borrow(_ agg: [String: Activity]) {
        guard let mode = link.screenMode() else { return fellAsleep() }
        onScreen = mode
        userMode = mode; userTexts = nil; drawn = nil

        if config.display != .text, mode == MODE_CUSTOM {
            // Already on CUSTOM: that is the status display. Draw into it if the
            // pixel link allows, and otherwise leave it be — never switch away from
            // the user's own CUSTOM, not even to fall back to text.
            surface = .pixel; dismissed = false
            persist()
            _ = drawPixel(agg)
            return
        }
        if config.display != .text, pixelLinkAnswers() {
            surface = .pixel
            persist()                                    // on disk before the screen is touched
            guard setMode(MODE_CUSTOM) else { return fellAsleep() }
            if drawPixel(agg) { return }
            // The link died between the check and the frame. Never leave the
            // screen on CUSTOM showing the firmware's stored frame.
            guard setMode(mode) else { return fellAsleep() }
            surface = nil
            persist()
        }
        guard config.display != .pixel else {
            return note("pixel link down and display is pixel-only — leaving the screen alone")
        }
        guard let texts = link.readTexts() else { return fellAsleep() }
        surface = .text; userTexts = texts
        persist()
        guard enterText(agg) else { return fellAsleep() }
    }

    private func refresh(_ agg: [String: Activity]) {
        if surface == .text {
            guard config.display == .mixed, pixelLinkAnswers() else { return drawText(agg) }
            // Mixed and the pixel link answers again: their texts back, then CUSTOM.
            if let texts = userTexts { guard link.writeTexts(texts) else { return fellAsleep() } }
            userTexts = nil; surface = .pixel; drawn = nil
            persist()
            guard setMode(MODE_CUSTOM) else { return fellAsleep() }
        }
        if drawPixel(agg) { return }
        // Resident on the user's own CUSTOM: nothing better to show, and switching
        // away — even to text — would hijack the mode key's cycle (CUSTOM pressed,
        // SCROLL shown, the next press lands on OFF and INFO is never reached).
        guard !resident else { return }

        switch config.display {
        case .mixed:
            log("pixel link down — showing text until it answers again")
            guard let texts = link.readTexts() else { return fellAsleep() }
            surface = .text; userTexts = texts
            persist()
            guard enterText(agg) else { return fellAsleep() }
        case .pixel:
            release()      // don't leave the stored frame up; borrowed again once the link answers
        case .text:
            break          // unreachable: text display never draws pixels
        }
    }

    private func goIdle() {
        guard holding else { return }
        guard resident else { return release() }
        _ = drawPixel([:])      // the dim dashboard; retried on the link's schedule if it is down
    }

    private func release() {
        guard handBack(Takeover(userMode: userMode, userTexts: userTexts), via: link) else {
            return fellAsleep()      // stays held; tried again once the keyboard answers
        }
        log("idle — screen handed back (\(modeName(userMode)))")
        surface = nil; userTexts = nil; onScreen = userMode; drawn = nil
        persist()
    }

    private func userSwitched(to mode: UInt8, active: Bool) {
        if let texts = userTexts, !link.writeTexts(texts) { return fellAsleep() }
        log("you switched the screen to \(modeName(mode)) — leaving it to you")
        surface = nil; userTexts = nil; onScreen = mode; drawn = nil
        persist()
        // Switching *to* CUSTOM asks for the status display; anything else is a dismissal.
        dismissed = active && !(mode == MODE_CUSTOM && config.display != .text)
    }

    // MARK: Drawing

    private func drawPixel(_ agg: [String: Activity]) -> Bool {
        let text = render(agg)
        let key = "pixel:" + (text.isEmpty ? IDLE_KEY : text)
        if drawn == key { return true }
        guard let port = pixelLink() else { return false }
        guard port.sendFrame(buildFrame(agg), rows: SCREEN_ROWS, cols: SCREEN_COLS) else {
            cdcFailed(); return false
        }
        linkUp()
        drawn = key
        log(text.isEmpty ? "idle — dashboard" : text)
        return true
    }

    /// Our status line in slot 0 and the other slots blank, so only it scrolls.
    private func enterText(_ agg: [String: Activity]) -> Bool {
        for slot in 1..<TEXT_SLOTS { guard link.writeText(slot: slot, "") else { return false } }
        drawn = nil
        guard setMode(MODE_SCROLL) else { return false }
        drawText(agg)
        return drawn != nil
    }

    private func drawText(_ agg: [String: Activity]) {
        let text = render(agg)
        guard drawn != "text:" + text else { return }
        guard link.writeText(slot: 0, text) else { return fellAsleep() }
        drawn = "text:" + text
        log("\(text) (text)")
    }

    /// Change the screen mode, skipping the write when it is already there:
    /// re-entering CUSTOM makes the firmware reload its stored frame, so even a
    /// same-value write is not free.
    private func setMode(_ m: UInt8) -> Bool {
        if onScreen == m { return true }
        guard link.setScreenMode(m) else { return false }
        onScreen = m
        return true
    }

    private func persist() {
        if holding, userMode != MODE_CUSTOM || userTexts != nil {
            Takeover(userMode: userMode, userTexts: userTexts).save()
        } else {
            Takeover.clear()
        }
    }

    // MARK: The pixel link

    /// The pixel link, if it is open and not sitting out a retry backoff. No I/O.
    /// It is opened once per connection, and when it stops answering it is left
    /// alone on a growing backoff — hammering a dead link every few seconds is
    /// part of how it used to stay dead.
    private func pixelLink() -> SerialPort? {
        if let serial, cdcUp { return serial }
        guard Date() >= nextCdcTry else { return nil }
        // A fresh descriptor for every retry: one opened while the keyboard was
        // still coming up after a re-enumeration can stay unusable for good. On
        // the backoff schedule this is gentle — nothing like the old six-second loop.
        serial = nil
        guard let path = findSerialPath(), let port = SerialPort(path: path) else { cdcFailed(); return nil }
        serial = port
        return port
    }

    /// Before switching the screen to CUSTOM: does the link answer? Switching
    /// first and finding out after would show the firmware's stored frame.
    private func pixelLinkAnswers() -> Bool {
        guard let port = pixelLink() else { return false }
        guard port.ping() else { cdcFailed(); return false }
        linkUp()
        return true
    }

    private func linkUp() {
        if !cdcUp { log("pixel link up") }
        cdcUp = true
        cdcBackoff = CDC_RETRY_MIN
    }

    private func cdcFailed() {
        log("pixel link not answering — next try in \(Int(cdcBackoff))s")
        cdcUp = false
        nextCdcTry = Date().addingTimeInterval(cdcBackoff)
        cdcBackoff = min(cdcBackoff * 2, CDC_RETRY_MAX)
    }

    // MARK: Presence and sleep

    private func trackPresence() {
        let gen = link.generation
        guard gen != seenGeneration else { return }
        let first = seenGeneration == nil
        seenGeneration = gen
        if link.device != nil { log("keyboard connected") }
        else { log(first ? "waiting for the keyboard" : "keyboard unplugged") }
        // An unplug is a power cycle: the keyboard comes back on its own saved
        // settings, so anything borrowed is already undone. (The very first
        // sighting is not one — a takeover on disk then still needs handing back.)
        if !first { surface = nil; userTexts = nil; Takeover.clear() }
        onScreen = nil; drawn = nil; dismissed = false; lastCheck = .distantPast
        serial = nil; cdcUp = false; cdcBackoff = CDC_RETRY_MIN; nextCdcTry = .distantPast
        asleep = false; sleepBackoff = SLEEP_BACKOFF_MIN
    }

    private func awake() -> Bool {
        guard asleep else { return true }
        guard Date() >= nextWakeProbe else { return false }
        guard link.screenMode() != nil else {
            sleepBackoff = min(sleepBackoff * 2, SLEEP_BACKOFF_MAX)
            nextWakeProbe = Date().addingTimeInterval(sleepBackoff)
            return false
        }
        asleep = false
        sleepBackoff = SLEEP_BACKOFF_MIN
        log("keyboard awake")
        // It may have reloaded its stored frame and lost the pixel link while it
        // slept: redraw, and reopen the link once. The mode is kept — sleeping
        // does not change it, so a different mode now is the user's doing.
        drawn = nil
        serial = nil; cdcUp = false; cdcBackoff = CDC_RETRY_MIN; nextCdcTry = .distantPast
        return true
    }

    private func fellAsleep() {
        guard !asleep else { return }
        asleep = true
        sleepBackoff = SLEEP_BACKOFF_MIN
        nextWakeProbe = Date().addingTimeInterval(sleepBackoff)
        log("keyboard not answering (asleep?) — waiting for it")
    }

    // MARK: Logging

    private func log(_ s: String) { print("[\(stamp())] \(s)"); lastNote = nil }

    /// Log a standing condition once rather than on every tick it persists.
    private func note(_ s: String) {
        guard s != lastNote else { return }
        print("[\(stamp())] \(s)")
        lastNote = s
    }
}

func modeName(_ m: UInt8) -> String {
    screenModes.first { $0.value == m }.map { $0.key.uppercased() } ?? "mode \(m)"
}

var signalSources: [DispatchSourceSignal] = []

func runDaemon() {
    let cfg = Config.load()
    print("dp104status: watching \(stateURL.path) — display \(cfg.display.rawValue)")

    let link = HIDLink()
    let renderer = Renderer(link: link)

    var remote: RemoteListener?
    if let port = cfg.remotePort {
        remote = RemoteListener(port: port)
        print(remote == nil
              ? "remote: could not bind 127.0.0.1:\(port) — is another daemon running?"
              : "remote: listening on 127.0.0.1:\(port)")
    }
    _ = remote     // held for the daemon's lifetime

    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { renderer.shutdown(); print("\nstopped"); exit(0) }
        src.resume()
        signalSources.append(src)
    }

    let timer = Timer(timeInterval: POLL_INTERVAL, repeats: true) { _ in
        renderer.update(loadState().aggregate())
    }
    RunLoop.current.add(timer, forMode: .default)
    RunLoop.current.run()
}

// MARK: - Hook config output

let claudeEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse",
                    "PermissionRequest", "SubagentStart", "SubagentStop", "Stop", "SessionEnd"]
let codexEvents = ["UserPromptSubmit", "PostToolUse", "PermissionRequest",
                   "SubagentStart", "SubagentStop", "Stop", "SessionStart", "SessionEnd"]

func printHooks(product: String) {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0],
                  relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
    let events = product == "claude" ? claudeEvents : codexEvents
    let blocks = events.map { e in
        let timeout = product == "codex" && e == "SessionEnd" ? 3 : 5
        return """
            "\(e)": [
              { "hooks": [{ "type": "command", "command": "\(exe) hook \(product)", "timeout": \(timeout) }] }
            ]
        """
    }
    print("{\n  \"hooks\": {\n" + blocks.joined(separator: ",\n") + "\n  }\n}")
}

// MARK: - Entry point

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered: output survives an abnormal exit, and reaches log files promptly
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "hook":
    guard let p = args.dropFirst().first, p == "claude" || p == "codex" else { exit(0) }
    runHook(product: p)

case "daemon":
    runDaemon()

case "status":
    let agg = loadState().aggregate()
    let text = render(agg)
    print(text.isEmpty ? "(idle)" : text)
    for (k, o) in loadState().owners.sorted(by: { $0.key < $1.key }) {
        print("  \(k)  \(o.activity.rawValue)")
    }
    if let t = Takeover.load() {
        print("screen borrowed — goes back to \(modeName(t.userMode))"
              + (t.userTexts == nil ? "" : ", with your texts"))
    }

case "probe":
    // Read-only look at the keyboard: what the screen is doing and how soon it sleeps.
    let link = HIDLink()
    guard link.device != nil else { print("no keyboard on USB"); exit(1) }
    func value(_ ch: UInt8, _ v: UInt8) -> UInt8? { link.get(ch, v).flatMap { $0.count > 3 ? $0[3] : nil } }
    let sleeps: [UInt8: String] = [0: "never", 1: "5 min", 2: "15 min", 3: "30 min", 4: "1 h", 5: "3 h", 6: "6 h"]
    guard let mode = value(CH_SCREEN, VAL_EFFECT) else {
        print("keyboard did not answer — asleep? press a key and try again"); exit(1)
    }
    print("screen mode : \(modeName(mode))")
    print("brightness  : " + (value(CH_SCREEN, VAL_BRIGHTNESS).map { "\($0)/255" } ?? "—"))
    print("sleeps after: " + (value(17, 2).map { sleeps[$0] ?? "setting \($0)" } ?? "—"))
    print("pixel link  : " + (findSerialPath() ?? "no serial node"))
    if let t = Takeover.load() { print("borrowed    : goes back to \(modeName(t.userMode))") }

case "restore":
    // Hand back a borrowed screen by hand. With the daemon running it will
    // borrow again while agents are active — stop it first to keep it back.
    let link = HIDLink()
    guard link.device != nil else { print("no keyboard on USB"); exit(1) }
    guard let t = Takeover.load() else { print("nothing borrowed — the screen is already yours"); exit(0) }
    guard handBack(t, via: link) else {
        print("keyboard did not answer — asleep? press a key and try again"); exit(1)
    }
    Takeover.clear()
    print("handed back: \(modeName(t.userMode))" + (t.userTexts.map { ", texts \($0)" } ?? ""))

case "hooks":
    guard let p = args.dropFirst().first, p == "claude" || p == "codex" else {
        print("usage: dp104status hooks <claude|codex>"); exit(2)
    }
    printHooks(product: p)

case "pixel-test":
    guard let path = findSerialPath() else { print("no serial node for \(String(format: "%04x:%04x", VID, PID))"); exit(1) }
    print("serial node : \(path)")
    guard let port = SerialPort(path: path) else {
        print("open failed — the daemon already holds the port. Stop it first:")
        print("  launchctl bootout gui/$(id -u)/com.skyler.dp104status")
        exit(1)
    }
    print("opened      : ok")
    print("ping        : \(port.ping() ? "answered" : "no answer")")
    let hdr = port.packet(CMD_FRAME_HEADER, [1, 10, UInt8(SCREEN_ROWS), UInt8(SCREEN_COLS)])
    if let h = hdr {
        print("header resp : \(h.prefix(10).map { String(format: "%02x", $0) }.joined(separator: " "))")
        print("  resp[5]=\(h[5]) (0xEE=error)  resp[6]=\(h[6]) (chunks acked)")
    } else {
        print("header resp : <nil — no 64-byte reply>"); exit(1)
    }
    let demo: [String: Activity] = ["claude": .working, "codex": .waiting]
    let ok = port.sendFrame(buildFrame(demo), rows: SCREEN_ROWS, cols: SCREEN_COLS)
    print("sendFrame   : \(ok ? "OK" : "FAILED")")

case "preview":
    // Render a frame to the terminal so glyphs can be iterated on without hardware.
    // Anything that is not a known activity — "idle", "off", "-" — means absent,
    // which is exactly how the aggregate represents a product with nothing running.
    var demo: [String: Activity] = [:]
    for (i, product) in productOrder.enumerated() where i + 1 < args.count {
        if let a = Activity(rawValue: args[i + 1]) { demo[product] = a }
    }
    let frame = buildFrame(demo)
    let shown = productOrder.map { "\($0)=\(demo[$0]?.rawValue ?? "idle")" }.joined(separator: "  ")
    print("\(shown)\n")
    for row in 0..<SCREEN_ROWS {
        var line = "  "
        for col in 0..<SCREEN_COLS {
            let v = frame[(row * SCREEN_COLS + col) * 3 + 2]   // V channel
            line += v == 0 ? "." : (v < 128 ? "-" : "#")       // off / dim / lit
        }
        print(line)
    }
    print("\n  \(SCREEN_ROWS)x\(SCREEN_COLS), \(frame.count) bytes HSV")

case "config":
    var cfg = Config.load()
    let key = args.dropFirst().first
    let want = args.dropFirst(2).first
    switch (key, want) {
    case ("display", .some(let v)):
        guard let d = Display(rawValue: v.lowercased()) else {
            print("unknown display \(v) — mixed, pixel or text"); exit(2)
        }
        cfg.display = d
    case ("remote", .some(let v)):
        if v == "off" {
            cfg.remotePort = nil
        } else if let p = UInt16(v), p >= 1024 {
            cfg.remotePort = p
        } else {
            print("remote takes a port above 1023, or off"); exit(2)
        }
    case ("idle", _):
        print("""
        There is no idle setting any more: the screen follows your own mode.
          leave it on CUSTOM   the status display stays up, dim while agents are idle
          leave it elsewhere   borrowed only while agents run, then handed back
        """)
        exit(2)
    case (.some(let k), _) where !["display", "remote"].contains(k):
        print("usage: dp104status config [display <mixed|pixel|text>] [remote <port|off>]"); exit(2)
    default:
        break
    }
    try? cfg.save()   // always rewrite, so every field is present and explicit

    print("display : \(cfg.display.rawValue)   (mixed | pixel | text)")
    print("remote  : " + (cfg.remotePort.map { "127.0.0.1:\($0)" } ?? "off"))
    print("config  : \(configURL.path)")
    if key != nil {
        print("\nThe daemon reads this at start — restart it to apply:")
        print("  launchctl kickstart -k gui/$(id -u)/com.skyler.dp104status")
    }

case "remote-hook":
    guard let p = args.dropFirst().first, products.contains(p) else {
        print("usage: dp104status remote-hook <claude|codex>"); exit(2)
    }
    let port = Config.load().remotePort ?? 47104
    // Bash's /dev/tcp keeps this dependency-free on the remote host, and every
    // failure path exits 0: a missing tunnel must never fail the agent's turn.
    print("""
    #!/bin/bash
    # dp104status remote hook — reports one \(p) lifecycle event to a Mac
    # running `dp104status daemon`, reached through an SSH reverse tunnel.
    #
    # Install on the remote host, make it executable, and point that host's
    # hook configuration at it. It sends only the event name and identifiers
    # the daemon already reads; the prompt and tool output stay on this host.
    exec 3<>/dev/tcp/127.0.0.1/\(port) 2>/dev/null || exit 0
    printf '%s\\t' '\(p)' >&3
    tr -d '\\r\\n' >&3
    printf '\\n' >&3
    exec 3>&-
    exit 0
    """)

default:
    print("""
    dp104status — agent activity on a Ticktype DP104 screen

      dp104status daemon                  own the screen, render the aggregate state
      dp104status hook <claude|codex>     record one hook event from stdin
      dp104status status                  what the daemon would render, and what it holds
      dp104status probe                   read-only look at the keyboard
      dp104status restore                 hand a borrowed screen back by hand
      dp104status config [display <mixed|pixel|text>] [remote <port|off>]
      dp104status hooks <claude|codex>    print hook config to install
      dp104status remote-hook <product>   print the forwarder for an SSH host
      dp104status preview <a> <b>         draw a frame in the terminal
      dp104status pixel-test              exercise the pixel link (daemon stopped)

    The screen follows your own mode: leave it on CUSTOM for a permanent status
    display, or anywhere else to have it borrowed only while agents run.
    """)
}
