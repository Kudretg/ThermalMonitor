import Foundation
import IOKit

// MARK: - SMC Structures

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

// Swift omits trailing padding from embedded structs, so we must add explicit
// padding bytes to match the C layout the SMC kernel driver expects (80 bytes total).
// Without this the driver gets wrong offsets and returns kIOReturnBadArgument.
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var _kp0: UInt8 = 0   // explicit trailing padding for keyInfo (C adds 3 bytes)
    var _kp1: UInt8 = 0
    var _kp2: UInt8 = 0
    var result: UInt8 = 0  // now at offset 40, matching C layout
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var _dp: UInt8 = 0     // padding to align data32 to offset 44
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

enum SMCSelector: UInt32 {
    case handleYPCEvent = 2
    case readKey        = 5
    case writeKey       = 6
    case getKeyInfo     = 9
}

// MARK: - SMC Reader

class SMCReader: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private(set) var isOpen = false

    func open() {
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { return }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        isOpen = kr == kIOReturnSuccess
    }

    func close() {
        guard isOpen else { return }
        IOServiceClose(connection)
        connection = 0
        isOpen = false
    }

    // MARK: - Private helpers

    private func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for byte in s.utf8 { v = (v << 8) | UInt32(byte) }
        return v
    }

    private func callSMC(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard isOpen else { return nil }
        var output = SMCParamStruct()
        var size = MemoryLayout<SMCParamStruct>.size
        let kr = withUnsafePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(
                    connection,
                    UInt32(SMCSelector.handleYPCEvent.rawValue),
                    UnsafeRawPointer(inPtr),
                    MemoryLayout<SMCParamStruct>.size,
                    UnsafeMutableRawPointer(outPtr),
                    &size
                )
            }
        }
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(_ key: UInt32) -> SMCKeyInfoData? {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = UInt8(SMCSelector.getKeyInfo.rawValue)
        guard let output = callSMC(&input) else { return nil }
        return output.keyInfo
    }

    private func readRaw(_ key: String) -> SMCParamStruct? {
        let code = fourCC(key)
        guard let info = keyInfo(code) else { return nil }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(SMCSelector.readKey.rawValue)
        return callSMC(&input)
    }

    // Fan writes require root. We use a setuid-root helper installed on first run.
    static let helperDest = "/usr/local/bin/smc_write"
    static var helperAvailable: Bool { FileManager.default.isExecutableFile(atPath: helperDest) }

    // Locate the bundled smc_write binary (packed alongside the main executable).
    static var bundledHelperPath: String? {
        // 1. Inside .app bundle Contents/MacOS/
        if let url = Bundle.main.url(forAuxiliaryExecutable: "smc_write") {
            return url.path
        }
        // 2. Sibling of the running binary (dev / make run scenario)
        let sibling = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("smc_write").path
        return FileManager.default.fileExists(atPath: sibling) ? sibling : nil
    }

    // Shows the standard macOS "enter password" dialog then installs the helper.
    static func installHelper(completion: @escaping (Bool, String?) -> Void) {
        guard let src = bundledHelperPath else {
            completion(false, "smc_write binary not found inside the app bundle.")
            return
        }
        let dest = helperDest
        // Escape paths for AppleScript string literals
        let safeSrc  = src.replacingOccurrences(of: "'", with: "'\\''")
        let safeDest = dest.replacingOccurrences(of: "'", with: "'\\''")
        let shellCmd = "cp '\(safeSrc)' '\(safeDest)' && chown root:wheel '\(safeDest)' && chmod 4755 '\(safeDest)'"
        let script   = "do shell script \"\(shellCmd)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            DispatchQueue.main.async {
                if let e = err {
                    completion(false, e[NSAppleScript.errorMessage] as? String)
                } else {
                    completion(helperAvailable, helperAvailable ? nil : "Helper installed but not executable.")
                }
            }
        }
    }

    @discardableResult
    private func writeViaHelper(_ key: String, type t: String, value: String) -> Bool {
        guard SMCReader.helperAvailable else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SMCReader.helperDest)
        p.arguments = [key, t, value]
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    // MARK: - Decode helpers (Apple Silicon M1 uses IEEE 754 'flt ' little-endian)

    // Decodes a 4-byte little-endian IEEE 754 float from the SMC bytes tuple
    private func decodeFloat(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Double {
        let bits = UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24
        return Double(Float(bitPattern: bits))
    }

    private func encodeFloat(_ value: Double) -> [UInt8] {
        let bits = Float(value).bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF),
                UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    }

    // Legacy Intel sp78 decoder kept as fallback
    private func decodeSP78(_ b0: UInt8, _ b1: UInt8) -> Double {
        return Double(Int16(bitPattern: UInt16(b0) << 8 | UInt16(b1))) / 256.0
    }

    // MARK: - Public API

    func temperature(key: String) -> Double? {
        let code = fourCC(key)
        guard let info = keyInfo(code) else { return nil }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(SMCSelector.readKey.rawValue)
        guard let data = callSMC(&input) else { return nil }

        let typeCC = info.dataType
        let temp: Double
        if typeCC == fourCC("flt ") {
            temp = decodeFloat(data.bytes.0, data.bytes.1, data.bytes.2, data.bytes.3)
        } else {
            // sp78 or other legacy fixed-point (Intel Macs)
            temp = decodeSP78(data.bytes.0, data.bytes.1)
        }
        guard temp > -40 && temp < 150 else { return nil }
        return temp
    }

    func fanCount() -> Int {
        guard let data = readRaw("FNum") else { return 0 }
        return Int(data.bytes.0)
    }

    private func fanSpeed(_ key: String) -> Double? {
        let code = fourCC(key)
        guard let info = keyInfo(code) else { return nil }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(SMCSelector.readKey.rawValue)
        guard let data = callSMC(&input) else { return nil }
        // M1 uses 'flt ', Intel used 'fpe2'
        if info.dataType == fourCC("flt ") {
            return decodeFloat(data.bytes.0, data.bytes.1, data.bytes.2, data.bytes.3)
        } else {
            return Double(UInt32(data.bytes.0) << 8 | UInt32(data.bytes.1)) / 4.0
        }
    }

    func fanCurrentSpeed(index: Int) -> Double? { fanSpeed("F\(index)Ac") }
    func fanMinSpeed(index: Int) -> Double?     { fanSpeed("F\(index)Mn") }
    func fanMaxSpeed(index: Int) -> Double?     { fanSpeed("F\(index)Mx") }

    func setFanManual(index: Int, speed: Double) {
        writeViaHelper("F\(index)Md", type: "ui8", value: "1")
        writeViaHelper("F\(index)Tg", type: "flt", value: String(format: "%.1f", speed))
    }

    func setFanAuto(index: Int) {
        writeViaHelper("F\(index)Md", type: "ui8", value: "0")
    }
}
