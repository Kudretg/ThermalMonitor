// smc_write — privileged SMC fan-control writer
//
// Installed setuid-root (root:admin, mode 4750) so the menu bar app can change fan
// settings. Because it runs as root for any admin-group caller, it only accepts the
// two fan-control keys and validates every value:
//   smc_write F<n>Md ui8 0|1      — fan n automatic (0) / manual (1)
//   smc_write F<n>Tg flt <rpm>    — fan n target RPM, clamped to [F<n>Mn, F<n>Mx]
//
// Imports only Darwin + IOKit (no Foundation) to keep the setuid attack surface small.

import Darwin
import IOKit

// ---- SMC struct (must match kernel layout exactly: 80 bytes) ----
struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
struct SMCParamStruct {
    var key: UInt32 = 0; var vers = SMCVersion(); var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var _kp0: UInt8 = 0; var _kp1: UInt8 = 0; var _kp2: UInt8 = 0
    var result: UInt8 = 0; var status: UInt8 = 0; var data8: UInt8 = 0
    var _dp: UInt8 = 0; var data32: UInt32 = 0
    var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

let kSMCReadKey: UInt8 = 5
let kSMCWriteKey: UInt8 = 6
let kSMCGetKeyInfo: UInt8 = 9

// ---- Helpers ----
func fourCC(_ s: String) -> UInt32 { var v: UInt32 = 0; for b in s.utf8 { v = (v<<8)|UInt32(b) }; return v }

let typeUI8 = fourCC("ui8 ")
let typeFlt = fourCC("flt ")
let typeFPE2 = fourCC("fpe2")

var conn: io_connect_t = 0

func fail(_ msg: String) -> Never {
    fputs("smc_write: \(msg)\n", stderr)
    if conn != 0 { IOServiceClose(conn) }
    exit(1)
}

func smcCall(_ input: inout SMCParamStruct) -> (kern_return_t, SMCParamStruct) {
    var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.size
    let kr = withUnsafePointer(to: &input) { ip in withUnsafeMutablePointer(to: &out) { op in
        IOConnectCallStructMethod(conn, 2, UnsafeRawPointer(ip), MemoryLayout<SMCParamStruct>.size, UnsafeMutableRawPointer(op), &sz)
    }}
    return (kr, out)
}

func getKeyInfo(_ key: String) -> SMCKeyInfoData? {
    var i = SMCParamStruct(); i.key = fourCC(key); i.data8 = kSMCGetKeyInfo
    let (kr, o) = smcCall(&i)
    guard kr == kIOReturnSuccess && o.result == 0 else { return nil }
    return o.keyInfo
}

func smcRead(_ key: String) -> (info: SMCKeyInfoData, bytes: [UInt8])? {
    guard let info = getKeyInfo(key) else { return nil }
    var i = SMCParamStruct(); i.key = fourCC(key); i.keyInfo.dataSize = info.dataSize; i.data8 = kSMCReadKey
    let (kr, o) = smcCall(&i)
    guard kr == kIOReturnSuccess && o.result == 0 else { return nil }
    let bytes = withUnsafeBytes(of: o.bytes) { Array($0.prefix(Int(info.dataSize))) }
    return (info, bytes)
}

func smcWrite(_ key: String, info: SMCKeyInfoData, bytes valueBytes: [UInt8]) -> Bool {
    guard valueBytes.count == Int(info.dataSize) else {
        fputs("smc_write: '\(key)' expects \(info.dataSize) bytes, got \(valueBytes.count)\n", stderr); return false
    }
    var i = SMCParamStruct()
    i.key = fourCC(key)
    i.keyInfo = info
    i.data8 = kSMCWriteKey
    withUnsafeMutableBytes(of: &i.bytes) { ptr in
        for (idx, b) in valueBytes.enumerated() where idx < ptr.count { ptr[idx] = b }
    }
    let (kr, o) = smcCall(&i)
    if kr != kIOReturnSuccess {
        fputs("smc_write: IOKit error 0x\(String(UInt32(bitPattern: kr), radix: 16)) writing '\(key)'\n", stderr)
        return false
    }
    if o.result != 0 {
        fputs("smc_write: SMC error \(o.result) writing '\(key)'\n", stderr)
        return false
    }
    return true
}

// Fan speeds are 'flt ' (Apple Silicon, little-endian IEEE 754) or 'fpe2' (Intel, big-endian 14.2 fixed).
func decodeRPM(_ info: SMCKeyInfoData, _ b: [UInt8]) -> Float? {
    if info.dataType == typeFlt && b.count == 4 {
        return Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }
    if info.dataType == typeFPE2 && b.count == 2 {
        return Float(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
    }
    return nil
}

func encodeRPM(_ info: SMCKeyInfoData, _ v: Float) -> [UInt8]? {
    if info.dataType == typeFlt && info.dataSize == 4 {
        let bits = v.bitPattern
        return [UInt8(bits&0xFF), UInt8((bits>>8)&0xFF), UInt8((bits>>16)&0xFF), UInt8((bits>>24)&0xFF)]
    }
    if info.dataType == typeFPE2 && info.dataSize == 2 {
        let raw = UInt16(v * 4)
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }
    return nil
}

// Returns the fan digit for keys of the form F<0-9><suffix>, e.g. "F0Md".
func fanKeyIndex(_ key: String, suffix: String) -> Character? {
    let chars = Array(key)
    guard chars.count == 4, chars[0] == "F", let d = chars[1].asciiValue, (48...57).contains(d),
          String(chars[2...]) == suffix else { return nil }
    return chars[1]
}

// ---- Main ----
let args = CommandLine.arguments
guard args.count == 4 else {
    fputs("Usage: smc_write F<n>Md ui8 0|1\n       smc_write F<n>Tg flt <rpm>\n", stderr); exit(1)
}

let key = args[1]; let typeStr = args[2]; let valStr = args[3]

// Validate everything we can before touching the SMC.
enum Request { case mode(UInt8), target(fan: Character, rpm: Float) }
let request: Request
if fanKeyIndex(key, suffix: "Md") != nil {
    guard typeStr == "ui8" else { fail("'\(key)' must be written as ui8") }
    guard let v = UInt8(valStr), v <= 1 else { fail("'\(key)' accepts only 0 or 1") }
    request = .mode(v)
} else if let fan = fanKeyIndex(key, suffix: "Tg") {
    guard typeStr == "flt" else { fail("'\(key)' must be written as flt") }
    guard let v = Float(valStr), v.isFinite else { fail("invalid RPM '\(valStr)'") }
    request = .target(fan: fan, rpm: v)
} else {
    fail("key '\(key)' is not allowed (only F<n>Md and F<n>Tg)")
}

// Open SMC
let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
guard svc != IO_OBJECT_NULL else { fail("AppleSMC not found") }
let openKr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
IOObjectRelease(svc)
guard openKr == kIOReturnSuccess else {
    conn = 0
    fail("cannot open SMC (0x\(String(UInt32(bitPattern: openKr), radix:16)))")
}

guard let info = getKeyInfo(key) else { fail("key '\(key)' not found") }

var success = false
switch request {
case .mode(let v):
    guard info.dataType == typeUI8 && info.dataSize == 1 else { fail("'\(key)' is not a ui8 key") }
    success = smcWrite(key, info: info, bytes: [v])
case .target(let fan, let rpm):
    // Never let a caller stop the fan or overspin it: clamp to the SMC's own limits.
    guard let mn = smcRead("F\(fan)Mn").flatMap({ decodeRPM($0.info, $0.bytes) }),
          let mx = smcRead("F\(fan)Mx").flatMap({ decodeRPM($0.info, $0.bytes) }),
          mn.isFinite, mx.isFinite, mn >= 0, mx > mn else {
        fail("cannot read a valid min/max range for fan \(fan)")
    }
    guard let bytes = encodeRPM(info, min(max(rpm, mn), mx)) else { fail("'\(key)' has an unsupported data type") }
    success = smcWrite(key, info: info, bytes: bytes)
}

IOServiceClose(conn)
exit(success ? 0 : 1)
