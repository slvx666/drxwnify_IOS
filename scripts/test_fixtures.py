# Тестовые данные для проверки формата копии (запускается на VM из scripts/host-test.sh).
#   python3 test_fixtures.py make <schema.sql> <out.backup>   — копия «как с Android»
#   python3 test_fixtures.py verify <file.zip>                — читает zip потоково, как Java ZipInputStream
# Копия пишется в непозиционируемый поток: как у Java, размеры уходят в data descriptor,
# а в локальных заголовках стоят нули.
import io
import os
import sqlite3
import struct
import sys
import tempfile
import zipfile
import zlib


def varint(n):
    n &= (1 << 64) - 1
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def ld(field, payload):
    return varint(field << 3 | 2) + varint(len(payload)) + payload


def entry(key, value):
    return ld(1, ld(1, key.encode()) + ld(2, value))


def make_prefs():
    out = b''
    out += entry('pureBlack', varint(1 << 3 | 0) + varint(1))
    out += entry('stereoBalance', varint(2 << 3 | 5) + struct.pack('<f', 1.5))
    out += entry('selectedThemeColor', varint(3 << 3 | 0) + varint(-3))
    out += entry('spotifyTokenExpiry', varint(4 << 3 | 0) + varint(1700000000000))
    out += entry('spotifySpDc', ld(5, 'секрет sp_dc'.encode()))
    out += entry('someSet', ld(6, ld(1, b'a') + ld(1, b'b')))
    out += entry('someDouble', varint(7 << 3 | 1) + struct.pack('<d', 2.25))
    out += entry('someBytes', ld(8, b'\x00\x01\xff'))
    return out


FRIENDS_XML = """<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="sk">00ff11</string>
    <string name="name">Имя &amp; &lt;тег&gt; &quot;кавычки&quot;
вторая строка</string>
    <int name="n" value="-5" />
    <long name="ts" value="1700000000000" />
    <boolean name="flag" value="true" />
    <float name="vol" value="0.75" />
    <set name="friends">
        <string>npub1aaa</string>
        <string>npub1bbb</string>
    </set>
</map>
"""


class Unseekable(io.RawIOBase):
    def __init__(self, f):
        self.f = f

    def writable(self):
        return True

    def write(self, b):
        return self.f.write(b)

    def flush(self):
        self.f.flush()


def make(schema_path, out_path):
    tmp = os.path.join(tempfile.mkdtemp(), 'song.db')
    db = sqlite3.connect(tmp)
    db.executescript(open(schema_path, encoding='utf-8').read())
    db.execute('PRAGMA user_version = 40')
    db.execute("INSERT INTO song (id, title, duration, liked, totalPlayTime) VALUES ('spotify:1', 'Песня', 180, 1, 0)")
    db.execute("INSERT INTO playlist (id, name) VALUES ('LP1', 'Плейлист')")
    db.commit()
    db.close()
    with open(out_path, 'wb') as raw:
        with zipfile.ZipFile(Unseekable(raw), 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('settings.preferences_pb', make_prefs())
            z.write(tmp, 'song.db')
            z.writestr('shared_prefs/friends.xml', FRIENDS_XML.encode())
            z.writestr('shared_prefs/../evil.xml', b'<map></map>')
            z.writestr('covers/cover_1.jpg', bytes(range(256)) * 40)
    print('made', out_path, os.path.getsize(out_path))


def verify(path):
    """Потоковое чтение по локальным заголовкам, без центрального каталога."""
    data = open(path, 'rb').read()
    pos = 0
    names = []
    while data[pos:pos + 4] == b'PK\x03\x04':
        (ver, flags, method, _t, _d, crc, comp, uncomp, nlen, elen) = struct.unpack('<HHHHHIIIHH', data[pos + 4:pos + 30])
        assert flags & 8 == 0, 'data descriptor is not expected'
        name = data[pos + 30:pos + 30 + nlen].decode('utf-8')
        start = pos + 30 + nlen + elen
        payload = data[start:start + comp]
        body = zlib.decompress(payload, -15) if method == 8 else payload
        assert len(body) == uncomp, name
        assert zlib.crc32(body) & 0xFFFFFFFF == crc, name
        names.append('%s:%d' % (name, uncomp))
        pos = start + comp
    assert data[pos:pos + 4] == b'PK\x01\x02', 'central directory expected'
    with zipfile.ZipFile(path) as z:
        assert z.testzip() is None
    print('stream ok', ' '.join(names))


if __name__ == '__main__':
    if sys.argv[1] == 'make':
        make(sys.argv[2], sys.argv[3])
    else:
        verify(sys.argv[2])
