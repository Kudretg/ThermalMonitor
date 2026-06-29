// smc_write — privileged SMC key writer
// Install as setuid-root: sudo chown root:wheel smc_write && sudo chmod 4755 smc_write
// Usage:
//   smc_write <key> flt <float_value>   — write IEEE 754 float
//   smc_write <key> ui8 <int_value>     — write uint8

import Foundation
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

// ---- Helpers ----
func fourCC(_ s: String) -> UInt32 { var v: UInt32 = 0; for b in s.utf8 { v = (v<<8)|UInt32(b) }; return v }

var conn: io_connect_t = 0

func smcCall(_ input: inout SMCParamStruct) -> (kern_return_t, SMCParamStruct) {
    var out = SMCParamStruct(); var sz = MemoryLayout<SMCParamStruct>.size
    let kr = withUnsafePointer(to: &input) { ip in withUnsafeMutablePointer(to: &out) { op in
        IOConnectCallStructMethod(conn, 2, UnsafeRawPointer(ip), MemoryLayout<SMCParamStruct>.size, UnsafeMutableRawPointer(op), &sz)
    }}
    return (kr, out)
}

func getKeyInfo(_ key: String) -> SMCKeyInfoData? {
    var i = SMCParamStruct(); i.key = fourCC(key); i.data8 = 9
    let (kr, o) = smcCall(&i)
    guard kr == kIOReturnSuccess && o.result == 0 else { return nil }
    return o.keyInfo
}

func smcWrite(_ key: String, bytes valueBytes: [UInt8]) -> Bool {
    guard let info = getKeyInfo(key) else {
        fputs("smc_write: key '\(key)' not found\n", stderr); return false
    }
    var i = SMCParamStruct()
    i.key = fourCC(key)
    i.keyInfo = info
    i.data8 = 6  // kSMCWriteKey
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

// ---- Main ----
let args = CommandLine.arguments
guard args.count == 4 else {
    fputs("Usage: smc_write <key> flt|ui8 <value>\n", stderr); exit(1)
}

let key = args[1]; let typeStr = args[2]; let valStr = args[3]

// Open SMC
let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
guard svc != IO_OBJECT_NULL else { fputs("smc_write: AppleSMC not found\n", stderr); exit(1) }
let openKr = IOServiceOpen(svc, mach_task_self_, 0, &conn)
IOObjectRelease(svc)
guard openKr == kIOReturnSuccess else {
    fputs("smc_write: cannot open SMC (0x\(String(UInt32(bitPattern: openKr), radix:16)))\n", stderr); exit(1)
}

var success = false
switch typeStr {
case "flt":
    guard let v = Float(valStr) else { fputs("smc_write: invalid float '\(valStr)'\n", stderr); exit(1) }
    let bits = v.bitPattern
    success = smcWrite(key, bytes: [UInt8(bits&0xFF), UInt8((bits>>8)&0xFF), UInt8((bits>>16)&0xFF), UInt8((bits>>24)&0xFF)])
case "ui8":
    guard let v = UInt8(valStr) else { fputs("smc_write: invalid uint8 '\(valStr)'\n", stderr); exit(1) }
    success = smcWrite(key, bytes: [v])
default:
    fputs("smc_write: unknown type '\(typeStr)' (use flt or ui8)\n", stderr); exit(1)
}

IOServiceClose(conn)
exit(success ? 0 : 1)
