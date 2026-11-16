import Foundation
import CommonCrypto

/// Photoshop 远程连接使用的加密：3DES-CBC + PKCS7
/// 参数取自 Adobe 官方 generator-core/lib/ps_crypto.js：
///   SALT         = "Adobe Photoshop"
///   ITERATIONS   = 1000
///   ALGORITHM    = des-ede3-cbc (key 24 字节)
///   DIGEST       = sha1
///   IV           = 000000005d260000   ← 注意：不是全零
enum PSCryptoError: Error {
    case keyDerivation(Int32)
    case encryptFailed
    case decryptFailed
}

struct PSCrypto {
    static let saltString = "Adobe Photoshop"
    static let iterations: UInt32 = 1000
    static let keyLength = 24
    static let iv: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x5d, 0x26, 0x00, 0x00]

    private let key: [UInt8]

    init(password: String) throws {
        var derived = [UInt8](repeating: 0, count: PSCrypto.keyLength)
        let saltBytes = Array(PSCrypto.saltString.utf8)
        let passwordBytes = Array(password.utf8)
        let pwLen = passwordBytes.count

        let status: Int32 = passwordBytes.withUnsafeBufferPointer { pwBuf in
            saltBytes.withUnsafeBufferPointer { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(pwBuf.baseAddress)?.assumingMemoryBound(to: Int8.self),
                    pwLen,
                    saltBuf.baseAddress,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    PSCrypto.iterations,
                    &derived,
                    derived.count
                )
            }
        }

        guard status == kCCSuccess else {
            throw PSCryptoError.keyDerivation(status)
        }
        self.key = derived
    }

    func encrypt(_ data: Data) throws -> Data {
        try crypt(data, operation: CCOperation(kCCEncrypt))
    }

    func decrypt(_ data: Data) throws -> Data {
        try crypt(data, operation: CCOperation(kCCDecrypt))
    }

    private func crypt(_ data: Data, operation: CCOperation) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let outCapacity = data.count + kCCBlockSize3DES
        var out = Data(count: outCapacity)
        var outLength = 0

        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            data.withUnsafeBytes { inBytes -> CCCryptorStatus in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithm3DES),
                    CCOptions(kCCOptionPKCS7Padding),
                    key,
                    key.count,
                    PSCrypto.iv,
                    inBytes.baseAddress,
                    data.count,
                    outBytes.baseAddress,
                    outCapacity,
                    &outLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCEncrypt)
                ? PSCryptoError.encryptFailed
                : PSCryptoError.decryptFailed
        }
        return out.prefix(outLength)
    }
}
