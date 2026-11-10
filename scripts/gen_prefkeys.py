# Генерирует Drxwnify/Storage/Prefs/PreferenceKeys.generated.swift из Android PreferenceKeys.kt.
# Запуск (из любой папки):  python -I ios/scripts/gen_prefkeys.py
# Android-код только читается.
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'kotlin', 'com', 'metrolist', 'music',
                   'constants', 'PreferenceKeys.kt')
DST = os.path.join(ROOT, 'ios', 'Drxwnify', 'Storage', 'Prefs', 'PreferenceKeys.generated.swift')

KINDS = {
    'boolean': ('Bool', '.bool'),
    'float': ('Float', '.float'),
    'int': ('Int', '.int'),
    'long': ('Int', '.long'),
    'string': ('String', '.string'),
    'stringSet': ('[String]', '.stringSet'),
    'double': ('Double', '.double'),
}

# Ключи, объявленные вне PreferenceKeys.kt (SET-910…913).
EXTRA = [
    ('bitratesBySize220', 'boolean'), ('sourcesRecheck220c', 'boolean'), ('qualityModes220', 'boolean'),
    ('spotify_profile_tracks_json', 'string'), ('spotify_profile_artists_json', 'string'),
    ('spotify_profile_cache_ts', 'long'), ('spotify_profile_had_rest', 'boolean'),
    ('spotify_followed_artists_json', 'string'), ('spotify_followed_artists_ts', 'long'),
    ('spotify_related_artist_names_json', 'string'), ('spotify_related_artist_names_ts', 'long'),
    ('spotify_cached_playlists_json', 'string'), ('spotify_library_grid', 'boolean'),
    ('reviews_sort', 'string'), ('reviews_desc', 'boolean'),
    ('remoteConfigUrl', 'string'), ('remoteConfigCache', 'string'),
    ('spotify_gql_hashes_json', 'string'), ('spotify_gql_hashes_last_fetch', 'long'),
]

SWIFT_KEYWORDS = {'default', 'repeat', 'case', 'class', 'func', 'in', 'is', 'as', 'let', 'var', 'self',
                  'operator', 'private', 'public', 'static', 'struct', 'switch', 'true', 'false', 'nil'}

pat = re.compile(r'^\s*(?:const\s+)?val\s+(\w+)\s*=\s*(?:[\w.]+\.)?(\w+?)PreferencesKey(?:<[^>]*>)?\("([^"]+)"\)')


def swift_name(raw):
    name = re.sub(r'[^A-Za-z0-9]+(.)?', lambda m: (m.group(1) or '').upper(), raw)
    name = name[0].lower() + name[1:]
    return '`%s`' % name if name in SWIFT_KEYWORDS else name


seen = {}
rows = []
with open(SRC, encoding='utf-8') as f:
    for line in f:
        m = pat.match(line)
        if not m:
            continue
        kotlin, kind, key = m.groups()
        if kind not in KINDS:
            raise SystemExit('unknown kind %s in %s' % (kind, line))
        rows.append((key, kind, kotlin))
for key, kind in EXTRA:
    rows.append((key, kind, '(extra)'))

out = ['// Сгенерировано scripts/gen_prefkeys.py из android/.../constants/PreferenceKeys.kt. Руками не править.',
       '// Имена ключей совпадают с Android DataStore (settings.preferences_pb).',
       '',
       'enum PK {']
all_names = []
for key, kind, kotlin in rows:
    if key in seen:
        if seen[key] != kind:
            raise SystemExit('key %s declared with two kinds' % key)
        continue
    seen[key] = kind
    sw, tag = KINDS[kind]
    name = swift_name(key)
    all_names.append((name, key, tag))
    out.append('    /// %s' % kotlin)
    out.append('    static let %s = PrefKey<%s>("%s", %s)' % (name, sw, key, tag))
out.append('')
out.append('    /// Тип каждого известного ключа — для записи в protobuf при создании копии.')
out.append('    static let kinds: [String: PrefKind] = [')
for name, key, tag in all_names:
    out.append('        "%s": %s,' % (key, tag))
out.append('    ]')
out.append('}')
out.append('')

os.makedirs(os.path.dirname(DST), exist_ok=True)
with open(DST, 'w', encoding='utf-8', newline='\n') as f:
    f.write('\n'.join(out))
print('keys:', len(seen))
