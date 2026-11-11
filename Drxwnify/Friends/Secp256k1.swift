import Foundation
import CommonCrypto
import Security

/// Неотрицательное целое на массиве `UInt64` (младшая часть первой). Только то, что нужно secp256k1.
struct BigUInt: Equatable {
    var limbs: [UInt64]

    init(_ limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    init(_ v: UInt64) { self.init([v]) }

    /// Из 32 байт big-endian (или любой длины).
    init(bytes: [UInt8]) {
        var out: [UInt64] = []
        var i = bytes.count
        while i > 0 {
            var w: UInt64 = 0
            let start = max(0, i - 8)
            for b in bytes[start..<i] { w = (w << 8) | UInt64(b) }
            out.append(w)
            i = start
        }
        self.init(out)
    }

    init?(hex: String) {
        let clean = hex.count % 2 == 1 ? "0" + hex : hex
        guard let b = [UInt8](hexString: clean) else { return nil }
        self.init(bytes: b)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    func bit(_ i: Int) -> Bool {
        let w = i / 64
        guard w < limbs.count else { return false }
        return (limbs[w] >> UInt64(i % 64)) & 1 == 1
    }

    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    /// 32 байта big-endian (старшие лишние отбрасываются).
    var bytes32: [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        for (wi, w) in limbs.prefix(4).enumerated() {
            for bi in 0..<8 { out[31 - (wi * 8 + bi)] = UInt8(truncatingIfNeeded: w >> UInt64(bi * 8)) }
        }
        return out
    }

    static func < (a: BigUInt, b: BigUInt) -> Bool { compare(a, b) < 0 }
    static func >= (a: BigUInt, b: BigUInt) -> Bool { compare(a, b) >= 0 }

    static func compare(_ a: BigUInt, _ b: BigUInt) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        var i = a.limbs.count - 1
        while i >= 0 {
            if a.limbs[i] != b.limbs[i] { return a.limbs[i] < b.limbs[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        let n = max(a.limbs.count, b.limbs.count)
        var out = [UInt64](repeating: 0, count: n + 1)
        var carry: UInt64 = 0
        for i in 0..<n {
            let x = i < a.limbs.count ? a.limbs[i] : 0
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (s1, o1) = x.addingReportingOverflow(y)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        out[n] = carry
        return BigUInt(out)
    }

    /// a − b, требуется a ≥ b.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = a.limbs
        var borrow: UInt64 = 0
        for i in 0..<out.count {
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (d1, o1) = out[i].subtractingReportingOverflow(y)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt(out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt([]) }
        var out = [UInt64](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let x = a.limbs[i]
            for j in 0..<b.limbs.count {
                let (hi, lo) = x.multipliedFullWidth(by: b.limbs[j])
                let (s1, o1) = out[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                out[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            out[i + b.limbs.count] = carry
        }
        return BigUInt(out)
    }

    /// Старшие limbs начиная с `from` и младшие до него.
    func split(at from: Int) -> (lo: BigUInt, hi: BigUInt) {
        if limbs.count <= from { return (self, BigUInt([])) }
        return (BigUInt(Array(limbs[0..<from])), BigUInt(Array(limbs[from...])))
    }
}

/// Остатки по модулю вида 2²⁵⁶ − c (поле p и порядок n у secp256k1): свёртка старшей части через c.
struct Modulus {
    let m: BigUInt
    /// 2²⁵⁶ − m
    let c: BigUInt

    init(hex: String) {
        m = BigUInt(hex: hex)!
        let two256 = BigUInt([0, 0, 0, 0, 1])
        c = two256 - m
    }

    func reduce(_ x: BigUInt) -> BigUInt {
        var v = x
        while v.limbs.count > 4 {
            let (lo, hi) = v.split(at: 4)
            v = lo + hi * c
        }
        while v >= m { v = v - m }
        return v
    }

    func add(_ a: BigUInt, _ b: BigUInt) -> BigUInt { reduce(a + b) }
    func sub(_ a: BigUInt, _ b: BigUInt) -> BigUInt { a >= b ? a - b : (a + m) - b }
    func mul(_ a: BigUInt, _ b: BigUInt) -> BigUInt { reduce(a * b) }
    func neg(_ a: BigUInt) -> BigUInt { a.isZero ? a : m - a }

    func pow(_ base: BigUInt, _ exp: BigUInt) -> BigUInt {
        var result = BigUInt(1)
        let b = reduce(base)
        var i = exp.bitWidth - 1
        while i >= 0 {
            result = mul(result, result)
            if exp.bit(i) { result = mul(result, b) }
            i -= 1
        }
        return result
    }

    /// Обратный по малой теореме Ферма (m простое).
    func inverse(_ a: BigUInt) -> BigUInt { pow(a, m - BigUInt(2)) }
}

/// Кривая secp256k1 так, как её использует Nostr: x-only ключи, подписи Schnorr BIP-340, общий секрет ECDH для NIP-04.
/// Перенос `friends/Secp256k1.kt`: якобиевы координаты, те же формулы.
enum Secp256k1 {
    static let P = Modulus(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F")
    static let N = Modulus(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")
    private static let GX = BigUInt(hex: "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798")!
    private static let GY = BigUInt(hex: "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8")!

    private struct Jac {
        var x: BigUInt
        var y: BigUInt
        var z: BigUInt
        var infinity: Bool { z.isZero }
    }

    private static let G = Jac(x: GX, y: GY, z: BigUInt(1))
    private static let INF = Jac(x: BigUInt(1), y: BigUInt(1), z: BigUInt([]))

    private static func double(_ p: Jac) -> Jac {
        if p.infinity || p.y.isZero { return INF }
        let f = P
        let ysq = f.mul(p.y, p.y)
        let s = f.mul(f.mul(BigUInt(4), p.x), ysq)
        let m = f.mul(f.mul(BigUInt(3), p.x), p.x)
        let nx = f.sub(f.mul(m, m), f.add(s, s))
        let ny = f.sub(f.mul(m, f.sub(s, nx)), f.mul(f.mul(BigUInt(8), ysq), ysq))
        let nz = f.mul(f.mul(BigUInt(2), p.y), p.z)
        return Jac(x: nx, y: ny, z: nz)
    }

    private static func add(_ p: Jac, _ q: Jac) -> Jac {
        if p.infinity { return q }
        if q.infinity { return p }
        let f = P
        let z1z1 = f.mul(p.z, p.z)
        let z2z2 = f.mul(q.z, q.z)
        let u1 = f.mul(p.x, z2z2)
        let u2 = f.mul(q.x, z1z1)
        let s1 = f.mul(f.mul(p.y, q.z), z2z2)
        let s2 = f.mul(f.mul(q.y, p.z), z1z1)
        if u1 == u2 { return s1 == s2 ? double(p) : INF }
        let h = f.sub(u2, u1)
        let r = f.sub(s2, s1)
        let h2 = f.mul(h, h)
        let h3 = f.mul(h2, h)
        let u1h2 = f.mul(u1, h2)
        let nx = f.sub(f.sub(f.mul(r, r), h3), f.add(u1h2, u1h2))
        let ny = f.sub(f.mul(r, f.sub(u1h2, nx)), f.mul(s1, h3))
        let nz = f.mul(f.mul(h, p.z), q.z)
        return Jac(x: nx, y: ny, z: nz)
    }

    private static func multiply(_ p: Jac, _ k: BigUInt) -> Jac {
        var result = INF
        var addend = p
        for i in 0..<k.bitWidth {
            if k.bit(i) { result = add(result, addend) }
            addend = double(addend)
        }
        return result
    }

    private static func affine(_ p: Jac) -> (BigUInt, BigUInt)? {
        if p.infinity { return nil }
        let f = P
        let zi = f.inverse(p.z)
        let zi2 = f.mul(zi, zi)
        return (f.mul(p.x, zi2), f.mul(f.mul(p.y, zi2), zi))
    }

    /// Точка с данным x и чётным y (BIP-340 lift_x); nil, если такой нет.
    private static func liftX(_ x: BigUInt) -> Jac? {
        let f = P
        if x >= f.m { return nil }
        let c = f.add(f.mul(f.mul(x, x), x), BigUInt(7))
        let y = f.pow(c, (f.m + BigUInt(1)).shiftedRight2)
        if f.mul(y, y) != c { return nil }
        return Jac(x: x, y: y.bit(0) ? f.m - y : y, z: BigUInt(1))
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &b) != errSecSuccess {
            for i in 0..<n { b[i] = UInt8.random(in: 0...255) }
        }
        return b
    }

    static func newPrivateKey() -> [UInt8] {
        while true {
            let b = randomBytes(32)
            let d = BigUInt(bytes: b)
            if !d.isZero && d < N.m { return b }
        }
    }

    static func publicKey(_ privateKey: [UInt8]) -> [UInt8] {
        affine(multiply(G, BigUInt(bytes: privateKey)))!.0.bytes32
    }

    static func sign(_ message: [UInt8], privateKey: [UInt8], auxRand: [UInt8]? = nil) -> [UInt8] {
        let d0 = BigUInt(bytes: privateKey)
        let (px, py) = affine(multiply(G, d0))!
        let d = py.bit(0) ? N.m - d0 : d0
        let aux = auxRand ?? randomBytes(32)
        let t = zip(d.bytes32, taggedHash("BIP0340/aux", aux)).map { $0 ^ $1 }
        let k0 = N.reduce(BigUInt(bytes: taggedHash("BIP0340/nonce", t + px.bytes32 + message)))
        precondition(!k0.isZero)
        let (rx, ry) = affine(multiply(G, k0))!
        let k = ry.bit(0) ? N.m - k0 : k0
        let e = N.reduce(BigUInt(bytes: taggedHash("BIP0340/challenge", rx.bytes32 + px.bytes32 + message)))
        return rx.bytes32 + N.add(k, N.mul(e, d)).bytes32
    }

    static func verify(_ message: [UInt8], publicKey: [UInt8], signature: [UInt8]) -> Bool {
        guard signature.count == 64, publicKey.count == 32, let pk = liftX(BigUInt(bytes: publicKey)) else { return false }
        let r = BigUInt(bytes: Array(signature[0..<32]))
        let s = BigUInt(bytes: Array(signature[32..<64]))
        if r >= P.m || s >= N.m { return false }
        let e = N.reduce(BigUInt(bytes: taggedHash("BIP0340/challenge", Array(signature[0..<32]) + publicKey + message)))
        let point = add(multiply(G, s), multiply(pk, N.neg(e)))
        guard let (x, y) = affine(point) else { return false }
        return !y.bit(0) && x == r
    }

    /// x от d·Q — общий секрет двух ключей (NIP-04), 32 байта без хеширования.
    static func sharedSecret(privateKey: [UInt8], publicKey: [UInt8]) -> [UInt8]? {
        guard let q = liftX(BigUInt(bytes: publicKey)), let (x, _) = affine(multiply(q, BigUInt(bytes: privateKey))) else { return nil }
        return x.bytes32
    }

    static func isValidPublicKey(_ publicKey: [UInt8]) -> Bool {
        publicKey.count == 32 && liftX(BigUInt(bytes: publicKey)) != nil
    }

    private static func taggedHash(_ tag: String, _ data: [UInt8]) -> [UInt8] {
        let tagHash = sha256(Array(tag.utf8))
        return sha256(tagHash + tagHash + data)
    }

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBufferPointer { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &out) }
        return out
    }
}

extension BigUInt {
    /// self >> 2 (нужно только для (p+1)/4).
    var shiftedRight2: BigUInt {
        var out = limbs
        for i in 0..<out.count {
            let next: UInt64 = i + 1 < out.count ? out[i + 1] : 0
            out[i] = (out[i] >> 2) | (next << 62)
        }
        return BigUInt(out)
    }
}

extension Array where Element == UInt8 {
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hexString.count / 2)
        var it = hexString.unicodeScalars.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let hi = Self.nibble(a), let lo = Self.nibble(b) else { return nil }
            out.append(hi << 4 | lo)
        }
        self = out
    }

    private static func nibble(_ c: Unicode.Scalar) -> UInt8? {
        switch c.value {
        case 48...57: return UInt8(c.value - 48)
        case 65...70: return UInt8(c.value - 55)
        case 97...102: return UInt8(c.value - 87)
        default: return nil
        }
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
