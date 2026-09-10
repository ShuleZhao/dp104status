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
let RECONNECT_INTERVAL: TimeInterval = 3.0   // how often to look for a keyboard that went away
let VERIFY_INTERVAL: TimeInterval = 5.0      // how often to read the screen back and re-assert
let SERIAL_RETRY_INTERVAL: TimeInterval = 30 // how long to sit in the text fallback before retrying pixel
let IDLE_FRAME = "(idle)"                    // cache marker for the dim resting frame

// MARK: - Paths

let home = FileManager.default.homeDirectoryForCurrentUser
let stateDir = home.appendingPathComponent(".dp104status")
let stateURL = stateDir.appendingPathComponent("state.json")
let stateLockURL = stateDir.appendingPathComponent("state.lock")
let baselineURL = stateDir.appendingPathComponent("baseline.json")
let configURL = stateDir.appendingPathComponent("config.json")

func ensureStateDir() throws {
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
}

// MARK: - Config

enum Display: String, Codable {
    case pixel     // two 8x12 halves on the dot-matrix screen, one per product
    case text      // a single scrolling line, "CLAUDE WORK  CODEX WAIT"
}

struct Config: Codable {
    /// Screen mode to leave the keyboard in when nothing is running.
    /// nil means "put back whatever mode was there when the daemon first started".
    var idleMode: UInt8? = MODE_INFO

    /// How to show an active state. Pixel needs the CDC serial interface;
    /// text needs only raw HID, and is the fallback if the port cannot be found.
    var display: Display = .pixel

    /// Stay on the pixel display when nothing is running, with both halves dim,
    /// instead of handing the screen back to the user's own mode. Keeps the
    /// layout permanently visible so a state change is the only thing that moves.
    var idleKeep: Bool = false

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

func runHook(product: String) {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let event = try? JSONDecoder().decode(HookEvent.self, from: input),
          let name = event.hook_event_name, !name.isEmpty else { exit(0) }
    let session = event.session_id.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
    let agent = event.agent_id.flatMap { $0.isEmpty ? nil : $0 } ?? "main"
    let now = Date().timeIntervalSince1970
    _ = try? withState { st in
        apply(event: name, product: product, session: session, agent: agent, to: &st, now: now)
        st.owners = st.owners.filter { $0.value.alive(now) }   // reap on the way past
    }
    exit(0)   // hooks must never block or fail the agent
}

// MARK: - HID transport

final class Keyboard {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private var buf = [UInt8](repeating: 0, count: 64)
    private final class Box { var last: [UInt8]? }
    private let box = Box()

    /// Set when a report cannot be delivered at all — the device is gone, as
    /// opposed to a command the firmware simply does not implement.
    private(set) var gone = false

    deinit { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: VID, kIOHIDProductIDKey: PID,
            kIOHIDPrimaryUsagePageKey: USAGE_PAGE, kIOHIDPrimaryUsageKey: USAGE,
        ] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let dev = set.first else { return nil }
        device = dev
        IOHIDDeviceRegisterInputReportCallback(device, &buf, buf.count, { ctx, _, _, _, _, rep, len in
            Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue().last =
                Array(UnsafeBufferPointer(start: rep, count: min(len, 64)))
            CFRunLoopStop(CFRunLoopGetCurrent())
        }, Unmanaged.passUnretained(box).toOpaque())
    }

    @discardableResult
    func send(_ cmd: UInt8, _ args: [UInt8]) -> [UInt8]? {
        var p = [UInt8](repeating: 0, count: REPORT)
        p[0] = cmd
        for (i, a) in args.enumerated() where i + 1 < REPORT { p[i + 1] = a }
        box.last = nil
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, p, p.count) == kIOReturnSuccess
        else { gone = true; return nil }
        CFRunLoopRunInMode(.defaultMode, 0.5, false)
        // 0xff in byte 0 means "firmware does not implement this command".
        if let r = box.last, r.first == 0xff { return nil }
        return box.last
    }

    func get(_ channel: UInt8, _ value: UInt8, _ extra: [UInt8] = []) -> [UInt8]? {
        send(0x08, [channel, value] + extra)
    }

    func set(_ channel: UInt8, _ value: UInt8, _ payload: [UInt8]) {
        send(0x07, [channel, value] + payload)
    }

    func readText(slot: Int) -> String {
        var out = ""
        var offset = 0
        while offset < TEXT_LEN {
            let n = min(TEXT_LEN - offset, 26)
            guard let r = get(CH_SCREEN, VAL_TEXT, [UInt8(slot), UInt8(offset), UInt8(n)]),
                  r.count >= 6 + n else { break }
            out += String(bytes: r[6..<(6 + n)].filter { $0 != 0 }, encoding: .ascii) ?? ""
            offset += n
        }
        return out
    }

    /// Always writes the full 30 bytes so a shorter string cannot leave a tail behind.
    func writeText(slot: Int, _ text: String) {
        var bytes = Array(text.uppercased().unicodeScalars.compactMap { $0.isASCII ? UInt8($0.value) : 0x20 })
        bytes = Array(bytes.prefix(TEXT_LEN))
        bytes += [UInt8](repeating: 0, count: TEXT_LEN - bytes.count)
        var offset = 0
        while offset < TEXT_LEN {
            let n = min(TEXT_LEN - offset, 26)
            set(CH_SCREEN, VAL_TEXT, [UInt8(slot), UInt8(offset), UInt8(n)] + Array(bytes[offset..<(offset + n)]))
            offset += n
        }
    }

    func screenMode() -> UInt8? { get(CH_SCREEN, VAL_EFFECT).flatMap { $0.count > 3 ? $0[3] : nil } }
    func setScreenMode(_ m: UInt8) { set(CH_SCREEN, VAL_EFFECT, [m]) }
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
    let path: String

    init?(path: String) {
        let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return nil }
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
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { close(f); return nil }
        _ = fcntl(fd, F_SETFL, 0)       // back to blocking reads
        tcflush(fd, TCIOFLUSH)
    }

    deinit { close(fd) }

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

// MARK: - Baseline (what the keyboard looked like before we touched it)

struct Baseline: Codable {
    var texts: [String]
    var screenMode: UInt8
}

func saveBaselineIfNeeded(_ kb: Keyboard) -> Baseline? {
    if let data = try? Data(contentsOf: baselineURL),
       let b = try? JSONDecoder().decode(Baseline.self, from: data) { return b }
    guard let mode = kb.screenMode() else { return nil }
    let b = Baseline(texts: (0..<TEXT_SLOTS).map { kb.readText(slot: $0) }, screenMode: mode)
    try? ensureStateDir()
    try? JSONEncoder().encode(b).write(to: baselineURL)
    return b
}

/// Put the user's own texts back and leave the screen in the configured resting
/// mode — which is *not* necessarily the mode the daemon happened to find at
/// startup, since that may have been a transient one.
func restore(_ kb: Keyboard, _ b: Baseline, idleMode: UInt8?) {
    for (i, t) in b.texts.enumerated() where i < TEXT_SLOTS { kb.writeText(slot: i, t) }
    kb.setScreenMode(idleMode ?? b.screenMode)
}

// MARK: - Daemon

func stamp() -> String { Date().formatted(date: .omitted, time: .standard) }

/// Owns the keyboard for the daemon's lifetime, surviving unplug/replug.
/// A missing keyboard is a normal state here, not a fatal one: hooks keep
/// recording activity regardless, and the screen catches up on reconnect.
final class Renderer {
    private var kb: Keyboard?
    private var baseline: Baseline?
    private var rendered: String?
    private var lastAttempt = Date.distantPast
    private var lastVerify = Date.distantPast
    private var serial: SerialPort?
    private var lastSerialAttempt = Date.distantPast
    private var pixelDisabled = false
    private let config = Config.load()

    /// The daemon caches what it believes is on screen so it does not rewrite on
    /// every tick. That cache goes stale the moment anything else touches the
    /// keyboard — the physical mode key, VIA, or another copy of this tool — and
    /// without this check the screen would stay wrong forever. So periodically
    /// read the device back and drop the cache when it disagrees.
    private func verifyIfDue(_ kb: Keyboard) {
        guard let shown = rendered,
              Date().timeIntervalSince(lastVerify) > VERIFY_INTERVAL else { return }
        lastVerify = Date()
        guard let mode = kb.screenMode() else { return }   // read failed: leave it be
        // Frame data has no read-back, so in pixel mode the screen mode is all
        // there is to check; in text mode slot 0 can be compared too.
        var stale = mode != activeMode
        if mode == MODE_SCROLL {
            let slot0 = kb.readText(slot: 0)
            guard !kb.gone else { return }
            stale = stale || slot0 != shown.uppercased()
        }
        if stale {
            print("[\(stamp())] screen changed externally (mode=\(mode)) — reasserting")
            rendered = nil
        }
    }

    /// Pixel mode degrades to text when the serial side is unusable, so the
    /// display stays useful instead of going blank.
    private var activeDisplay: Display { pixelDisabled ? .text : config.display }
    private var activeMode: UInt8 { activeDisplay == .pixel ? MODE_CUSTOM : MODE_SCROLL }

    /// Resolved once and held for the daemon's lifetime; only a physical
    /// disconnect drops it. Reconnect attempts are rate limited so a keyboard
    /// that is simply absent does not get probed on every tick.
    private func serialPort() -> SerialPort? {
        if let serial { return serial }
        guard Date().timeIntervalSince(lastSerialAttempt) > SERIAL_RETRY_INTERVAL else { return nil }
        lastSerialAttempt = Date()
        guard let path = findSerialPath(), let port = SerialPort(path: path) else { return nil }
        print("[\(stamp())] serial: \(path)")
        serial = port
        return port
    }

    /// Send on the held connection and keep that connection whatever happens.
    ///
    /// This keyboard's CDC endpoint sometimes stops answering entirely — every
    /// command, down to a bare firmware query, reads back nothing, and only a
    /// physical replug revives it. HID is unaffected throughout. It has been
    /// seen twice and the trigger is not known: transport load, interleaved HID
    /// reads and writes, open/close cycling, idle gaps up to 20s and truncated
    /// transfers were each tested against it and none reproduced it. See
    /// DP104-PROTOCOL.md §5.1 for the experiments.
    ///
    /// So holding one descriptor is caution, not a proven remedy, and there is
    /// no reopen-as-recovery here: a failed frame is just a failed frame, and
    /// the caller degrades to the text display rather than churning the port on
    /// a hunch. Recovery lives in retryPixelIfDue().
    private func sendPixelFrame(_ payload: [UInt8]) -> Bool {
        guard let port = serialPort() else { return false }
        return port.sendFrame(payload, rows: SCREEN_ROWS, cols: SCREEN_COLS)
    }

    private func serialFailed() {
        pixelDisabled = true
        lastSerialAttempt = Date()      // note: the port stays open on purpose
        print("[\(stamp())] pixel frame failed — falling back to text; "
              + "retrying in \(Int(SERIAL_RETRY_INTERVAL))s. "
              + "If it never recovers, replug the keyboard: the CDC endpoint "
              + "sometimes stops answering until it is physically reconnected.")
    }

    private func retryPixelIfDue() {
        guard config.display == .pixel, pixelDisabled,
              Date().timeIntervalSince(lastSerialAttempt) >= SERIAL_RETRY_INTERVAL else { return }
        pixelDisabled = false
        rendered = nil
        print("[\(stamp())] retrying pixel display")
    }

    private func acquire() -> (Keyboard, Baseline)? {
        if let kb, !kb.gone, let baseline { return (kb, baseline) }
        if kb != nil {
            print("[\(stamp())] keyboard disconnected")
            kb = nil
            rendered = nil          // whatever it was showing is gone with it
            // A physical reconnect gives the CDC endpoint a fresh lifetime.
            // Drop the permanent text fallback and retry pixel transport from
            // scratch once the HID side is available again.
            serial = nil
            lastSerialAttempt = Date.distantPast
            pixelDisabled = false
        }
        guard Date().timeIntervalSince(lastAttempt) > RECONNECT_INTERVAL else { return nil }
        lastAttempt = Date()
        guard let fresh = Keyboard(), let b = saveBaselineIfNeeded(fresh) else { return nil }
        kb = fresh
        baseline = b
        rendered = nil              // force a redraw so state survives the gap
        print("[\(stamp())] keyboard connected — baseline mode=\(b.screenMode) texts=\(b.texts)")
        return (fresh, b)
    }

    func update(_ agg: [String: Activity]) {
        guard let (kb, baseline) = acquire() else { return }
        verifyIfDue(kb)
        retryPixelIfDue()

        let text = render(agg)
        if text.isEmpty, config.idleKeep, activeDisplay == .pixel {
            guard rendered != IDLE_FRAME else { return }
            if rendered == nil { kb.setScreenMode(MODE_CUSTOM) }
            guard sendPixelFrame(buildFrame([:])) else { serialFailed(); rendered = nil; return }
            rendered = IDLE_FRAME
            print("[\(stamp())] idle — holding the pixel display")
            return
        }
        if text.isEmpty {
            guard rendered != nil else { return }
            restore(kb, baseline, idleMode: config.idleMode)
            rendered = nil
            print("[\(stamp())] idle — keyboard restored")
            return
        }
        guard rendered != text else { return }
        let takingOver = rendered == nil

        switch activeDisplay {
        case .text:
            kb.writeText(slot: 0, text)
            if takingOver {         // clear the other slots so only our line scrolls
                for slot in 1..<TEXT_SLOTS { kb.writeText(slot: slot, "") }
                kb.setScreenMode(MODE_SCROLL)
            }
            guard !kb.gone else { rendered = nil; return }

        case .pixel:
            // Enter CUSTOM before the first frame; after that upload only.
            // Re-entering the mode would make the firmware reload its own stored
            // frame and discard ours, so never round-trip the mode here.
            if takingOver { kb.setScreenMode(MODE_CUSTOM) }
            guard sendPixelFrame(buildFrame(agg)) else {
                serialFailed(); rendered = nil; return
            }
        }

        rendered = text
        print("[\(stamp())] \(text)")
    }

    func restoreNow() {
        guard let kb, let baseline, rendered != nil else { return }
        restore(kb, baseline, idleMode: config.idleMode)
    }
}

var signalSources: [DispatchSourceSignal] = []

func runDaemon() {
    setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered so logs appear when piped to a file
    print("dp104status: watching \(stateURL.path)")

    let renderer = Renderer()

    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { renderer.restoreNow(); print("\nrestored"); exit(0) }
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

case "restore":
    guard let kb = Keyboard() else { print("no keyboard"); exit(1) }
    guard let data = try? Data(contentsOf: baselineURL),
          let b = try? JSONDecoder().decode(Baseline.self, from: data) else {
        print("no saved baseline"); exit(1)
    }
    let idle = Config.load().idleMode
    restore(kb, b, idleMode: idle)
    print("restored: mode=\(idle ?? b.screenMode) texts=\(b.texts)")

case "hooks":
    guard let p = args.dropFirst().first, p == "claude" || p == "codex" else {
        print("usage: dp104status hooks <claude|codex>"); exit(2)
    }
    printHooks(product: p)

case "pixel-test":
    guard let path = findSerialPath() else { print("no serial node for \(String(format: "%04x:%04x", VID, PID))"); exit(1) }
    print("serial node : \(path)")
    guard let port = SerialPort(path: path) else { print("open failed: \(String(cString: strerror(errno)))"); exit(1) }
    print("opened      : ok")
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
    case ("idle", .some(let v)):
        if v == "keep" {
            cfg.idleKeep = true
        } else if v == "restore" {
            cfg.idleKeep = false
            cfg.idleMode = nil
        } else if let m = screenModes[v.lowercased()] {
            cfg.idleKeep = false
            cfg.idleMode = m
        } else {
            print("unknown mode \(v) — one of: \(screenModes.keys.sorted().joined(separator: ", ")), restore, keep")
            exit(2)
        }
    case ("display", .some(let v)):
        guard let d = Display(rawValue: v.lowercased()) else {
            print("unknown display \(v) — pixel or text"); exit(2)
        }
        cfg.display = d
    case (.some(let k), _) where k != "idle" && k != "display":
        print("usage: dp104status config [idle <mode|restore|keep>|display <pixel|text>]"); exit(2)
    default:
        break
    }
    try? cfg.save()   // always rewrite, so every field is present and explicit

    let idleName = cfg.idleMode.flatMap { m in screenModes.first { $0.value == m }?.key }
    print("display  : \(cfg.display.rawValue)")
    print("idle mode: " + (cfg.idleKeep
        ? "keep (stay on the pixel display, both halves dim)"
        : (idleName ?? "restore (whatever was there at startup)")))
    print("config   : \(configURL.path)")

default:
    print("""
    dp104status — agent activity on a Ticktype DP104 screen

      dp104status daemon                own the keyboard, render the aggregate state
      dp104status hook <claude|codex>   record one hook event from stdin
      dp104status status                print what the daemon would render
      dp104status restore               put the keyboard back
      dp104status hooks <claude|codex>  print hook config to install
    """)
}
