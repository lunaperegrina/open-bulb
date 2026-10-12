import XCTest
@testable import TuyaLocal

final class TuyaCryptoTests: XCTestCase {
    func testCRC32KnownVector() {
        // standard check value for CRC-32/ISO-HDLC
        XCTAssertEqual(TuyaCrypto.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testAESECBGoldenVector() {
        // generated with python cryptography, AES-128-ECB, PKCS pad
        let key = Data("0123456789abcdef".utf8)
        let pt = Data(#"{"devId":"dev12345","uid":"dev12345","t":"1700000000","dps":{"20":true}}"#.utf8)
        let ct = TuyaCrypto.aesECBEncrypt(key: key, plaintext: pt)
        XCTAssertEqual(ct.map { String(format: "%02x", $0) }.joined(),
                       "d136205043d3aaf4a21fdd2b78ba3af8227c9d9f5bc46a6aa1c5ab51b7711730ac611841e6ccf777f2231f9ada754818e21928634293482e565ebcabbcab85d2a603e43b8f00ae44bada4be6f66160dd")
        // decrypt roundtrip
        let back = TuyaCrypto.aesECBDecrypt(key: key, ciphertext: ct)
        XCTAssertEqual(back, pt)
    }

    func testAESPadAlwaysAddsBlock() {
        // Tuya pads a full extra block when input is already aligned
        let key = Data("0123456789abcdef".utf8)
        let aligned = Data(repeating: 0x41, count: 32)
        XCTAssertEqual(TuyaCrypto.aesECBEncrypt(key: key, plaintext: aligned).count, 48)
    }

    func testHMACSHA256RFC4231() {
        // RFC 4231 test case 1
        let key = Data(repeating: 0x0b, count: 20)
        let data = Data("Hi There".utf8)
        XCTAssertEqual(TuyaCrypto.hmacSHA256(key: key, data: data).map { String(format: "%02x", $0) }.joined(),
                       "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    func testUDPKey() {
        XCTAssertEqual(TuyaCrypto.udpKey.map { String(format: "%02x", $0) }.joined(),
                       "6c1ec8e2bb9bb59ab50b0daf649b410a")
    }

    func testSessionKeyDerivation() {
        // vector generated with python cryptography
        let key = Data("0123456789abcdef".utf8)
        let local = Data(repeating: 0x61, count: 16)
        let remote = Data(repeating: 0x62, count: 16)
        var xored = Data()
        for (a, b) in zip(local, remote) { xored.append(a ^ b) }
        XCTAssertEqual(xored.map { String(format: "%02x", $0) }.joined(),
                       "03030303030303030303030303030303")
        let session = TuyaCrypto.aesECBEncryptUnpadded(key: key, plaintext: xored)
        XCTAssertEqual(session?.map { String(format: "%02x", $0) }.joined(),
                       "bc264f3f987bbc37422bdc899692f232")
    }
}

final class TuyaFrameTests: XCTestCase {
    func testPackHeartbeatGolden() {
        // python: prefix+seqno=1+cmd=9+payload {"devId":"dev12345","gwId":"dev12345"}
        let payload = Data(#"{"devId":"dev12345","gwId":"dev12345"}"#.utf8)
        let frame = TuyaFrame.pack(TuyaMessage(seqno: 1, cmd: 9, payload: payload))
        XCTAssertEqual(frame.map { String(format: "%02x", $0) }.joined(),
                       "000055aa00000001000000090000002e7b226465764964223a226465763132333435222c2267774964223a226465763132333435227d259617be0000aa55")
    }

    func testPackHMACGolden() {
        let keyA = Array("0123456789abcdef".utf8)
        let keyB = Array("fedcba9876543210".utf8)
        let skey = Data(zip(keyA, keyB).map { $0 ^ $1 })
        let frame = TuyaFrame.pack(TuyaMessage(seqno: 7, cmd: 13, payload: Data(repeating: 0, count: 16)),
                                   hmacKey: skey)
        XCTAssertEqual(frame.map { String(format: "%02x", $0) }.joined(),
                       "000055aa000000070000000d00000034000000000000000000000000000000006feaddec5f9a2fe0f80fab18d671804cf46587a35a467b59a93178395776d3280000aa55")
    }

    func testUnpackReceivedFrame() throws {
        // received frames carry a 4-byte return code before the payload
        var wire = Data()
        wire.appendBE(TuyaFrame.prefix)
        wire.appendBE(3)
        wire.appendBE(0x0a)
        let payload = Data(#"{"dps":{"20":true}}"#.utf8)
        let retcode: [UInt8] = [0, 0, 0, 0]
        let body = Data(retcode) + payload
        wire.appendBE(UInt32(body.count + 8))
        wire.append(body)
        wire.appendBE(TuyaCrypto.crc32(wire))
        wire.appendBE(TuyaFrame.suffix)

        XCTAssertEqual(try TuyaFrame.totalLength(of: wire), wire.count)
        let msg = try TuyaFrame.unpack(wire)
        XCTAssertEqual(msg.cmd, 0x0a)
        XCTAssertEqual(msg.seqno, 3)
        XCTAssertEqual(msg.retcode, 0)
        XCTAssertEqual(String(data: msg.payload, encoding: .utf8), #"{"dps":{"20":true}}"#)
        XCTAssertTrue(msg.crcGood)
    }

    func testUnpackDetectsBadCRC() throws {
        var wire = Data()
        wire.appendBE(TuyaFrame.prefix)
        wire.appendBE(1)
        wire.appendBE(7)
        let body = Data([0, 0, 0, 0]) + Data("{}".utf8)
        wire.appendBE(UInt32(body.count + 8))
        wire.append(body)
        wire.appendBE(0xDEAD_BEEF) // wrong crc
        wire.appendBE(TuyaFrame.suffix)
        let msg = try TuyaFrame.unpack(wire)
        XCTAssertFalse(msg.crcGood)
    }

    func testUnpackHMACVerifies() throws {
        let skey = Data(repeating: 0x33, count: 16)
        let payload = Data("hello".utf8)
        var wire = Data()
        wire.appendBE(TuyaFrame.prefix)
        wire.appendBE(2)
        wire.appendBE(0x0d)
        let body = Data([0, 0, 0, 0]) + payload
        wire.appendBE(UInt32(body.count + 36))
        wire.append(body)
        wire.append(TuyaCrypto.hmacSHA256(key: skey, data: wire))
        wire.appendBE(TuyaFrame.suffix)
        let msg = try TuyaFrame.unpack(wire, hmacKey: skey)
        XCTAssertTrue(msg.crcGood)
        XCTAssertEqual(String(data: msg.payload, encoding: .utf8), "hello")
        // tamper -> HMAC fails
        wire[20] ^= 0xFF
        let bad = try TuyaFrame.unpack(wire, hmacKey: skey)
        XCTAssertFalse(bad.crcGood)
    }

    func test31ControlPayloadGolden() throws {
        // full pipeline: "3.1" + md5slice + base64(ECB(key, padded 32 zero bytes))
        let device = TuyaDevice(config: .init(deviceID: "dev12345", host: "1.2.3.4",
                                              localKey: Data("0123456789abcdef".utf8), version: 3.1))
        let payload = try device.encodePayload(cmd: TuyaCommand.control.rawValue,
                                               json: Data(repeating: 0, count: 32))
        XCTAssertEqual(payload.map { String(format: "%02x", $0) }.joined(),
                       "332e316163373366353962383738343466346243357356326b74456f50555648632f4577423831315175624664704c524b443146523350784d41664e64553363694c6759616b6b785a484e6e436671466a3755")
    }
}

final class BulbModelTests: XCTestCase {
    func testTypeBStateFromDPS() {
        let dps: [String: Any] = ["20": true, "21": "colour", "22": 500, "23": 0,
                                  "24": "012c02fb0336"]
        let state = BulbModel.state(from: dps)!
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.mode, .colour)
        XCTAssertEqual(state.brightness, 0.5, accuracy: 0.01)
        XCTAssertEqual(state.hue, 300, accuracy: 0.1)
        XCTAssertEqual(state.saturation, 0.763, accuracy: 0.001)
        XCTAssertEqual(state.colorValue, 0.822, accuracy: 0.001)
    }

    func testTypeBColourHexRoundtrip() {
        let hex = BulbModel.colourHex(hue: 300, saturation: 0.763, value: 0.822, kind: .typeB)
        XCTAssertEqual(hex, "012c02fb0336")
        let back = BulbModel.parseColourHex(hex, kind: .typeB)
        XCTAssertEqual(back.hue, 300, accuracy: 0.1)
        XCTAssertEqual(back.saturation, 0.763, accuracy: 0.001)
        XCTAssertEqual(back.value, 0.822, accuracy: 0.001)
    }

    func testTypeBDPSPayloadRoundtrip() {
        var state = BulbState()
        state.isOn = true
        state.mode = .white
        state.brightness = 0.35
        state.colorTemperature = 0.8
        state.hue = 120; state.saturation = 0.9; state.colorValue = 0.7
        let dps = BulbModel.dpsPayload(for: state, kind: .typeB)
        XCTAssertEqual(dps["20"] as? Bool, true)
        XCTAssertEqual(dps["22"] as? Int, 357) // 10 + 0.35*990 = 356.5 rounds to 357
        let back = BulbModel.state(from: dps)!
        XCTAssertEqual(back.brightness, 0.35, accuracy: 0.01)
        XCTAssertEqual(back.colorTemperature!, 0.8, accuracy: 0.01)
        XCTAssertEqual(back.hue, 120, accuracy: 0.1)
    }

    func testTypeADetectionAndRoundtrip() {
        let dps: [String: Any] = ["1": true, "2": "colour", "3": 128, "4": 128, "5": "ff000000ffff"]
        let state = BulbModel.state(from: dps)!
        XCTAssertEqual(BulbModel.detectKind(dps: dps), .typeA)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.hue, 0, accuracy: 0.1)
        XCTAssertEqual(state.saturation, 1.0, accuracy: 0.01)
        let out = BulbModel.dpsPayload(for: state, kind: .typeA)
        XCTAssertEqual(out["3"] as? Int, 128)
    }

    func testSetBrightnessRanges() {
        XCTAssertEqual(BulbModel.setBrightness(0, kind: .typeB)["22"] as? Int, 10)
        XCTAssertEqual(BulbModel.setBrightness(1, kind: .typeB)["22"] as? Int, 1000)
        XCTAssertEqual(BulbModel.setBrightness(1, kind: .typeA)["3"] as? Int, 255)
    }

    func testSetColorSwitchesMode() {
        let dps = BulbModel.setColor(hue: 240, saturation: 1, value: 1, kind: .typeB)
        XCTAssertEqual(dps["21"] as? String, "colour")
        XCTAssertEqual(dps["24"] as? String, "00f003e803e8")
    }

    func testHSVRGBConversions() {
        XCTAssertEqual(BulbModel.hsvToRGB(hue: 0, saturation: 1, value: 1).0, 255)
        XCTAssertEqual(BulbModel.hsvToRGB(hue: 0, saturation: 1, value: 1).1, 0)
        let hsv = BulbModel.rgbToHSV(r: 255, g: 0, b: 0)
        XCTAssertEqual(hsv.hue, 0, accuracy: 0.1)
        XCTAssertEqual(hsv.saturation, 1, accuracy: 0.001)
        // roundtrip
        let rgb = BulbModel.hsvToRGB(hue: 210, saturation: 0.8, value: 0.6)
        let back = BulbModel.rgbToHSV(r: Double(rgb.0), g: Double(rgb.1), b: Double(rgb.2))
        XCTAssertEqual(back.hue, 210, accuracy: 0.5)
        XCTAssertEqual(back.saturation, 0.8, accuracy: 0.01)
        XCTAssertEqual(back.value, 0.6, accuracy: 0.01)
    }
}

final class DiscoveryTests: XCTestCase {
    func testParsePlainJSONBroadcast() {
        let json = #"{"ip":"192.168.1.50","gwId":"abcdef123456","active":2,"encrypt":true,"productKey":"keypfce7c","version":"3.3"}"#
        let device = TuyaDiscovery.parse(Data(json.utf8))
        XCTAssertNotNil(device)
        XCTAssertEqual(device?.id, "abcdef123456")
        XCTAssertEqual(device?.ip, "192.168.1.50")
        XCTAssertEqual(device?.version, "3.3")
    }

    func testParseEncryptedBroadcast() {
        // build a 55AA-framed UDP_NEW packet: header + 4 bytes + ECB(udpKey, json)
        let key = TuyaCrypto.udpKey
        let json = Data(#"{"ip":"10.0.0.7","gwId":"feedface","version":"3.4","productKey":"k"}"#.utf8)
        let encrypted = TuyaCrypto.aesECBEncrypt(key: key, plaintext: json)
        var wire = Data()
        wire.appendBE(TuyaFrame.prefix)
        wire.appendBE(0) // seqno
        wire.appendBE(TuyaCommand.udpNew.rawValue)
        let body = Data([0, 0, 0, 0]) + encrypted
        wire.appendBE(UInt32(body.count + 8))
        wire.append(body)
        wire.appendBE(TuyaCrypto.crc32(wire))
        wire.appendBE(TuyaFrame.suffix)
        let device = TuyaDiscovery.parse(wire)
        XCTAssertEqual(device?.id, "feedface")
        XCTAssertEqual(device?.ip, "10.0.0.7")
        XCTAssertEqual(device?.version, "3.4")
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(TuyaDiscovery.parse(Data(repeating: 0x42, count: 20)))
    }
}
