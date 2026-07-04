import Foundation
import IOKit

/// Read-only access to the SMC (System Management Controller) — the same undocumented mechanism
/// iStat Menus / Macs Fan Control use to read fan RPM. This only ever issues the SMC "read bytes"
/// call, never "write bytes", so it cannot change fan speed or any other SMC-controlled behavior.
/// The wire format below (`ParamStruct`, selector 2) is the long-stable layout used by those tools
/// and is identical on Intel and Apple Silicon — only fan *control* keys differ by chip generation.
enum SMC {
    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private typealias Bytes32 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private static let readKeyInfoSelector: UInt8 = 9
    private static let readBytesSelector: UInt8 = 5
    private static let handleYPCEvent: UInt32 = 2

    private static let connection: io_connect_t = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return 0 }
        return conn
    }()

    /// Reads a 4-character SMC key (e.g. "FNum", "F0Ac") and decodes it as a number, regardless of
    /// which underlying SMC type this particular key reports (ui8 / ui16 / ui32 / flt / fpe2 / sp78
    /// — fan RPM is "flt " on Apple Silicon, "fpe2" on Intel; we decode by the reported type rather
    /// than assuming one).
    static func readValue(_ key: String) -> Double? {
        guard connection != 0, let code = fourCharCode(key) else { return nil }

        var infoInput = ParamStruct()
        infoInput.key = code
        infoInput.data8 = readKeyInfoSelector
        var infoOutput = ParamStruct()
        guard call(&infoInput, &infoOutput) == KERN_SUCCESS, infoOutput.keyInfo.dataSize > 0 else { return nil }

        var readInput = ParamStruct()
        readInput.key = code
        readInput.keyInfo.dataSize = infoOutput.keyInfo.dataSize
        readInput.data8 = readBytesSelector
        var readOutput = ParamStruct()
        guard call(&readInput, &readOutput) == KERN_SUCCESS else { return nil }

        let size = Int(infoOutput.keyInfo.dataSize)
        let bytes = withUnsafeBytes(of: readOutput.bytes) { Array($0.prefix(size)) }
        return decode(bytes, type: infoOutput.keyInfo.dataType)
    }

    private static func call(_ input: inout ParamStruct, _ output: inout ParamStruct) -> kern_return_t {
        let inputSize = MemoryLayout<ParamStruct>.stride
        var outputSize = MemoryLayout<ParamStruct>.stride
        return IOConnectCallStructMethod(connection, handleYPCEvent, &input, inputSize, &output, &outputSize)
    }

    private static func fourCharCode(_ key: String) -> UInt32? {
        guard key.utf8.count == 4 else { return nil }
        return key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        guard !bytes.isEmpty else { return nil }
        switch typeString(type) {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 6) | (Int(bytes[1]) >> 2))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256
        default:
            return nil
        }
    }

    private static func typeString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [UInt8(code >> 24), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
