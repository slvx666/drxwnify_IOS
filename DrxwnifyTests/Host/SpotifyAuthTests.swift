import Foundation

func testSpotifyAuth() {
    section("Spotify TOTP (RFC 6238, SHA-1, 6 цифр)")
    // Секрет из RFC 6238: ASCII "12345678901234567890" в base32.
    let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    expect(SpotifyAuth.base32Decode(secret) == Array("12345678901234567890".utf8), "base32")
    expect(SpotifyAuth.base32Decode("gezd gnbv====") == Array("12345".utf8), "base32: регистр, пробелы, дополнение")
    // Эталонные 8-значные коды RFC: 94287082, 07081804, 89005924 — берём младшие 6 цифр.
    expect(SpotifyAuth.generateTotp(secret: secret, serverTimeSec: 59) == "287082", "t=59")
    expect(SpotifyAuth.generateTotp(secret: secret, serverTimeSec: 1_111_111_109) == "081804", "t=1111111109")
    expect(SpotifyAuth.generateTotp(secret: secret, serverTimeSec: 1_234_567_890) == "005924", "t=1234567890")

    section("JSON-хелперы")
    let o = JSON.object("{\"a\":{\"n\":5,\"s\":\"7\",\"b\":true,\"f\":1.5,\"z\":null},\"l\":[{\"x\":1},2]}")!
    expect(o.obj("a")?.int("n") == 5 && o.obj("a")?.str("n") == "5", "число как int и как строка")
    expect(o.obj("a")?.int("s") == 7, "числовая строка как int")
    expect(o.obj("a")?.bool("b") == true && o.obj("a")?.int("b") == nil, "bool не превращается в int")
    expect(o.obj("a")?.int("f") == nil && o.obj("a")?.str("z") == nil, "дробное и null дают nil")
    expect(o.objects("l").count == 1, "objects пропускает не-объекты")
    expect("spotify:track:abc".substringAfterLast(":") == "abc" && "abc".substringAfterLast(":") == "abc", "substringAfterLast")
}
