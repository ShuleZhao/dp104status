// test helper: kb mode            -> print screen mode
//              kb setmode <n>      -> set screen mode (simulates the mode key)
//              kb texts            -> print the five text slots
import Foundation
import IOKit
import IOKit.hid
let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0xe560, kIOHIDProductIDKey: 0xe104,
    kIOHIDPrimaryUsagePageKey: 0xFF60, kIOHIDPrimaryUsageKey: 0x61] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(m, 0)
guard let d = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first else { print("no keyboard"); exit(1) }
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
final class B { var want: [UInt8] = []; var r: [UInt8]? }
let b = B()
IOHIDDeviceRegisterInputReportCallback(d, buf, 64, { c, _, _, _, _, p, n in
    let box = Unmanaged<B>.fromOpaque(c!).takeUnretainedValue()
    let rep = Array(UnsafeBufferPointer(start: p, count: n))
    if rep.starts(with: box.want) { box.r = rep; CFRunLoopStop(CFRunLoopGetCurrent()) }
}, Unmanaged.passUnretained(b).toOpaque())
func xfer(_ bytes: [UInt8]) -> [UInt8]? {
    var p = [UInt8](repeating: 0, count: 32); for (i, x) in bytes.enumerated() { p[i] = x }
    b.want = Array(bytes.prefix(3)); b.r = nil
    guard IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0, p, 32) == kIOReturnSuccess else { return nil }
    let end = Date().addingTimeInterval(0.6)
    while b.r == nil && end.timeIntervalSinceNow > 0 { CFRunLoopRunInMode(.defaultMode, end.timeIntervalSinceNow, true) }
    return b.r
}
let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "mode": print(xfer([0x08, 26, 2]).map { String($0[3]) } ?? "?")
case "setmode": _ = xfer([0x07, 26, 2, UInt8(a[2])!]); print("set \(a[2])")
case "texts":
    var all: [String] = []
    for s in 0..<5 {
        var t = ""
        for off in [0, 26] {
            let n = min(30 - off, 26)
            if let r = xfer([0x08, 26, 5, UInt8(s), UInt8(off), UInt8(n)]) {
                t += String(bytes: r[6..<(6+n)].filter { $0 != 0 }, encoding: .ascii) ?? ""
            }
        }
        all.append(t)
    }
    print(all)
default: print("usage: kb mode|setmode <n>|texts")
}
