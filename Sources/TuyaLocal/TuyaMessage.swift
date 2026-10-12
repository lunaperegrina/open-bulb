import Foundation
import CryptoKit

/// Tuya local protocol framing (the "55AA" format used by 3.1-3.4).
///
/// Frame layout (all integers big-endian):
///
///     +--------+-------+-----+--------+---------+-----+--------+
///     | 0x000055AA | seqno | cmd | length | payload | crc | 0x0000AA55 |
///     +--------+-------+-----+--------+---------+-----+--------+
///
/// `length` counts payload + trailer (4-byte CRC32 or 32-byte HMAC-SHA256,
/// + 4-byte suffix). Received frames carry a 4-byte return code at the start
/// of the payload, which this parser strips.
public enum TuyaCommand: UInt32 {
    case sessionKeyNegStart = 3
    case sessionKeyNegResponse = 4
    case sessionKeyNegFinish = 5
    case control = 7
    case status = 8
    case heartbeat = 9
    case dpQuery = 0x0a
    case controlNew = 0x0d   // 3.4+ uses this for CONTROL
    case dpQueryNew = 0x10   // 3.4+ uses this for DP_QUERY
    case updateDPS = 0x12
    case udpNew = 0x13       // encrypted UDP broadcast on port 6667
}

public enum TuyaMessageError: Error, CustomStringConvertible, Equatable {
    case badPrefix(UInt32)
    case tooShortForHeader
    case payloadTooLarge(Int)
    case incompletePayload(need: Int, have: Int)
    case badCRC(expected: UInt32, got: UInt32)
    case badHMAC
    case badSuffix
    case gcmFailed(String)

    public var description: String {
        switch self {
        case .badPrefix(let p): return "bad prefix 0x\(String(p, radix: 16)) (not 55AA)"
        case .tooShortForHeader: return "not enough data for header"
        case .payloadTooLarge(let n): return "frame claims \(n) bytes payload (over sanity cap)"
        case .incompletePayload(let need, let have): return "incomplete payload: need \(need), have \(have)"
        case .badCRC(let e, let g): return "CRC mismatch: expected 0x\(String(e, radix: 16)), got 0x\(String(g, radix: 16))"
        case .badHMAC: return "HMAC mismatch"
        case .badSuffix: return "bad frame suffix"
        case .gcmFailed(let why): return "GCM error: \(why)"
        }
    }
}

public struct TuyaMessage {
    public var seqno: UInt32
    public var cmd: UInt32
    public var retcode: UInt32
    public var payload: Data
    public var crcGood: Bool

    public init(seqno: UInt32, cmd: UInt32, retcode: UInt32 = 0, payload: Data, crcGood: Bool = true) {
        self.seqno = seqno
        self.cmd = cmd
        self.retcode = retcode
        self.payload = payload
        self.crcGood = crcGood
    }
}

public enum TuyaFrame {
    public static let prefix: UInt32 = 0x0000_55AA
    public static let suffix: UInt32 = 0x0000_AA55
    static let prefixBytes = Data([0x00, 0x00, 0x55, 0xAA])
    static let suffixBytes = Data([0x00, 0x00, 0xAA, 0x55])
    static let headerLength = 16
    /// Corrupt/desynced streams can declare absurd lengths; devices have tiny
    /// RAM, so reject anything beyond this (mirrors tinytuya MAX_PAYLOAD_LENGTH).
    public static let maxPayloadLength = 8192

    /// Pack a message for sending. When `hmacKey` is set (protocol 3.4+) the
    /// trailer is HMAC-SHA256 instead of CRC32.
    public static func pack(_ message: TuyaMessage, hmacKey: Data? = nil) -> Data {
        let trailerLength = hmacKey != nil ? 32 + 4 : 4 + 4
        let length = UInt32(message.payload.count + trailerLength)

        var out = Data(capacity: TuyaFrame.headerLength + message.payload.count + trailerLength)
        out.appendBE(TuyaFrame.prefix)
        out.appendBE(message.seqno)
        out.appendBE(message.cmd)
        out.appendBE(length)
        out.append(message.payload)
        if let hmacKey {
            out.append(TuyaCrypto.hmacSHA256(key: hmacKey, data: out))
            out.appendBE(TuyaFrame.suffix)
        } else {
            out.appendBE(TuyaCrypto.crc32(out))
            out.appendBE(TuyaFrame.suffix)
        }
        return out
    }

    /// Parse a complete frame already read from the wire. `hmacKey` must be
    /// provided for 3.4+ frames.
    public static func unpack(_ data: Data, hmacKey: Data? = nil) throws -> TuyaMessage {
        guard data.count >= TuyaFrame.headerLength else {
            throw TuyaMessageError.tooShortForHeader
        }
        let prefix = data.readBE32(0)
        guard prefix == TuyaFrame.prefix else { throw TuyaMessageError.badPrefix(prefix) }
        let seqno = data.readBE32(4)
        let cmd = data.readBE32(8)
        let length = Int(data.readBE32(12))
        guard length <= TuyaFrame.maxPayloadLength else {
            throw TuyaMessageError.payloadTooLarge(length)
        }

        let trailerLength = hmacKey != nil ? 32 + 4 : 4 + 4
        let totalNeeded = TuyaFrame.headerLength + length
        guard data.count >= totalNeeded else {
            throw TuyaMessageError.incompletePayload(need: totalNeeded, have: data.count)
        }

        // payload region = header ..< header+length; its last bytes are the trailer
        let bodyStart = TuyaFrame.headerLength
        let bodyEnd = totalNeeded
        var body = data.subdata(in: bodyStart..<bodyEnd)

        // strip trailer
        let (crc, suffix): (Data, UInt32)
        let trailer = body.suffix(trailerLength)
        body = body.prefix(body.count - trailerLength)
        if hmacKey != nil {
            crc = trailer.prefix(32)
            suffix = trailer.readBE32(32)
        } else {
            crc = trailer.prefix(4)
            suffix = trailer.readBE32(4)
        }
        guard suffix == TuyaFrame.suffix else { throw TuyaMessageError.badSuffix }

        // verify checksum over header + payload (retcode included for received frames)
        var signed = data.prefix(TuyaFrame.headerLength)
        signed.append(body)
        var crcGood = false
        if let hmacKey {
            crcGood = TuyaCrypto.hmacSHA256(key: hmacKey, data: signed) == crc
        } else {
            crcGood = TuyaCrypto.crc32(signed) == crc.readBE32(0)
        }

        // received frames start with a 4-byte return code
        guard body.count >= 4 else {
            return TuyaMessage(seqno: seqno, cmd: cmd, retcode: 0, payload: Data(), crcGood: crcGood)
        }
        let retcode = body.readBE32(0)
        let payload = body.suffix(from: 4)
        return TuyaMessage(seqno: seqno, cmd: cmd, retcode: retcode, payload: payload, crcGood: crcGood)
    }

    /// Figure out how many total bytes the frame starting at `data` needs,
    /// so a receive loop knows how much more to read.
    public static func totalLength(of data: Data) throws -> Int {
        guard data.count >= TuyaFrame.headerLength else {
            throw TuyaMessageError.tooShortForHeader
        }
        let prefix = data.readBE32(0)
        guard prefix == TuyaFrame.prefix else { throw TuyaMessageError.badPrefix(prefix) }
        let length = Int(data.readBE32(12))
        guard length <= TuyaFrame.maxPayloadLength else {
            throw TuyaMessageError.payloadTooLarge(length)
        }
        return TuyaFrame.headerLength + length
    }

    // MARK: - 6699 frames (protocol 3.5)
    //
    // Layout: prefix(4) 0x00006699 + unknown(2) + seqno(4) + cmd(4) + length(4)
    //         + iv(12) + AES-GCM ciphertext + tag(16) + suffix(4) 0x00009966
    // `length` counts iv + ciphertext + tag (not the suffix); the header minus
    // its prefix is the GCM additional authenticated data.

    public static let prefix6699: UInt32 = 0x0000_6699
    static let suffix6699Bytes = Data([0x00, 0x00, 0x99, 0x66])
    static let prefix6699Bytes = Data([0x00, 0x00, 0x66, 0x99])
    public static let headerLength6699 = 18

    public static func pack6699(_ message: TuyaMessage, key: Data, iv: Data) throws -> Data {
        guard iv.count == 12 else { throw TuyaMessageError.gcmFailed("iv must be 12 bytes") }
        var header = Data()
        header.appendBE(TuyaFrame.prefix6699)
        header.append(0)
        header.append(0)
        header.appendBE(message.seqno)
        header.appendBE(message.cmd)
        header.appendBE(UInt32(message.payload.count + 12 + 16))
        do {
            let sealed = try AES.GCM.seal(message.payload, using: SymmetricKey(data: key),
                                          nonce: AES.GCM.Nonce(data: iv),
                                          authenticating: header.suffix(14))
            var frame = header
            frame.append(iv)
            frame.append(sealed.ciphertext)
            frame.append(sealed.tag)
            frame.append(TuyaFrame.suffix6699Bytes)
            return frame
        } catch {
            throw TuyaMessageError.gcmFailed("\(error)")
        }
    }

    /// Total wire size of the 6699 frame starting at `data`.
    public static func totalLength6699(of data: Data) throws -> Int {
        guard data.count >= TuyaFrame.headerLength6699 else {
            throw TuyaMessageError.tooShortForHeader
        }
        guard data.readBE32(0) == TuyaFrame.prefix6699 else {
            throw TuyaMessageError.badPrefix(data.readBE32(0))
        }
        let length = Int(data.readBE32(14))
        guard length <= TuyaFrame.maxPayloadLength else {
            throw TuyaMessageError.payloadTooLarge(length)
        }
        return TuyaFrame.headerLength6699 + length + 4
    }

    /// Parse and GCM-decrypt a complete 6699 frame. The payload comes back
    /// already decrypted (for device responses it typically starts with a
    /// 4-byte return code inside the plaintext).
    public static func unpack6699(_ data: Data, key: Data) throws -> TuyaMessage {
        let total = try TuyaFrame.totalLength6699(of: data)
        guard data.count >= total else {
            throw TuyaMessageError.incompletePayload(need: total, have: data.count)
        }
        let seqno = data.readBE32(6)
        let cmd = data.readBE32(10)
        let body = data.subdata(in: TuyaFrame.headerLength6699..<(total - 4))
        guard data.subdata(in: (total - 4)..<total) == TuyaFrame.suffix6699Bytes else {
            throw TuyaMessageError.badSuffix
        }
        guard body.count > 12 + 16 else { throw TuyaMessageError.tooShortForHeader }
        let iv = body.prefix(12)
        let tag = body.suffix(16)
        let ciphertext = body.subdata(in: 12..<(body.count - 16))
        let aad = data.subdata(in: 4..<TuyaFrame.headerLength6699)
        do {
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                               ciphertext: ciphertext, tag: tag)
            let plain = try AES.GCM.open(sealed, using: SymmetricKey(data: key),
                                         authenticating: aad)
            return TuyaMessage(seqno: seqno, cmd: cmd, retcode: 0, payload: plain, crcGood: true)
        } catch {
            throw TuyaMessageError.gcmFailed("decrypt/authentication failed")
        }
    }
}

extension Data {
    mutating func appendBE(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    func readBE32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16)
            | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }
}
