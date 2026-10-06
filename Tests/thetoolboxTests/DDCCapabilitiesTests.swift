import XCTest
@testable import thetoolbox

final class DDCCapabilitiesTests: XCTestCase {
    // Captured from a real DELL P3225QE.
    private let dellP3225QE = "(prot(monitor)type(lcd)model(P3225QE)cmds(01 02 03 07 0C E3 F3)vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60( 1B 0F 11) 87 AA(00 01 04 02) AC AE B2 B6 C6 C8 C9 CA CC(02 03 04 06 09 0A 0D 0E) D6(01 04 05) DC(00 03 05) DF E0(03) E2(00 02 04 0E 12 14) EA(F800 F801) F1 F2 FE FD)mccs_ver(2.1)mswhql(1)) "

    func testParsesDiscreteValuesAdvertisedByARealDellMonitor() {
        let capabilities = DDCCapabilities(parsing: dellP3225QE)

        XCTAssertEqual(capabilities.values(for: .colorPreset), [0x05, 0x08, 0x0B, 0x0C])
        XCTAssertEqual(capabilities.values(for: .displayMode), [0x00, 0x03, 0x05])
        // Leading whitespace inside the value list, and the monitor's own ordering, are preserved.
        XCTAssertEqual(capabilities.values(for: .inputSource), [0x1B, 0x0F, 0x11])
        XCTAssertEqual(capabilities.vcp[0xAA], [0x00, 0x01, 0x04, 0x02])
    }

    func testContinuousFeaturesAreListedWithoutValues() {
        let capabilities = DDCCapabilities(parsing: dellP3225QE)

        XCTAssertEqual(capabilities.vcp[VCPCode.brightness.rawValue], [])
        XCTAssertNil(capabilities.vcp[0x62], "volume is not advertised by this monitor")
        XCTAssertEqual(capabilities.vcp.count, 33)
    }

    func testParsesSixteenBitValues() {
        XCTAssertEqual(DDCCapabilities(parsing: dellP3225QE).vcp[0xEA], [0xF800, 0xF801])
    }

    func testToleratesSpacingCaseAndAVcpnameGroup() {
        let capabilities = DDCCapabilities(parsing: "(vcpname(F0(Custom))VCP ( 10 dc(00 03)14 (01 0b) ))")

        XCTAssertEqual(capabilities.vcp, [0x10: [], 0xDC: [0x00, 0x03], 0x14: [0x01, 0x0B]])
    }

    func testTruncatedStringKeepsWhatWasRead() {
        let capabilities = DDCCapabilities(parsing: "(prot(monitor)vcp(10 12 14(05 08")

        XCTAssertEqual(capabilities.vcp, [0x10: [], 0x12: [], 0x14: [0x05, 0x08]])
    }

    func testStringWithoutAVcpGroupAdvertisesNothing() {
        XCTAssertTrue(DDCCapabilities(parsing: "(prot(monitor)type(lcd))").vcp.isEmpty)
        XCTAssertTrue(DDCCapabilities(parsing: "").vcp.isEmpty)
    }

    // MARK: Capabilities Reply fragments

    private func reply(offset: Int, payload: [UInt8], padTo size: Int = 38) -> [UInt8] {
        var bytes: [UInt8] = [0x6E, 0x80 | UInt8(3 + payload.count), 0xE3, UInt8(offset >> 8), UInt8(offset & 0xFF)] + payload
        bytes.append(bytes.reduce(0x50, ^))
        return bytes + [UInt8](repeating: 0, count: max(0, size - bytes.count))
    }

    func testFragmentPayloadIsExtractedFromAValidReply() {
        let payload = Array("(prot(monitor)".utf8)

        XCTAssertEqual(DDCCapabilities.payload(ofReply: reply(offset: 300, payload: payload), offset: 300), payload)
    }

    func testEmptyFragmentMarksTheEndOfTheString() {
        XCTAssertEqual(DDCCapabilities.payload(ofReply: reply(offset: 306, payload: []), offset: 306), [])
    }

    func testFragmentIsRejectedWhenCorruptOrForAnotherOffset() {
        let valid = reply(offset: 32, payload: Array("vcp(10".utf8))
        var corrupt = valid
        corrupt[6] ^= 0x01

        XCTAssertNil(DDCCapabilities.payload(ofReply: corrupt, offset: 32))
        XCTAssertNil(DDCCapabilities.payload(ofReply: valid, offset: 64))
        XCTAssertNil(DDCCapabilities.payload(ofReply: [UInt8](repeating: 0, count: 38), offset: 0))
        XCTAssertNil(DDCCapabilities.payload(ofReply: Array(valid.prefix(8)), offset: 32))
    }

    // MARK: Color profile names

    func testColorProfileValuesHaveReadableNames() {
        XCTAssertEqual(ColorProfileFeature.presetMode.name(for: 0x03), "Movie")
        XCTAssertEqual(ColorProfileFeature.colorPreset.name(for: 0x05), "6500 K")
        XCTAssertEqual(ColorProfileFeature.colorPreset.name(for: 0x7F), "Preset 0x7F")
    }
}
