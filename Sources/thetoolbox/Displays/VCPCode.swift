import Foundation

/// VESA MCCS Virtual Control Panel (VCP) feature codes used over DDC/CI.
enum VCPCode: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
    case audioVolume = 0x62
    case audioMute = 0x8D
    case inputSource = 0x60
    case redGain = 0x16
    case greenGain = 0x18
    case blueGain = 0x1A
    case powerMode = 0xD6
}
