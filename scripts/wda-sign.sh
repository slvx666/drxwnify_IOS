#!/bin/bash
# Laptop (Arch): sign ~/drxwnify/WDA.ipa (unsigned WebDriverAgent runner) -> ~/drxwnify/WDA-signed.ipa with the saved Apple ID.
# plumesign signs a .xctest in PlugIns like an app (with entitlements) or not at all; iOS then refuses to load it
# ("has entitlements but is not a main binary"). So pass 1 signs it parked in Frameworks/ (no entitlements, like a framework),
# pass 2 puts it back into PlugIns/ and signs the runner around it.
set -euo pipefail
cd ~/drxwnify
A=Payload/WebDriverAgentRunner-Runner.app
X=$A/PlugIns/WebDriverAgentRunner.xctest
F=$A/Frameworks/WDAXCTest.framework
sign() { printf '\r\r\r' | timeout 300 script -qec "./bin/plumesign sign --package $1 --apple-id -o $2" /dev/null 2>&1 | grep -E 'Saved|ERROR' | tail -1; }
rm -rf wdasign && mkdir wdasign && cd wdasign
unzip -q ../WDA.ipa && mv "$X" "$F" && zip -qr -y ../wda-pass1.ipa Payload && cd .. && sign wda-pass1.ipa wda-pass1-signed.ipa
rm -rf wdasign && mkdir wdasign && cd wdasign
# original runner Info.plist, otherwise pass 2 appends the team id to the bundle id a second time
unzip -q ../wda-pass1-signed.ipa && unzip -o -q ../WDA.ipa "$A/Info.plist" && mv "$F" "$X" && zip -qr -y ../wda-pass2.ipa Payload && cd .. && rm -f WDA-signed.ipa && sign wda-pass2.ipa WDA-signed.ipa
rm -rf wdasign && mkdir wdasign && cd wdasign && unzip -q ../WDA-signed.ipa
[ "$(grep -ac application-identifier "$X/WebDriverAgentRunner")" = 0 ] || { echo 'error: xctest got entitlements'; exit 1; }
cd .. && rm -rf wdasign wda-pass1.ipa wda-pass1-signed.ipa wda-pass2.ipa
echo SIGNED
