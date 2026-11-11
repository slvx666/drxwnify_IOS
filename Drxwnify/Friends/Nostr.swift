import Foundation
import CommonCrypto

/// Событие Nostr (NIP-01).
struct NostrEvent: Hashable {
    var id: String
    var pubkey: String
    var createdAt: Int64
    var kind: Int
    var tags: [[String]]
    var content: String
    var sig: String

    func tag(_ name: String) -> String? { tags.first { $0.count >= 2 && $0[0] == name }?[1] }

    var json: JSONObject {
        ["id": id, "pubkey": pubkey, "created_at": createdAt, "kind": kind, "tags": tags, "content": content, "sig": sig]
    }

    /// id совпадает с содержимым — дёшево; хватает, чтобы узнать уже проверенное событие.
    var hasValidId: Bool { Nostr.idOf(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content) == id }

    var hasValidSignature: Bool {
        guard let m = [UInt8](hexString: id), let p = [UInt8](hexString: pubkey), let s = [UInt8](hexString: sig) else { return false }
        return Secp256k1.verify(m, publicKey: p, signature: s)
    }

    var isValid: Bool { hasValidId && hasValidSignature }

    init(id: String, pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String, sig: String) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }

    init?(json o: JSONObject) {
        guard let id = o.str("id"), let pubkey = o.str("pubkey"), let created = o.int("created_at"), let kind = o.int("kind"),
              let tags = o.arr("tags"), let content = o["content"] as? String, let sig = o.str("sig") else { return nil }
        var parsed: [[String]] = []
        for t in tags {
            guard let list = t as? [Any] else { return nil }
            parsed.append(list.map { ($0 as? String) ?? "\($0)" })
        }
        self.init(id: id, pubkey: pubkey, createdAt: Int64(created), kind: kind, tags: parsed, content: content, sig: sig)
    }
}

/// Nostr для друзей и чатов — перенос `friends/Nostr.kt` (CRITICAL §1.1): id события, подпись, NIP-04, bech32.
enum Nostr {
    /// NIP-78: данные приложения, replaceable по (автор, тег d).
    static let kindAppData = 30078
    /// Имя профиля (kind 0), публикуется, только если пользователь разрешил себя находить.
    static let kindMetadata = 0

    static func sign(privateKey: [UInt8], kind: Int, tags: [[String]], content: String, createdAt: Int64? = nil) -> NostrEvent {
        let pubkey = Secp256k1.publicKey(privateKey).hex
        let created = createdAt ?? Int64(Date().timeIntervalSince1970)
        let id = idOf(pubkey: pubkey, createdAt: created, kind: kind, tags: tags, content: content)
        let sig = Secp256k1.sign([UInt8](hexString: id)!, privateKey: privateKey).hex
        return NostrEvent(id: id, pubkey: pubkey, createdAt: created, kind: kind, tags: tags, content: content, sig: sig)
    }

    static func serialize(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
        var s = "[0,"
        appendJSONString(&s, pubkey)
        s += ",\(createdAt),\(kind),["
        for (i, tag) in tags.enumerated() {
            if i > 0 { s += "," }
            s += "["
            for (j, v) in tag.enumerated() {
                if j > 0 { s += "," }
                appendJSONString(&s, v)
            }
            s += "]"
        }
        s += "],"
        appendJSONString(&s, content)
        s += "]"
        return s
    }

    static func idOf(pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String) -> String {
        Secp256k1.sha256(Array(serialize(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content).utf8)).hex
    }

    /// Экранирование NIP-01: только эти символы, остальное как есть. Как Kotlin: перебор UTF-16 единиц.
    private static func appendJSONString(_ s: inout String, _ value: String) {
        s += "\""
        for u in value.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            case "\u{08}": s += "\\b"
            case "\u{0C}": s += "\\f"
            default:
                if u.value < 0x20 { s += String(format: "\\u%04x", u.value) } else { s.unicodeScalars.append(u) }
            }
        }
        s += "\""
    }

    // MARK: - NIP-04 (AES-256-CBC на секрете ECDH)

    private static let secretLock = NSLock()
    private static var secrets: [String: (sk: [UInt8], secret: [UInt8])] = [:]
    private static var secretOrder: [String] = []

    /// Секрет с ключом собеседника, как в последний раз: математика кривой медленная, а чат просит его на каждое сообщение.
    private static func secretWith(_ privateKey: [UInt8], _ pubkey: String) -> [UInt8]? {
        secretLock.lock()
        if let hit = secrets[pubkey], hit.sk == privateKey {
            secretOrder.removeAll { $0 == pubkey }
            secretOrder.append(pubkey)
            secretLock.unlock()
            return hit.secret
        }
        secretLock.unlock()
        guard let pk = [UInt8](hexString: pubkey), let secret = Secp256k1.sharedSecret(privateKey: privateKey, publicKey: pk) else { return nil }
        secretLock.lock()
        secrets[pubkey] = (privateKey, secret)
        secretOrder.removeAll { $0 == pubkey }
        secretOrder.append(pubkey)
        while secretOrder.count > 64 { secrets[secretOrder.removeFirst()] = nil }
        secretLock.unlock()
        return secret
    }

    private static func aes(_ op: Int, key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(moved))
    }

    static func encrypt(privateKey: [UInt8], to pubkey: String, plain: String, iv: [UInt8]? = nil) -> String? {
        guard let key = secretWith(privateKey, pubkey) else { return nil }
        let v = iv ?? Secp256k1.randomBytes(16)
        guard let ct = aes(kCCEncrypt, key: key, iv: v, data: Array(plain.utf8)) else { return nil }
        return Data(ct).base64EncodedString() + "?iv=" + Data(v).base64EncodedString()
    }

    static func decrypt(privateKey: [UInt8], from pubkey: String, payload: String) -> String? {
        let parts = payload.components(separatedBy: "?iv=")
        guard parts.count == 2,
              let data = Data(base64Encoded: parts[0], options: .ignoreUnknownCharacters),
              let iv = Data(base64Encoded: parts[1], options: .ignoreUnknownCharacters),
              let key = secretWith(privateKey, pubkey),
              let plain = aes(kCCDecrypt, key: key, iv: Array(iv), data: Array(data)) else { return nil }
        return String(bytes: plain, encoding: .utf8)
    }

    // MARK: - Bech32 (npub / nsec, NIP-19)

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

    private static func polymod(_ values: [Int]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 { chk ^= generator[i] }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [Int] {
        let codes = hrp.unicodeScalars.map { Int($0.value) }
        return codes.map { $0 >> 5 } + [0] + codes.map { $0 & 31 }
    }

    private static func convertBits(_ data: [Int], from: Int, to: Int, pad: Bool) -> [Int]? {
        var acc = 0, bits = 0
        var out: [Int] = []
        let maxv = (1 << to) - 1
        for value in data {
            if value >> from != 0 { return nil }
            acc = (acc << from) | value
            bits += from
            while bits >= to {
                bits -= to
                out.append((acc >> bits) & maxv)
            }
        }
        if pad {
            if bits > 0 { out.append((acc << (to - bits)) & maxv) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }

    static func bech32Encode(hrp: String, data: [UInt8]) -> String {
        let values = convertBits(data.map { Int($0) }, from: 8, to: 5, pad: true)!
        let mod = polymod(hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ 1
        let checksum = (0..<6).map { Int((mod >> UInt32(5 * (5 - $0))) & 31) }
        return hrp + "1" + String((values + checksum).map { charset[$0] })
    }

    static func bech32Decode(_ text: String) -> (hrp: String, data: [UInt8])? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let pos = s.lastIndex(of: "1") else { return nil }
        let p = s.distance(from: s.startIndex, to: pos)
        if p < 1 || p + 7 > s.count { return nil }
        let hrp = String(s[..<pos])
        var values: [Int] = []
        for c in s[s.index(after: pos)...] {
            guard let i = charset.firstIndex(of: c) else { return nil }
            values.append(i)
        }
        if polymod(hrpExpand(hrp) + values) != 1 { return nil }
        guard let eight = convertBits(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else { return nil }
        return (hrp, eight.map { UInt8($0) })
    }

    static func npub(_ pubkeyHex: String) -> String? { [UInt8](hexString: pubkeyHex).map { bech32Encode(hrp: "npub", data: $0) } }

    /// Ключ из npub или голого hex.
    static func pubkey(fromNpub text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count == 64, let b = [UInt8](hexString: t), Secp256k1.isValidPublicKey(b) { return t.lowercased() }
        guard let (hrp, data) = bech32Decode(t), hrp == "npub", data.count == 32 else { return nil }
        return data.hex
    }
}
