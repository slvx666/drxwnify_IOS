import Foundation

/// Протокол друзей побайтно (CRITICAL §1.1): векторы из scripts/nostr_vectors.py (эталон BIP-340 на Python + openssl).
func testNostr(vectors path: String) {
    section("Nostr: secp256k1, BIP-340, NIP-01, NIP-04, NIP-19")
    guard let data = FileManager.default.contents(atPath: path), let root = JSON.object(data) else {
        expect(false, "векторы \(path)")
        return
    }
    expect(Secp256k1.publicKey([UInt8](hexString: "00" + String(repeating: "0", count: 60) + "01")!).hex
           == "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798", "pubkey(1) = G.x")
    for (i, v) in root.objects("sigs").enumerated() {
        let sk = [UInt8](hexString: v.str("sk")!)!
        let msg = [UInt8](hexString: v.str("msg")!)!
        let aux = [UInt8](hexString: v.str("aux")!)!
        let pk = Secp256k1.publicKey(sk)
        expect(pk.hex == v.str("pk"), "вектор \(i): открытый ключ")
        let sig = Secp256k1.sign(msg, privateKey: sk, auxRand: aux)
        expect(sig.hex == v.str("sig"), "вектор \(i): подпись совпадает с эталоном")
        expect(Secp256k1.verify(msg, publicKey: pk, signature: sig), "вектор \(i): своя подпись проверяется")
        var broken = sig
        broken[63] ^= 1
        expect(!Secp256k1.verify(msg, publicKey: pk, signature: broken), "вектор \(i): испорченная подпись отвергается")
    }
    // Эталонный вектор BIP-340 №0 из спецификации (проверка самих векторов).
    expect(root.objects("sigs").first?.str("sig") == "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0",
           "эталон BIP-340 №0")

    let e = root.obj("ecdh")!
    let a = [UInt8](hexString: e.str("a")!)!
    let b = [UInt8](hexString: e.str("b")!)!
    expect(Secp256k1.sharedSecret(privateKey: a, publicKey: Secp256k1.publicKey(b))?.hex == e.str("secret"), "ECDH: секрет как у эталона")
    expect(Secp256k1.sharedSecret(privateKey: b, publicKey: Secp256k1.publicKey(a))?.hex == e.str("secret"), "ECDH: симметричен")
    let iv = [UInt8](hexString: e.str("iv")!)!
    let enc = Nostr.encrypt(privateKey: a, to: Secp256k1.publicKey(b).hex, plain: e.str("plain")!, iv: iv)
    expect(enc == e.str("content"), "NIP-04: шифртекст как у openssl")
    expect(Nostr.decrypt(privateKey: b, from: Secp256k1.publicKey(a).hex, payload: e.str("content")!) == e.str("plain"), "NIP-04: расшифровка")

    let ev = root.obj("event")!
    let tags = (ev.arr("tags") as? [[String]]) ?? []
    let id = Nostr.idOf(pubkey: ev.str("pubkey")!, createdAt: Int64(ev.int("created_at")!), kind: ev.int("kind")!, tags: tags,
                        content: ev["content"] as! String)
    expect(id == ev.str("id"), "NIP-01: id события (экранирование, юникод)")
    let signed = Nostr.sign(privateKey: a, kind: 4, tags: [["p", Secp256k1.publicKey(b).hex]], content: enc ?? "")
    expect(signed.isValid, "NIP-01: подписанное событие проверяется")
    let reparsed = NostrEvent(json: JSON.object(JSON.data(signed.json))!)
    expect(reparsed == signed, "NIP-01: событие переживает JSON")

    let pkHex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
    expect(Nostr.npub(pkHex) == "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg", "NIP-19: npub (вектор из спецификации)")
    expect(Nostr.pubkey(fromNpub: "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg") == pkHex, "NIP-19: разбор npub")
    expect(Nostr.pubkey(fromNpub: "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjpth") == nil, "NIP-19: битая контрольная сумма")
}
