#!/bin/bash
# Fails if a preference is shown in the UI but read by nothing.
#
# Five shipped toggles once wrote a value that no service ever consulted — a third of the
# preference pane did nothing, which is a refund in a paid app. This is the cheapest possible
# guard against that class of drift, and it runs in CI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import io, os, re, sys

root = sys.argv[1]
settings_path = os.path.join(root, "Sources/Core/Settings.swift")
src = io.open(settings_path, encoding="utf-8").read()

# Declared preferences.
stored = re.findall(r'@Stored\("[^"]+"\)\s+var\s+(\w+)', src)
if not stored:
    sys.exit("check-settings: found no @Stored properties — has Settings.swift moved?")

# Members of Settings that derive from a preference (calibration, resolvedSoundTheme, …). A
# preference consumed only by one of these is fine, provided that member is itself used elsewhere.
derived = {}
for match in re.finditer(r'\n    (?:private )?var (\w+)\s*:[^\n{]*\{(.*?)\n    \}', src, re.S):
    derived[match.group(1)] = match.group(2)

# Every other source file is a potential consumer. The settings window does not count: showing a
# toggle is exactly the thing that fools you into thinking it works.
consumers = []
for base, _, files in os.walk(os.path.join(root, "Sources")):
    for name in files:
        if not name.endswith(".swift"):
            continue
        path = os.path.join(base, name)
        if os.path.basename(path) in ("Settings.swift", "SettingsView.swift"):
            continue
        consumers.append(io.open(path, encoding="utf-8").read())
body = "\n".join(consumers)

def used(name):
    if re.search(r'\b%s\b' % re.escape(name), body):
        return True
    # Consumed via a derived member that is itself used outside Settings.swift.
    for member, code in derived.items():
        if re.search(r'\b%s\b' % re.escape(name), code) and re.search(r'\b%s\b' % re.escape(member), body):
            return True
    return False

dead = [name for name in stored if not used(name)]
if dead:
    print("check-settings: these preferences are written but never read:", file=sys.stderr)
    for name in dead:
        print(f"  - {name}", file=sys.stderr)
    print("Wire them up or remove them from Settings.swift and the settings window.", file=sys.stderr)
    sys.exit(1)

print(f"check-settings: {len(stored)} preferences, all consumed")
PY
