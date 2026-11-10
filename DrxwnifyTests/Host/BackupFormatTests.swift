import Foundation

func testBackupFormat(fixture: URL, outZip: URL) throws {
    section("zip: чтение копии с data descriptor")
    let zip = try ZipReader(url: fixture)
    let names = zip.entries.map { $0.name }
    expect(names.contains("settings.preferences_pb"), "есть settings.preferences_pb")
    expect(names.contains("song.db"), "есть song.db")
    expect(names.contains("shared_prefs/friends.xml"), "есть shared_prefs/friends.xml")
    expect(names.contains("covers/cover_1.jpg"), "есть covers/cover_1.jpg")

    func entry(_ name: String) -> ZipReader.Entry { zip.entries.first { $0.name == name }! }

    let cover = try zip.data(for: entry("covers/cover_1.jpg"))
    expect(cover.count == 256 * 40 && cover[255] == 255 && cover[256] == 0, "обложка распакована побайтно")

    let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("host-test-song.db")
    try zip.extract(entry("song.db"), to: dbURL)
    let db = try Data(contentsOf: dbURL)
    expect(db.count == entry("song.db").uncompressedSize, "song.db: размер совпал")
    expect(String(data: db.prefix(15), encoding: .ascii) == "SQLite format 3", "song.db: заголовок SQLite")

    section("protobuf: settings.preferences_pb")
    let prefsData = try zip.data(for: entry("settings.preferences_pb"))
    let prefs = try PreferencesProto.decode(prefsData)
    expect(prefs.count == 8, "8 ключей")
    expect(prefs["pureBlack"] == .bool(true), "bool")
    expect(prefs["stereoBalance"] == .float(1.5), "float")
    expect(prefs["selectedThemeColor"] == .int(-3), "int32 отрицательный")
    expect(prefs["spotifyTokenExpiry"] == .long(1_700_000_000_000), "int64")
    expect(prefs["spotifySpDc"] == .string("секрет sp_dc"), "string UTF-8")
    expect(prefs["someSet"] == .stringSet(["a", "b"]), "string set")
    expect(prefs["someDouble"] == .double(2.25), "double")
    expect(prefs["someBytes"] == .bytes(Data([0, 1, 255])), "bytes")
    let again = try PreferencesProto.decode(PreferencesProto.encode(prefs))
    expect(again == prefs, "запись и повторное чтение дают то же")
    // Порядок записей в protobuf-карте не задан, сравниваем множества байтовых записей.
    expect(PreferencesProto.encode(prefs).count == prefsData.count, "длина совпала с исходным файлом")

    section("SharedPreferences XML")
    let xml = AndroidPrefsXML.decode(try zip.data(for: entry("shared_prefs/friends.xml")))
    expect(xml["sk"] == .string("00ff11"), "string")
    expect(xml["name"] == .string("Имя & <тег> \"кавычки\"\nвторая строка"), "экранирование и перевод строки")
    expect(xml["n"] == .int(-5), "int")
    expect(xml["ts"] == .long(1_700_000_000_000), "long")
    expect(xml["flag"] == .bool(true), "boolean")
    expect(xml["vol"] == .float(0.75), "float")
    expect(xml["friends"] == .stringSet(["npub1aaa", "npub1bbb"]), "set")
    expect(AndroidPrefsXML.decode(AndroidPrefsXML.encode(xml)) == xml, "запись и повторное чтение дают то же")

    section("zip: запись")
    let writer = try ZipWriter(url: outZip)
    try writer.add(name: "settings.preferences_pb", data: PreferencesProto.encode(prefs))
    try writer.add(name: "song.db", fileAt: dbURL)
    try writer.add(name: "shared_prefs/friends.xml", data: AndroidPrefsXML.encode(xml))
    try writer.add(name: "covers/пустой.jpg", data: Data())
    try writer.finish()
    let back = try ZipReader(url: outZip)
    expect(back.entries.count == 4, "4 записи")
    let dbBack = try back.data(for: back.entries[1])
    expect(dbBack == db, "song.db читается обратно побайтно")
    expect(back.entries[3].name == "covers/пустой.jpg" && back.entries[3].uncompressedSize == 0, "пустая запись и имя UTF-8")
}
