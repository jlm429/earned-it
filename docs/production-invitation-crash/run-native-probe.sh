#!/bin/bash
set -euo pipefail

# Pass a booted, task-isolated Simulator UUID. Never uses CloudKit databases.
probe_simulator=${1:?Usage: run-native-probe.sh booted-isolated-simulator-uuid}
probe_root=$(cd "$(dirname "$0")/../.." && pwd -P)
probe_output="$probe_root/.artifacts/native-invitation-probe"
probe_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
mkdir -p "$probe_output"

# Parse the signing plist as data and embed only the capability under test.
python3 - "$probe_root" "$probe_output" <<'PY'
import plistlib
import sys
from pathlib import Path
root, output = map(Path, sys.argv[1:])
with (root / 'Configuration/EarnedIt.entitlements').open('rb') as source:
    signing = plistlib.load(source)
key = 'com.apple.developer.icloud-extended-share-access'
for name, values in [('enabled', signing.get(key, [])), ('absent', []),
                     ('wrong-value', ['InProcessShareOwnerParticipantInfo'])]:
    with (output / f'{name}.plist').open('wb') as destination:
        plistlib.dump({key: values}, destination)
if signing.get(key) != ['InProcessOneTimeLinks']:
    raise SystemExit('Signing contract lacks exactly the requested one-time link capability')
PY

for probe_config in enabled absent wrong-value; do
    xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator \
        -isysroot "$probe_sdk" -fobjc-arc -Wall -Werror \
        -framework Foundation -framework CloudKit \
        -Wl,-sectcreate,__TEXT,__entitlements,"$probe_output/$probe_config.plist" \
        "$probe_root/docs/production-invitation-crash/native-probe.m" \
        -o "$probe_output/$probe_config"
done

# Execute native admission, not a source-text assertion or transport double.
python3 - "$probe_simulator" "$probe_output" <<'PY'
import subprocess
import sys
from pathlib import Path
simulator, output = sys.argv[1], Path(sys.argv[2])
cases = [('enabled', kind, mode, 0)
         for kind in ('zone', 'hierarchy')
         for mode in ('factory', 'readwrite', 'private', 'duplicate')]
cases += [('enabled', 'zone', mode, 1)
          for mode in ('unknown-role', 'owner-role', 'public-role', 'unknown-permission')]
cases += [('enabled', 'zone', 'none-permission', 0),
          ('enabled', 'zone', 'public-share', 0),
          ('enabled', 'zone', 'administrator', 0),
          ('absent', 'zone', 'private', 133),
          ('absent', 'zone', 'readwrite', 133),
          ('wrong-value', 'zone', 'private', 133)]
failures = []
with (output / 'results.log').open('w') as log:
    for config, kind, mode, expected in cases:
        result = subprocess.run(['xcrun', 'simctl', 'spawn', simulator,
                                 str(output / config), mode, kind],
                                capture_output=True, text=True)
        text = f'{config} {kind} {mode}: exit={result.returncode}\n{result.stdout}{result.stderr}'
        print(text, end=''); log.write(text)
        if mode == 'administrator' and result.returncode == 77:
            continue
        if result.returncode != expected:
            failures.append((config, kind, mode, expected, result.returncode))
if failures:
    raise SystemExit(f'Native contract observations changed: {failures}')
print(f'{len(cases)} native admission and negative-control cases passed')
PY
