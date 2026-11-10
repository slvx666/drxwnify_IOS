# Генерирует Localizable.strings (ru, en) из строк Android с теми же именами ключей.
# Запуск:  python -I ios/scripts/gen_strings.py
# Источник: android/app/src/main/res/values/*.xml и values-ru/*.xml (только чтение).
# Множественные формы (<plurals>) превращаются в ключи `имя.one`, `имя.few`, `имя.many`, `имя.other`.
import glob
import os
import re
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
RES = os.path.join(ROOT, 'android', 'app', 'src', 'main', 'res')
OUT = os.path.join(ROOT, 'ios', 'Drxwnify', 'Resources')


def unescape(text):
    text = text or ''
    # Android схлопывает пробелы и переводы строк вне кавычек.
    text = re.sub(r'\s+', ' ', text).strip()
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        text = text[1:-1]
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c == '\\' and i + 1 < len(text):
            n = text[i + 1]
            if n == 'n':
                out.append('\n')
            elif n == 't':
                out.append('\t')
            elif n == 'u' and i + 5 < len(text):
                out.append(chr(int(text[i + 2:i + 6], 16)))
                i += 4
            else:
                out.append(n)
            i += 2
            continue
        out.append(c)
        i += 1
    text = ''.join(out)
    # %s / %1$s -> %@ / %1$@ (в iOS строковый аргумент — объект).
    text = re.sub(r'%(\d+\$)?s', lambda m: '%' + (m.group(1) or '') + '@', text)
    return text


def flatten(el):
    return ''.join(el.itertext())


def load(folder):
    strings = {}
    for path in sorted(glob.glob(os.path.join(RES, folder, '*.xml'))):
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            continue
        if root.tag != 'resources':
            continue
        for el in root:
            name = el.get('name')
            if not name:
                continue
            if el.tag == 'string':
                strings[name] = unescape(flatten(el))
            elif el.tag == 'plurals':
                for item in el.findall('item'):
                    strings['%s.%s' % (name, item.get('quantity'))] = unescape(flatten(item))
    return strings


def quote(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')


def write(lang, strings, note):
    folder = os.path.join(OUT, lang + '.lproj')
    os.makedirs(folder, exist_ok=True)
    lines = ['/* %s */' % note]
    for key in sorted(strings):
        lines.append('"%s" = "%s";' % (quote(key), quote(strings[key])))
    with open(os.path.join(folder, 'Localizable.strings'), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')


en = load('values')
ru = dict(en)
ru_own = load('values-ru')
ru.update(ru_own)
note = 'Сгенерировано scripts/gen_strings.py из строк Android. Руками не править: свои строки iOS лежат в IOS.strings.'
write('en', en, note)
write('ru', ru, note)
print('en:', len(en), 'ru own:', len(ru_own), 'ru total:', len(ru))
