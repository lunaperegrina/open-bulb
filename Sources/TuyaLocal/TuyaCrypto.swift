import Foundation
import CryptoKit
import CommonCrypto

/// Crypto helpers for the Tuya local protocol.
/// AES is 128-bit with the device's 16-byte `local_key` (or the negotiated
/// session key on 3.4+). ECB is not exposed by CryptoKit, so it goes through
/// CommonCrypto.
public enum TuyaCrypto {
    /// AES-128-ECB encrypt with PKCS#7-style padding (Tuya pads every block,
    /// i.e. a full extra block when the input is already block-aligned).
    public static func aesECBEncrypt(key: Data, plaintext: Data) -> Data {
        precondition(key.count == 16, "local_key must be 16 bytes")
        let padded = pkcs7Pad(plaintext, blockSize: 16)
        var out = Data(count: padded.count)
        var outLen: Int = 0
        let status = padded.withUnsafeBytes { pIn -> CCCryptorStatus in
            out.withUnsafeMutableBytes { pOut -> CCCryptorStatus in
                key.withUnsafeBytes { pKey -> CCCryptorStatus in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            pKey.baseAddress, kCCKeySizeAES128,
                            nil, // ECB: no IV
                            pIn.baseAddress, padded.count,
                            pOut.baseAddress, pOut.count, &outLen)
                }
            }
        }
        precondition(status == kCCSuccess, "CCCrypt encrypt failed: \(status)")
        return out.prefix(outLen)
    }

    /// AES-128-ECB decrypt; strips padding. Returns nil when the input is not
    /// block-aligned or the padding byte is out of range (wrong key / garbage).
    public static func aesECBDecrypt(key: Data, ciphertext: Data) -> Data? {
        precondition(key.count == 16, "local_key must be 16 bytes")
        guard ciphertext.count % 16 == 0, !ciphertext.isEmpty else { return nil }
        var out = Data(count: ciphertext.count)
        var outLen: Int = 0
        let status = ciphertext.withUnsafeBytes { pIn -> CCCryptorStatus in
            out.withUnsafeMutableBytes { pOut -> CCCryptorStatus in
                key.withUnsafeBytes { pKey -> CCCryptorStatus in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            pKey.baseAddress, kCCKeySizeAES128,
                            nil,
                            pIn.baseAddress, ciphertext.count,
                            pOut.baseAddress, pOut.count, &outLen)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out = out.prefix(outLen)
        guard let unpadded = pkcs7Unpad(out) else { return nil }
        return unpadded
    }

    static func pkcs7Pad(_ data: Data, blockSize: Int) -> Data {
        let padNum = blockSize - (data.count % blockSize) // always 1...16
        return data + Data(repeating: UInt8(padNum), count: padNum)
    }

    static func pkcs7Unpad(_ data: Data) -> Data? {
        guard let last = data.last else { return nil }
        guard last >= 1, last <= 16, data.count >= Int(last) else { return nil }
        return data.prefix(data.count - Int(last))
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    /// IEEE CRC-32 (reflected, as used by zlib/binascii.crc32).
    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
    }

    /// Shared key used to decrypt Tuya UDP broadcast payloads
    /// (credit: tuya-convert). MD5("yGAdlopoPVldABfn") as raw digest.
    public static let udpKey = md5(Data("yGAdlopoPVldABfn".utf8))
}
