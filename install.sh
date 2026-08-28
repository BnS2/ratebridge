#!/bin/bash
# Install ratebridge on this Mac: preflight, build, bundle, launch.
#
# Safe to re-run — it is also the upgrade path.
set -euo pipefail
cd "$(dirname "$0")"

say()  { printf '  %s\n' "$1"; }
fail() { printf '\nerror: %s\n' "$1" >&2; exit 1; }

echo "ratebridge — installing"
echo

# ---- preflight -------------------------------------------------------------
# Each of these fails confusingly later if it is not checked here. The macOS
# floor is real: kAudioHardwarePropertyProcessObjectList, which is how the whole
# tool knows what is playing, does not exist before 14.2.
echo "checking this machine"

OS="$(sw_vers -productVersion)"
MAJOR="${OS%%.*}"
MINOR="$(echo "$OS" | cut -d. -f2)"; MINOR="${MINOR:-0}"
if [ "$MAJOR" -lt 14 ] || { [ "$MAJOR" -eq 14 ] && [ "$MINOR" -lt 2 ]; }; then
    fail "macOS 14.2 or newer required (found $OS).
       ratebridge needs kAudioHardwarePropertyProcessObjectList to see what is playing."
fi
say "macOS $OS — ok"

command -v swiftc >/dev/null 2>&1 || fail "swiftc not found.
       Install the Xcode command line tools:  xcode-select --install"
say "swiftc $(swiftc --version 2>/dev/null | head -1 | sed 's/.*Swift version //;s/ .*//') — ok"

# Signing identity decides whether the Accessibility grant survives upgrades.
# Ad-hoc works, but every rebuild then costs a manual remove-and-re-add, so it is
# worth saying plainly rather than discovering later.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(.*\)"$/\1/p' | head -1)"
if [ -n "$SIGN_ID" ]; then
    say "signing identity: $SIGN_ID"
else
    say "no codesigning identity — will sign ad-hoc"
    say "  consequence: every future upgrade voids the Accessibility grant and"
    say "  you must remove and re-add the app by hand. Any free Apple Developer"
    say "  account provides an identity that avoids this."
fi

OUTPUTS="$(system_profiler SPAudioDataType 2>/dev/null | grep -c "Current SampleRate" || true)"
say "output devices detected: ${OUTPUTS:-unknown}"
echo

# ---- build -----------------------------------------------------------------
echo "building"
./package.sh /Applications >/dev/null 2>&1 || ./package.sh /Applications
say "/Applications/Ratebridge.app"

mkdir -p "$HOME/.local/bin"
cp bin/ratebridge "$HOME/.local/bin/.ratebridge.new"
mv -f "$HOME/.local/bin/.ratebridge.new" "$HOME/.local/bin/ratebridge"
say "$HOME/.local/bin/ratebridge"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) say "note: $HOME/.local/bin is not on your PATH" ;;
esac
echo

# ---- launch ----------------------------------------------------------------
osascript -e 'tell application "Ratebridge" to quit' >/dev/null 2>&1 || true
sleep 1
open -a /Applications/Ratebridge.app
say "launched — look for the note icon in the menu bar"
echo

# ---- what only you can do --------------------------------------------------
cat <<'NEXT'
Three steps left, none of which can be scripted:

  1. Accessibility  (only needed if you use Musicer)
     System Settings > Privacy & Security > Accessibility
     Remove any old Ratebridge entry, then add /Applications/Ratebridge.app.
     Removing first matters: macOS will not rebind a stale entry to a new
     signature. Musicer publishes no scripting interface, so reading its window
     is the only way to know its rate.

  2. Pin your DAC
     ratebridge device                 # list what is connected
     ratebridge device "Your DAC"      # pin it

     Skip this if exactly one USB DAC is attached — it is found automatically.
     Pin it if you have more than one, or output ever switches to the speakers.

  3. Open at Login
     Click the menu bar icon and tick it.

Then check your work:

  ratebridge status
  ratebridge probe

Automation access for Apple Music is requested the first time it plays.
See README.md for daily use and troubleshooting.
NEXT
