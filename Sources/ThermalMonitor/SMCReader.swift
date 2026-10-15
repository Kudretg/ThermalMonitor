import Foundation
import IOKit
import CryptoKit

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

// Not thread-safe: the key-info cache is unsynchronized, so every instance method
// must be called from one serial queue (ThermalModel.smcQueue).
class SMCReader: @unchecked Sendable {
    private var connection: io_connect_t = 0
    private(set) var isOpen = false

    // Key info never changes at runtime, and most catalogue keys don't exist on a
    // given Mac, so cache both hits and confirmed misses to halve IOKit calls per poll.
    private var keyInfoCache: [UInt32: SMCKeyInfoData] = [:]
    private var missingKeys: Set<UInt32> = []
    private static let kSMCKeyNotFound: UInt8 = 0x84

    private static let typeFlt  = fourCC("flt ")
    private static let typeSP78 = fourCC("sp78")
    private static let typeFPE2 = fourCC("fpe2")

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

    private static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for byte in s.utf8 { v = (v << 8) | UInt32(byte) }
        return v
    }

    // Returns nil only on an IOKit failure; callers check `result` for SMC errors.
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
        guard kr == kIOReturnSuccess else { return nil }
        return output
    }

    private func keyInfo(_ key: UInt32) -> SMCKeyInfoData? {
        if let cached = keyInfoCache[key] { return cached }
        if missingKeys.contains(key) { return nil }
        var input = SMCParamStruct()
        input.key = key
        input.data8 = UInt8(SMCSelector.getKeyInfo.rawValue)
        guard let output = callSMC(&input) else { return nil }  // transient: retry next poll
        guard output.result == 0 else {
            if output.result == Self.kSMCKeyNotFound { missingKeys.insert(key) }
            return nil
        }
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private func readRaw(_ key: String) -> (info: SMCKeyInfoData, data: SMCParamStruct)? {
        let code = Self.fourCC(key)
        guard let info = keyInfo(code) else { return nil }
        var input = SMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(SMCSelector.readKey.rawValue)
        guard let output = callSMC(&input), output.result == 0 else { return nil }
        return (info, output)
    }

    // Fan writes require root. We use a setuid-root helper installed on first run.
    // /Library/PrivilegedHelperTools is root-owned, unlike /usr/local/bin which is
    // often user-writable (Homebrew on Intel).
    static let helperDest = "/Library/PrivilegedHelperTools/com.github.Kudretg.ThermalMonitor.smc_write"
    // Where versions before 1.1 installed an unrestricted, world-executable helper.
    static let legacyHelperDest = "/usr/local/bin/smc_write"

    // Only a root-owned setuid regular file can actually perform writes; anything
    // else would make every fan change fail silently.
    static var helperAvailable: Bool {
        var st = stat()
        guard lstat(helperDest, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFREG
            && st.st_uid == 0
            && (st.st_mode & S_ISUID) != 0
            && FileManager.default.isExecutableFile(atPath: helperDest)
    }

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

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }

    // Shows the standard macOS "enter password" dialog then installs the helper.
    static func installHelper(completion: @escaping (Bool, String?) -> Void) {
        guard let src = bundledHelperPath else {
            completion(false, "smc_write binary not found inside the app bundle.")
            return
        }
        // The app bundle is usually user-writable, so pin the helper's contents now and
        // have root re-check them after copying into a root-only temp dir. If anything
        // swaps the file while the password prompt is up, the install aborts instead of
        // making the replacement setuid root.
        guard let contents = FileManager.default.contents(atPath: src) else {
            completion(false, "Could not read the bundled smc_write binary.")
            return
        }
        let sha256 = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()

        let dest = shellQuote(helperDest)
        let legacy = shellQuote(legacyHelperDest)
        let shellCmd = [
            "set -e",
            "tmp=$(/usr/bin/mktemp -d /tmp/thermalmonitor.XXXXXX)",
            "trap '/bin/rm -rf \"$tmp\"' EXIT",
            "/bin/cp \(shellQuote(src)) \"$tmp/smc_write\"",
            "[ \"$(/usr/bin/shasum -a 256 \"$tmp/smc_write\" | /usr/bin/cut -d' ' -f1)\" = \(sha256) ]"
                + " || { echo 'smc_write changed during install; aborting.' >&2; exit 1; }",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            // Admin-group only: non-admin accounts on the Mac can't touch the fans.
            "/usr/bin/install -o root -g admin -m 4750 \"$tmp/smc_write\" \(dest)",
            // Remove the old unrestricted helper so it stops being a root entry point.
            "if [ -u \(legacy) ]; then /bin/rm -f \(legacy); fi",
        ].joined(separator: "; ")
        let script = "do shell script \(appleScriptString(shellCmd)) with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            DispatchQueue.main.async {
                if let e = err {
                    completion(false, e[NSAppleScript.errorMessage] as? String)
                } else {
                    completion(helperAvailable, helperAvailable ? nil : "Helper installed but not usable.")
                }
            }
        }
    }

    // Blocks until the helper exits — call off the main thread.
    private func writeViaHelper(_ key: String, type t: String, value: String) -> Bool {
        guard SMCReader.helperAvailable else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SMCReader.helperDest)
        p.arguments = [key, t, value]
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationReason == .exit && p.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Decode helpers (Apple Silicon M1 uses IEEE 754 'flt ' little-endian)

    // Decodes a 4-byte little-endian IEEE 754 float from the SMC bytes tuple
    private func decodeFloat(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> Double {
        let bits = UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24
        return Double(Float(bitPattern: bits))
    }

    // Legacy Intel sp78 decoder
    private func decodeSP78(_ b0: UInt8, _ b1: UInt8) -> Double {
        return Double(Int16(bitPattern: UInt16(b0) << 8 | UInt16(b1))) / 256.0
    }

    // MARK: - Public API

    func temperature(key: String) -> Double? {
        guard let r = readRaw(key) else { return nil }
        let b = r.data.bytes
        let temp: Double
        switch r.info.dataType {
        case Self.typeFlt:  temp = decodeFloat(b.0, b.1, b.2, b.3)
        case Self.typeSP78: temp = decodeSP78(b.0, b.1)
        default:            return nil  // unknown encoding: hide rather than show garbage
        }
        guard temp > -40 && temp < 150 else { return nil }
        return temp
    }

    func fanCount() -> Int {
        guard let r = readRaw("FNum") else { return 0 }
        return Int(r.data.bytes.0)
    }

    private func fanSpeed(_ key: String) -> Double? {
        guard let r = readRaw(key) else { return nil }
        let b = r.data.bytes
        // M1 uses 'flt ', Intel used 'fpe2'
        switch r.info.dataType {
        case Self.typeFlt:  return decodeFloat(b.0, b.1, b.2, b.3)
        case Self.typeFPE2: return Double(UInt32(b.0) << 8 | UInt32(b.1)) / 4.0
        default:            return nil
        }
    }

    func fanCurrentSpeed(index: Int) -> Double? { fanSpeed("F\(index)Ac") }
    func fanMinSpeed(index: Int) -> Double?     { fanSpeed("F\(index)Mn") }
    func fanMaxSpeed(index: Int) -> Double?     { fanSpeed("F\(index)Mx") }

    // nil when the mode key can't be read; the caller keeps its last known state.
    func fanIsManual(index: Int) -> Bool? {
        guard let r = readRaw("F\(index)Md") else { return nil }
        return r.data.bytes.0 != 0
    }

    // Blocking (runs the helper twice). Returns false if either write failed, in
    // which case the fan is handed back to automatic control.
    func setFanManual(index: Int, speed: Double) -> Bool {
        guard writeViaHelper("F\(index)Md", type: "ui8", value: "1") else { return false }
        if writeViaHelper("F\(index)Tg", type: "flt", value: String(format: "%.1f", speed)) { return true }
        setFanAuto(index: index)
        return false
    }

    @discardableResult
    func setFanAuto(index: Int) -> Bool {
        writeViaHelper("F\(index)Md", type: "ui8", value: "0")
    }
}
