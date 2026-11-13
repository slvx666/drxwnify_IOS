"""Android (adb) and iPhone (pymobiledevice3 + WebDriverAgent) side by side: open the same screen, screenshot, list buttons, tap.

  python ios/scripts/devices.py screens                 names that open on both (SCREENS below)
  python ios/scripts/devices.py compare <name>          open <name> on both, shots + side-by-side + buttons -> ios/out/compare/
  python ios/scripts/devices.py compare -a <route> -i <DRX_SCREEN> <name>
  python ios/scripts/devices.py shot                    screenshot both as they are now (compare without opening)
  python ios/scripts/devices.py ios|android shot|buttons|tap X Y|swipe X1 Y1 X2 Y2|type TEXT|back|home|open <screen>
  python ios/scripts/devices.py wda start|stop|status   WebDriverAgent on the iPhone (needed for ios tap/swipe/buttons)
  python ios/scripts/devices.py wda install             re-sign on the laptop (every 7 days) and install

Coordinates are pixels of that device's screenshot. How it is set up: ios/DEVICES.md
"""
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

IOS_DIR = Path(__file__).resolve().parent.parent
OUT = IOS_DIR / 'out' / 'compare'
PMD3 = os.environ.get('PMD3_PATH', r'D:\tools\pmd3')
ADB = Path(os.environ.get('LOCALAPPDATA', '')) / 'Android' / 'Sdk' / 'platform-tools' / 'adb.exe'
ANDROID_PKG = os.environ.get('DRX_ANDROID_PKG', 'com.drxwnify.app')
ANDROID_ACTIVITY = 'com.metrolist.music.MainActivity'
IOS_BUNDLE = os.environ.get('DRX_IOS_BUNDLE', 'com.drxwnify.ios.PNHU7KJ7PZ')
WDA_BUNDLE = os.environ.get('DRX_WDA_BUNDLE', '')  # filled from out/wda-bundle.txt after install
WDA_PORT = 8100
WDA = f'http://127.0.0.1:{WDA_PORT}'
NO_WINDOW = 0x08000000 | 0x00000008  # CREATE_NO_WINDOW | DETACHED_PROCESS: never takes focus

# name: (Android navigation route, iOS DRX_SCREEN). None = that side opens nothing (already open / no such screen).
SCREENS = {
    'home': ('home', 'home'),
    'search': ('search_input', 'search'),
    'library': ('library', 'library'),
    'settings': ('settings', 'settings'),
    'integrations': ('settings/integrations', 'integrations'),
    'together': ('settings/integrations/listen_together', 'together'),
    'stats': ('stats', 'stats'),
    'history': ('history', 'history'),
    'concerts': ('concerts', 'concerts'),
}

for p in (OUT,):
    p.mkdir(parents=True, exist_ok=True)


def run(cmd, check=True, **kw):
    r = subprocess.run(cmd, capture_output=True, **kw)
    if check and r.returncode != 0:
        sys.exit(f'error: {" ".join(map(str, cmd))}\n{r.stderr.decode(errors="replace")[-800:]}')
    return r


def pmd3(*args, check=True):
    env = dict(os.environ, PYTHONPATH=PMD3, PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    return run([sys.executable, '-m', 'pymobiledevice3', *args], check=check, env=env)


# ---------- Android ----------

def adb(*args, check=True):
    return run([str(ADB), *args], check=check, env=dict(os.environ, MSYS_NO_PATHCONV='1'))


def android_open(route):
    adb('shell', 'am', 'start', '-S', '-n', f'{ANDROID_PKG}/{ANDROID_ACTIVITY}', '--es', 'meld_route', route)


def android_shot(path):
    path.write_bytes(adb('exec-out', 'screencap', '-p').stdout)
    return path


def android_buttons():
    import xml.etree.ElementTree as ET
    adb('shell', 'uiautomator', 'dump', '/sdcard/drx-ui.xml')
    root = ET.fromstring(adb('exec-out', 'cat', '/sdcard/drx-ui.xml').stdout)
    out = []
    for n in root.iter('node'):
        if n.get('package') != ANDROID_PKG or n.get('clickable') != 'true':
            continue
        label = n.get('content-desc') or n.get('text') or ''
        if not label:  # a clickable row/box: take the first text inside it
            label = next((c.get('text') or c.get('content-desc') for c in n.iter('node') if c.get('text') or c.get('content-desc')), '')
        x1, y1, x2, y2 = map(int, n.get('bounds').replace('][', ',').strip('[]').split(','))
        out.append((label or '?', f'tap {(x1 + x2) // 2} {(y1 + y2) // 2}'))
    return out


# ---------- iPhone ----------

def wda(method, path, body=None, timeout=30):
    req = urllib.request.Request(WDA + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b'{}')


def wda_up():
    try:
        return wda('GET', '/status', timeout=5)
    except Exception:
        return None


def wda_session():
    st = wda_up()
    if not st:
        sys.exit('error: WebDriverAgent is not running (python ios/scripts/devices.py wda start)')
    sid = st.get('sessionId')
    if not sid:
        sid = wda('POST', '/session', {'capabilities': {'alwaysMatch': {}}})['sessionId']
    return sid


def ios_scale():
    st = wda('GET', f'/session/{wda_session()}/wda/screen')['value']
    return st.get('scale', 2)


def ios_open(screen):
    args = ['developer', 'dvt', 'launch', '--kill-existing']
    if screen:
        args += ['--env', f'DRX_SCREEN={screen}']
    pmd3(*args, IOS_BUNDLE)


def ios_shot(path):
    pmd3('developer', 'dvt', 'screenshot', str(path))
    return path


def ios_buttons():
    tree = wda('GET', '/source?format=json', timeout=60)['value']
    kinds = {'Button', 'Cell', 'Link', 'Switch', 'TextField', 'SearchField', 'SecureTextField', 'Slider', 'SegmentedControl', 'Tab'}
    scr = tree.get('rect', {})
    sw, sh = scr.get('width', 375), scr.get('height', 667)
    s = ios_scale()
    out = []

    def walk(e):
        t = e.get('type', '').replace('XCUIElementType', '')
        r = e.get('rect', {})
        cx, cy = r.get('x', 0) + r.get('width', 0) / 2, r.get('y', 0) + r.get('height', 0) / 2
        if t in kinds and str(e.get('isVisible', '1')) in ('1', 'True') and 0 <= cx <= sw and 0 <= cy <= sh:
            out.append((f"{t}: {e.get('label') or e.get('name') or e.get('value') or '?'}", f'tap {round(cx * s)} {round(cy * s)}'))
        for c in e.get('children') or []:
            walk(c)
    walk(tree)
    return out


def ios_tap(x, y):
    s = ios_scale()
    wda('POST', f'/session/{wda_session()}/wda/tap', {'x': x / s, 'y': y / s})


def ios_swipe(x1, y1, x2, y2, dur=0.3):
    s = ios_scale()
    wda('POST', f'/session/{wda_session()}/wda/dragfromtoforduration',
        {'fromX': x1 / s, 'fromY': y1 / s, 'toX': x2 / s, 'toY': y2 / s, 'duration': dur})


def wda_bundle():
    if WDA_BUNDLE:
        return WDA_BUNDLE
    f = IOS_DIR / 'out' / 'wda-bundle.txt'
    if f.exists():
        return f.read_text().strip()
    apps = json.loads(pmd3('apps', 'list', '-t', 'User').stdout or b'{}')
    ids = [b for b in apps if 'xctrunner' in b.lower()]
    if not ids:
        sys.exit('error: WebDriverAgentRunner is not installed on the iPhone (ios/DEVICES.md)')
    f.write_text(ids[0])
    return ids[0]


def wda_start():
    if wda_up():
        print('WDA already running')
        return
    env = dict(os.environ, PYTHONPATH=PMD3, PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    logs = IOS_DIR / 'out'
    bundle = wda_bundle()
    subprocess.Popen([sys.executable, '-m', 'pymobiledevice3', 'developer', 'dvt', 'xcuitest', bundle],
                     env=env, stdout=open(logs / 'wda.log', 'wb'), stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
    subprocess.Popen([sys.executable, '-m', 'pymobiledevice3', 'usbmux', 'forward', str(WDA_PORT), str(WDA_PORT)],
                     env=env, stdout=open(logs / 'wda-forward.log', 'wb'), stderr=subprocess.STDOUT, creationflags=NO_WINDOW)
    for _ in range(60):
        time.sleep(2)
        if wda_up():
            print('WDA running')
            return
    sys.exit(f'error: WDA did not answer in 120 s, see {logs / "wda.log"}')


LAPTOP = os.environ.get('DRX_LAPTOP', 'slvt@192.168.0.140')
SSH_DIR = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32' / 'OpenSSH'
SSH_OPTS = ['-i', r'D:\macos\ssh\id_ed25519', '-o', r'UserKnownHostsFile=D:\macos\ssh\known_hosts', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15']
WDA_IPA = Path(os.environ.get('DRX_WDA_IPA', r'D:\tools\wda\WDA.ipa'))


def wda_install():
    """Re-sign (free Apple ID: 7 days) on the laptop and install. Needs only the laptop, not the VM."""
    scp, ssh = str(SSH_DIR / 'scp.exe'), str(SSH_DIR / 'ssh.exe')
    run([scp, *SSH_OPTS, '-q', str(WDA_IPA), f'{LAPTOP}:drxwnify/WDA.ipa'])
    script = (IOS_DIR / 'scripts' / 'wda-sign.sh').read_bytes().replace(b'\r', b'')
    r = run([ssh, *SSH_OPTS, LAPTOP, 'cat > ~/drxwnify/wda-sign.sh && bash ~/drxwnify/wda-sign.sh'], input=script)
    print(r.stdout.decode(errors='replace').strip())
    signed = WDA_IPA.with_name('WDA-signed.ipa')
    run([scp, *SSH_OPTS, '-q', f'{LAPTOP}:drxwnify/WDA-signed.ipa', str(signed)])
    wda_stop()
    pmd3('apps', 'install', str(signed))
    print('WDA installed')


def wda_stop():
    ps = "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { $_.CommandLine -match 'xcuitest|usbmux forward " + str(WDA_PORT) + "' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
    run(['powershell', '-NoProfile', '-Command', ps], check=False)
    print('WDA stopped')


# ---------- both ----------

def side_by_side(a, i, dst, title):
    from PIL import Image, ImageDraw
    ia, ii = Image.open(a), Image.open(i)
    h = 1400
    ia = ia.resize((round(ia.width * h / ia.height), h))
    ii = ii.resize((round(ii.width * h / ii.height), h))
    img = Image.new('RGB', (ia.width + ii.width + 30, h + 40), 'white')
    img.paste(ia, (0, 40))
    img.paste(ii, (ia.width + 30, 40))
    d = ImageDraw.Draw(img)
    d.text((10, 12), f'{title}  Android', fill='black')
    d.text((ia.width + 40, 12), 'iPhone', fill='black')
    img.save(dst)
    return dst


def print_buttons(name, items):
    print(f'--- {name}: {len(items)}')
    for label, bounds in items:
        print(f'  {label}  {bounds}')


def compare(name, a_route, i_screen, wait=6):
    if a_route:
        android_open(a_route)
    if i_screen is not None:
        ios_open(i_screen)
    time.sleep(wait)
    a = android_shot(OUT / f'{name}-android.png')
    i = ios_shot(OUT / f'{name}-ios.png')
    print('SHOT:', side_by_side(a, i, OUT / f'{name}.png', name))
    print_buttons('Android buttons', android_buttons())
    if wda_up():
        print_buttons('iPhone buttons', ios_buttons())
    else:
        print('--- iPhone buttons: WDA not running (wda start)')


def device_cmd(dev, args):
    op, rest = args[0], args[1:]
    shot = OUT / f'{dev}-now.png'
    if op == 'shot':
        print('SHOT:', (android_shot if dev == 'android' else ios_shot)(shot))
    elif op == 'buttons':
        print_buttons(dev, android_buttons() if dev == 'android' else ios_buttons())
    elif op == 'tap':
        x, y = map(float, rest[:2])
        if dev == 'android':
            adb('shell', 'input', 'tap', str(int(x)), str(int(y)))
        else:
            ios_tap(x, y)
    elif op == 'swipe':
        x1, y1, x2, y2 = map(float, rest[:4])
        if dev == 'android':
            adb('shell', 'input', 'swipe', *map(lambda v: str(int(v)), (x1, y1, x2, y2)), '300')
        else:
            ios_swipe(x1, y1, x2, y2)
    elif op == 'type':
        text = ' '.join(rest)
        if dev == 'android':
            adb('shell', 'input', 'text', text.replace(' ', '%s'))
        else:
            wda('POST', f'/session/{wda_session()}/wda/keys', {'value': list(text)})
    elif op == 'back':
        if dev == 'android':
            adb('shell', 'input', 'keyevent', '4')
        else:  # iOS has no back button: swipe from the left edge
            wda('POST', f'/session/{wda_session()}/wda/dragfromtoforduration',
                {'fromX': 2, 'fromY': 300, 'toX': 300, 'toY': 300, 'duration': 0.2})
    elif op == 'home':
        if dev == 'android':
            adb('shell', 'input', 'keyevent', '3')
        else:
            wda('POST', '/wda/homescreen')
    elif op == 'open':
        a, i = SCREENS.get(rest[0], (rest[0], rest[0]))
        (android_open if dev == 'android' else ios_open)(a if dev == 'android' else i)
    else:
        sys.exit(f'unknown: {op}')
    if op in ('tap', 'swipe', 'type', 'back', 'home', 'open'):
        time.sleep(1.5)
        print('SHOT:', (android_shot if dev == 'android' else ios_shot)(shot))


def main(argv):
    sys.stdout.reconfigure(encoding='utf-8')
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return
    cmd = argv[0]
    if cmd == 'screens':
        for k, (a, i) in SCREENS.items():
            print(f'{k:14} android={a}  ios={i}')
    elif cmd == 'compare':
        rest, a_route, i_screen = argv[1:], None, None
        while rest and rest[0] in ('-a', '-i'):
            if rest[0] == '-a':
                a_route = rest[1]
            else:
                i_screen = rest[1]
            rest = rest[2:]
        name = rest[0]
        if a_route is None and i_screen is None:
            a_route, i_screen = SCREENS[name]
        compare(name, a_route, i_screen)
    elif cmd == 'shot':
        compare(argv[1] if len(argv) > 1 else 'now', None, None, wait=0)
    elif cmd in ('ios', 'android'):
        device_cmd(cmd, argv[1:])
    elif cmd == 'wda':
        {'start': wda_start, 'stop': wda_stop, 'install': wda_install,
         'status': lambda: print(wda_up() or 'not running')}[argv[1]]()
    else:
        sys.exit(f'unknown command {cmd}')


if __name__ == '__main__':
    main(sys.argv[1:])
