import Foundation

/// What a monitor says it supports, parsed from its DDC/CI capabilities string, e.g.
/// `(prot(monitor)…vcp(10 12 14(05 08 0B 0C) DC(00 03 05))mccs_ver(2.1))`. Each advertised VCP
/// code maps to the discrete values the monitor accepts for it — empty for continuous features
/// such as brightness.
struct DDCCapabilities: Equatable {
    private(set) var vcp: [UInt8: [UInt16]] = [:]

    init(parsing string: String) {
        guard let body = Self.vcpGroup(in: string) else { return }
        var lastCode: UInt8?
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "(" {
                // The value list of the code just before it. A truncated string has no closing
                // paren; keep whatever was read.
                let close = Self.closingParen(in: body, openAt: index) ?? body.endIndex
                if let lastCode {
                    vcp[lastCode] = body[body.index(after: index) ..< close]
                        .split(whereSeparator: { !$0.isHexDigit })
                        .compactMap { UInt16($0, radix: 16) }
                }
                index = close < body.endIndex ? body.index(after: close) : close
            } else if character.isHexDigit {
                let token = body[index...].prefix(while: \.isHexDigit)
                lastCode = UInt8(token, radix: 16)
                if let lastCode, vcp[lastCode] == nil { vcp[lastCode] = [] }
                index = token.endIndex
            } else {
                index = body.index(after: index)
            }
        }
    }

    func values(for code: VCPCode) -> [UInt16] { vcp[code.rawValue] ?? [] }

    /// The contents of the `vcp(…)` group (not `vcpname(…)`, which some monitors also send).
    private static func vcpGroup(in string: String) -> Substring? {
        var searchRange = string.startIndex ..< string.endIndex
        while let match = string.range(of: "vcp", options: .caseInsensitive, range: searchRange) {
            let rest = string[match.upperBound...].drop(while: \.isWhitespace)
            if rest.first == "(" {
                let close = closingParen(in: rest, openAt: rest.startIndex) ?? rest.endIndex
                return rest[rest.index(after: rest.startIndex) ..< close]
            }
            searchRange = match.upperBound ..< string.endIndex
        }
        return nil
    }

    private static func closingParen(in text: Substring, openAt open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "(" { depth += 1 }
            if text[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Reading from the monitor

extension DDCCapabilities {
    /// Reads and parses the capabilities string. Blocking (~1 s: the string arrives in 32-byte
    /// fragments), so call it off the main thread. Nil when the monitor doesn't answer.
    static func read(service: IOAVService) -> DDCCapabilities? {
        var bytes: [UInt8] = []
        // Real strings are a few hundred bytes; the limit only guards against a monitor that
        // never sends the terminating empty fragment.
        while bytes.count < 4096 {
            guard let fragment = readFragment(service: service, offset: bytes.count) else { return nil }
            if fragment.isEmpty {
                return DDCCapabilities(parsing: String(decoding: bytes, as: UTF8.self))
            }
            bytes += fragment
        }
        return nil
    }

    /// One Capabilities Request (0xF3) / Reply (0xE3) exchange for the fragment at `offset`.
    /// AppleSiliconDDC only frames VCP get/set packets, so this one is framed here.
    private static func readFragment(service: IOAVService, offset: Int) -> [UInt8]? {
        let chipAddress = UInt32(ARM64_DDC_7BIT_ADDRESS)
        let dataAddress = UInt32(ARM64_DDC_DATA_ADDRESS)
        var packet: [UInt8] = [0x83, 0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)]
        packet.append(packet.reduce(ARM64_DDC_7BIT_ADDRESS << 1 ^ ARM64_DDC_DATA_ADDRESS, ^))

        for _ in 0 ..< 5 {
            usleep(10000)
            guard IOAVServiceWriteI2C(service, chipAddress, dataAddress, &packet, UInt32(packet.count)) == 0 else { continue }
            usleep(50000)
            var reply = [UInt8](repeating: 0, count: 38)   // header (5) + 32-byte fragment + checksum
            guard IOAVServiceReadI2C(service, chipAddress, dataAddress, &reply, UInt32(reply.count)) == 0 else { continue }
            if let payload = payload(ofReply: reply, offset: offset) { return payload }
        }
        return nil
    }

    /// Validates one Capabilities Reply and returns the string bytes it carries — empty once
    /// `offset` is past the end of the string. Nil for a corrupt or mismatched reply.
    static func payload(ofReply reply: [UInt8], offset: Int) -> [UInt8]? {
        guard reply.count >= 6, reply[0] == 0x6E, reply[1] & 0x80 != 0 else { return nil }
        let length = Int(reply[1] & 0x7F)   // opcode + 2 offset bytes + payload
        guard length >= 3, length + 3 <= reply.count,
              reply[2] == 0xE3,
              Int(reply[3]) << 8 | Int(reply[4]) == offset,
              reply[..<(length + 2)].reduce(0x50, ^) == reply[length + 2] else { return nil }
        return Array(reply[5 ..< length + 2])
    }
}
