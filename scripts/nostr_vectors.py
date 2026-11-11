#!/usr/bin/env python3
"""Эталонные векторы Nostr для проверки iOS-кода (CRITICAL §1.1).

BIP-340 — по эталонной реализации из спецификации (чистая арифметика Python), id события — NIP-01,
NIP-04 — общий секрет ECDH (x точки), шифртекст AES-256-CBC считает openssl (вызывается из host-test.sh).
Запуск: nostr_vectors.py <out.json>
"""
import hashlib
import json
import subprocess
import sys

p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
     0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)


def point_add(P1, P2):
    if P1 is None:
        return P2
    if P2 is None:
        return P1
    if P1[0] == P2[0] and P1[1] != P2[1]:
        return None
    if P1 == P2:
        lam = (3 * P1[0] * P1[0] * pow(2 * P1[1], p - 2, p)) % p
    else:
        lam = ((P2[1] - P1[1]) * pow(P2[0] - P1[0], p - 2, p)) % p
    x3 = (lam * lam - P1[0] - P2[0]) % p
    return (x3, (lam * (P1[0] - x3) - P1[1]) % p)


def point_mul(P, k):
    R = None
    for i in range(256):
        if (k >> i) & 1:
            R = point_add(R, P)
        P = point_add(P, P)
    return R


def b32(x):
    return x.to_bytes(32, "big")


def i(b):
    return int.from_bytes(b, "big")


def tagged(tag, msg):
    th = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(th + th + msg).digest()


def lift_x(x):
    if x >= p:
        return None
    c = (pow(x, 3, p) + 7) % p
    y = pow(c, (p + 1) // 4, p)
    if pow(y, 2, p) != c:
        return None
    return (x, y if y % 2 == 0 else p - y)


def pubkey(sk):
    return b32(point_mul(G, i(sk))[0])


def sign(msg, sk, aux):
    d0 = i(sk)
    P = point_mul(G, d0)
    d = d0 if P[1] % 2 == 0 else n - d0
    t = bytes(a ^ b for a, b in zip(b32(d), tagged("BIP0340/aux", aux)))
    k0 = i(tagged("BIP0340/nonce", t + b32(P[0]) + msg)) % n
    R = point_mul(G, k0)
    k = k0 if R[1] % 2 == 0 else n - k0
    e = i(tagged("BIP0340/challenge", b32(R[0]) + b32(P[0]) + msg)) % n
    return b32(R[0]) + b32((k + e * d) % n)


def shared(sk, pk):
    return b32(point_mul(lift_x(i(pk)), i(sk))[0])


def esc(s):
    out = '"'
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out += '\\"'
        elif ch == "\\":
            out += "\\\\"
        elif ch == "\n":
            out += "\\n"
        elif ch == "\r":
            out += "\\r"
        elif ch == "\t":
            out += "\\t"
        elif ch == "\b":
            out += "\\b"
        elif ch == "\f":
            out += "\\f"
        elif o < 0x20:
            out += "\\u%04x" % o
        else:
            out += ch
    return out + '"'


def event_id(pk, created, kind, tags, content):
    s = "[0," + esc(pk) + "," + str(created) + "," + str(kind) + ",["
    s += ",".join("[" + ",".join(esc(v) for v in t) + "]" for t in tags)
    s += "]," + esc(content) + "]"
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def main(out):
    keys = [
        "0000000000000000000000000000000000000000000000000000000000000003",
        "B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF",
        "C90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B14E5C9",
        "0B432B2677937381AEF05BB02A66ECD012773062CF3FA2549E44F58ED2401710",
        "1d2dc2b8b0f62d24f3a8b1c8f07ad1cc7bb1d1b6f6f7c8a1e2b3c4d5e6f70812",
    ]
    msgs = ["00" * 32, "243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89",
            "7E2D58D8B3BCDF1ABADEC7829054F90DDA9805AAB56C77333024B9D0A508B75C", "FF" * 32, "11" * 32]
    auxes = ["00" * 32, "00" * 31 + "01", "C87AA53824B4D7AE2EB035A2B5BBBCCC080E76CDC6D1692C4B0B62D798E6D906", "FF" * 32, "42" * 32]
    sigs = []
    for sk, m, a in zip(keys, msgs, auxes):
        skb = bytes.fromhex(sk)
        sigs.append({"sk": sk.lower(), "pk": pubkey(skb).hex(), "msg": m.lower(), "aux": a.lower(),
                     "sig": sign(bytes.fromhex(m), skb, bytes.fromhex(a)).hex()})
    a_sk, b_sk = bytes.fromhex(keys[1]), bytes.fromhex(keys[4])
    sec = shared(a_sk, pubkey(b_sk))
    assert sec == shared(b_sk, pubkey(a_sk))
    plain = 'Привет, "друг"! 🎵 {"t":"drxw-chat"}'
    iv = "000102030405060708090a0b0c0d0e0f"
    ct = subprocess.run(["openssl", "enc", "-aes-256-cbc", "-K", sec.hex(), "-iv", iv, "-base64", "-A"],
                        input=plain.encode("utf-8"), capture_output=True, check=True).stdout.decode().strip()
    pk_a = pubkey(a_sk).hex()
    tags = [["d", "drxw:now:" + pubkey(b_sk).hex()], ["p", pubkey(b_sk).hex()], ["t", "drxwnify"]]
    content = 'Строка с "кавычками", \\ слешем,\nпереводом,\tтабом,\r\b\f и \x01 управляющим 🎶'
    ev = {"pubkey": pk_a, "created_at": 1767225600, "kind": 30078, "tags": tags, "content": content}
    ev["id"] = event_id(pk_a, ev["created_at"], ev["kind"], tags, content)
    json.dump({"sigs": sigs, "ecdh": {"a": keys[1].lower(), "b": keys[4], "secret": sec.hex(), "iv": iv,
                                      "plain": plain, "content": ct + "?iv=" + __import__("base64").b64encode(bytes.fromhex(iv)).decode()},
               "event": ev}, open(out, "w"), ensure_ascii=False)


if __name__ == "__main__":
    main(sys.argv[1])
