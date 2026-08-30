#!/bin/bash
# Acceptance test: play tones of known rate and check the device followed.
#
# Everything else in this project is verified against whatever happened to be in
# a music library, which makes a failure hard to reproduce and a pass hard to
# trust. These tones are generated at exact rates, so a run is deterministic.
#
#   ./verify.sh            play through afplay (the generic file tier)
#   ./verify.sh vlc        play through VLC (the VLC rule)
#
# Requires the daemon or Ratebridge.app to be running. Audible: it plays a quiet
# 440 Hz tone at each rate.
set -uo pipefail
cd "$(dirname "$0")"

RB="${RATEBRIDGE:-$HOME/.local/bin/ratebridge}"
PLAYER="${1:-afplay}"

# ---------------------------------------------------------------- offline ----
# Everything that can be checked without making a sound or touching a DAC.
#
# It exists because the audible suite needs hardware that may be absent, asleep,
# or — as on 2026-08-28 — wedged, and "we could not test any of it" is a bad
# answer to "did that refactor break anything". These cases cover the parts most
# likely to rot: policy parsing, settings round-trips, and the promise that the
# configuration commands keep working when the audio server does not.
if [ "${1:-}" = "--no-audio" ]; then
    [ -x "$RB" ] || { echo "error: $RB not found — run ./install.sh"; exit 1; }
    P=0; F=0
    check() {  # check <name> <expected-substring> <command...>
        local name="$1" want="$2"; shift 2
        local got; got="$("$@" 2>&1)"
        if printf '%s' "$got" | grep -qF -- "$want"; then
            printf "  PASS  %s\n" "$name"; P=$((P+1))
        else
            printf "  FAIL  %s\n        wanted: %s\n        got:    %s\n" \
                   "$name" "$want" "$(printf '%s' "$got" | head -2)"
            F=$((F+1))
        fi
    }

    # Settings are real and shared with a running bridge, so snapshot them.
    SNAP="$(mktemp -t ratebridge-settings)"
    defaults export com.bns.ratebridge "$SNAP" 2>/dev/null || echo > "$SNAP"
    restore() { defaults import com.bns.ratebridge "$SNAP" 2>/dev/null; rm -f "$SNAP"; }
    trap restore EXIT

    echo "offline checks"

    check "help works"                 "ratebridge —"      "$RB" --help
    check "unknown command is rejected" "unknown command"  "$RB" nonsense-command

    # Policy forms round-trip through settings, with case preserved. `ui:Musicer`
    # lowercased to `ui:musicer` once, and pgrep -x is case-sensitive, so the rule
    # looked right in `rule` output and never matched the app.
    # input form -> how `rule` renders it back. They differ for the parameterised
    # forms, which is the whole reason to assert on the rendered value.
    for pair in "ui=ui" "ui:MyPlayer=ui:MyPlayer" "script=script" "file=file" \
                "file:44100=file(44100)" "48000=48000" "off=off"; do
        form="${pair%%=*}"; shown="${pair#*=}"
        "$RB" rule com.example.test "$form" >/dev/null 2>&1
        check "rule round-trips: $form" "$shown" sh -c "\"$RB\" rule | grep com.example.test"
    done
    "$RB" rule com.example.test default >/dev/null 2>&1
    if "$RB" rule | grep -q com.example.test; then
        printf "  FAIL  rule default drops the override\n"; F=$((F+1))
    else
        printf "  PASS  rule default drops the override\n"; P=$((P+1))
    fi
    check "bad policy is rejected"      "cannot read"      "$RB" rule com.example.test wat

    check "priority round-trips"        "com.example.a"    sh -c \
        "\"$RB\" priority com.example.a com.example.b >/dev/null && \"$RB\" priority"
    "$RB" priority default >/dev/null 2>&1

    check "conflict accepts priority"   "priority"         "$RB" config conflict priority
    check "conflict accepts hold"       "hold"             "$RB" config conflict hold
    check "conflict rejects nonsense"   "conflict is"      "$RB" config conflict sideways
    "$RB" config conflict priority >/dev/null 2>&1

    check "manual-override accepts 0"   "no longer yield"  "$RB" config manual-override 0
    check "manual-override accepts 300" "300s"             "$RB" config manual-override 300
    check "manual-override rejects text" "needs seconds"   "$RB" config manual-override soon

    check "config lists new keys"       "conflict"         "$RB" config
    check "ignore lists built-ins"      "qemu"             "$RB" ignore

    # Per-app routing is invisible to CoreAudio, so it can only be declared. The
    # declaration is what makes a DAC fed by a per-app router followable at all;
    # if it stops round-tripping, the bridge silently rests through every track.
    "$RB" routed add com.example.routed >/dev/null 2>&1
    check "routed round-trips"          "com.example.routed" "$RB" routed
    # Assert on the removal itself, not on the list being empty — the list is a
    # real user setting and a test must not care whether it is otherwise in use.
    check "routed remove drops it"      "no longer counts"   \
          "$RB" routed remove com.example.routed
    check "routed rejects nonsense"     "usage"              "$RB" routed nonsense x

    # The wiring the matchers cannot see. `identifyPlayingFile` is pure and was
    # always correct; the bug was that only the `ui` branch ever handed it
    # anything to match, so every other tier asked it to identify a track from an
    # empty list and got nil for ever. A pure-function test passes either way, so
    # assert the structure instead: openFileRate must prime the reader itself
    # when its caller had nothing, or the whole file tier is Musicer-only again.
    if awk '/^func openFileRate/,/^}/' Sources/main.swift \
       | grep -q 'PlayerUIReader.readNative(pid: pid)'; then
        P=$((P+1)); echo "  PASS  file tier primes the reader for any player"
    else
        F=$((F+1)); echo "  FAIL  file tier primes the reader for any player"
    fi

    # The same class of regression one level up: a player the user added a rule
    # for must count as a session player, or pausing it rests the DAC on the
    # short 30s delay instead of the 120s one meant for an open player.
    if awk '/^var sessionPlayerBundleIDs/,/^}/' Sources/main.swift \
       | grep -q 'settings.dictionary(forKey: "rules")'; then
        P=$((P+1)); echo "  PASS  user-added players count as session players"
    else
        F=$((F+1)); echo "  FAIL  user-added players count as session players"
    fi

    # The pure decisions, lifted out of Sources/main.swift and run against
    # fixtures: which of several open files a rate is read from, and whether a
    # process counts for the managed device at all. A wrong answer in the first
    # writes a wrong rate into a live stream; a wrong answer in the second
    # decides whose rate is written, and whether the speakers are muted over it.
    # Neither needs a DAC to catch, and both are lifted rather than copied —
    # a copy that drifts is a test that lies.
    GEN="$(mktemp -t ratebridge-matchers).swift"
    if python3 test/matchers.py "$GEN" 2>/dev/null \
       && swiftc -O "$GEN" -o "${GEN%.swift}" 2>/dev/null; then
        echo
        if "${GEN%.swift}"; then
            P=$((P+22))
        else
            F=$((F+1)); echo "  FAIL  matcher suite"
        fi
    else
        F=$((F+1)); echo "  FAIL  matcher suite would not build"
    fi
    rm -f "$GEN" "${GEN%.swift}"

    echo
    echo "pass $P   fail $F"
    [ "$F" -eq 0 ]
    exit $?
fi

RATES="44100 48000 96000 176400 192000"
PASS=0; FAIL=0; SKIP=0

[ -x "$RB" ] || { echo "error: $RB not found — run ./install.sh"; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 required to make tones"; exit 1; }
# Generate the tones on demand rather than committing 6.4 MB of WAV to the repo.
# They are pure functions of a rate and a duration, so a checkout does not need
# to carry them; anything that can run this script can make them.
mkdir -p test/tones
for r in $RATES; do
    [ -f "test/tones/tone-${r}.wav" ] && continue
    echo "generating test/tones/tone-${r}.wav"
    python3 - "$r" <<'PYGEN'
import math, struct, sys, wave
rate = int(sys.argv[1])
seconds, freq, amplitude = 10.0, 440.0, 0.25
frames = int(rate * seconds)
with wave.open(f"test/tones/tone-{rate}.wav", "w") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
    # A short fade at each end. A tone that starts at full amplitude on sample
    # zero clicks, and a click is precisely what this script is listening for.
    fade = int(rate * 0.01)
    data = bytearray()
    for i in range(frames):
        gain = min(1.0, i / fade, (frames - i) / fade)
        v = int(32767 * amplitude * gain * math.sin(2 * math.pi * freq * i / rate))
        data += struct.pack("<hh", v, v)
    w.writeframes(bytes(data))
PYGEN
done

pgrep -f "Ratebridge.app/Contents/MacOS/ratebridge" >/dev/null \
    || "$RB" status 2>/dev/null | grep -q "daemon        ON" \
    || echo "warning: no daemon or app appears to be running — nothing will switch"

device=$("$RB" status | awk '/^device/{$1="";print substr($0,2)}')
echo "target: $device"
echo "player: $PLAYER"
echo

# The tones play to the system output. If the bridge is pinned somewhere else,
# nothing they do can ever reach it, and every rate reports FAIL for a bridge
# that is working perfectly. That is exactly what happened on 2026-08-29: a
# display woke, macOS moved the default output to the built-in speakers, and the
# suite failed 4 of 5 with no hint that it was testing a device nobody was
# playing to. A test that cannot reach its subject must say so, not score it.
# A higher-ranked player already holding the target is not a failure either — it
# is the priority model working — but it makes every tone below it score FAIL.
# This cost two runs: once a browser at a fixed 48 kHz, once a music player
# outranking an unruled `afplay`. Both times the bridge was correct and the
# scoreboard said otherwise.
# Only what actually counts. `status` now lists excluded apps too, marked, so a
# literal read of this line refuses to test a Mac where the only thing playing is
# something the user deliberately took out of the picture.
busy=$("$RB" status | sed -n 's/^playing *//p' \
    | tr ',' '\n' | grep -v '\[excluded\]' | grep -v '\[not on ' | tr '\n' ',' \
    | sed 's/^,*//; s/,*$//')
if [ -n "$busy" ] && [ "$busy" != "nothing" ]; then
    echo "  cannot test — something is already playing on the target:"
    echo "      $busy"
    echo
    echo "  The tones rank below a known player, so they would score FAIL while the"
    echo "  bridge follows that app correctly. Pause it and run again."
    exit 1
fi

# A mismatch used to be fatal here, and under the old model it was: a tone
# playing to the system output could never count for a device pinned elsewhere,
# so every rate scored FAIL for a bridge that was working. That stopped being
# true on 2026-08-30. Anything playing on the system output is now assumed to
# reach the target unless excluded, which is precisely how a redirected app
# behaves — verified with this same `afplay`, which took the DAC to 192 kHz and
# back to 44.1 while rendering on the built-in speakers. So it is a note now, not
# a refusal: the tones will not be audible *on* the target, and the switch mute
# will silence the system output across each write, but the rate the bridge
# chooses is exactly what this suite measures.
mismatch=$("$RB" status | sed -n 's/^⚠ output *//p')
if [ -n "$mismatch" ]; then
    echo "  note — $mismatch"
    echo
    echo "  Testing anyway: the tones count for the target the same way a redirected"
    echo "  app does. They will be audible on the system output, not on the target."
    echo
fi

for rate in $RATES; do
    file="test/tones/tone-${rate}.wav"
    want=$(python3 -c "
r=$rate
print(f'{r//1000} kHz' if r%1000==0 else f'{r/1000:.1f} kHz')")

    # Bail out if the device has gone away. Without this the run keeps hammering
    # a DAC that is no longer there, which is how a test turns into a diagnosis
    # of its own making: on 2026-08-28 the M2s dropped off the USB bus partway
    # through a run and coreaudiod wedged behind it, blocking every audio client
    # on the machine. `ratebridge` now reports that in about five seconds
    # instead of hanging, so honour it and stop.
    if ! "$RB" status >/dev/null 2>&1; then
        echo
        echo "  aborted — the target device is gone, or CoreAudio is not responding:"
        "$RB" status 2>&1 | sed 's/^/    /'
        exit 1
    fi

    # Skip rates this device cannot do, rather than reporting a false failure.
    if ! "$RB" set "$rate" >/dev/null 2>&1; then
        printf "  %-9s SKIP  device does not support it\n" "$rate"
        SKIP=$((SKIP+1)); continue
    fi
    # Park the device somewhere else first, so a pass means it actually moved.
    other=44100; [ "$rate" = "44100" ] && other=48000
    "$RB" set "$other" >/dev/null 2>&1
    # Let the DAC finish relocking before asking it to move again. Back-to-back
    # rate writes are the one thing in this script a real listening session never
    # does, and a USB DAC re-negotiating its endpoint twice a second is exactly
    # the condition under which one drops off the bus.
    sleep 1

    case "$PLAYER" in
        vlc) open -a VLC "$file" 2>/dev/null; sleep 9 ;;
        # Long enough for the bridge to notice a brand-new process. Measured
        # 2026-08-28: ~5s from first sound to the device following, dominated by
        # the 3s process-list cache. A 3s tone expired inside that window, so the
        # whole suite failed 5/5 while the bridge was working correctly — the
        # test was simply shorter than the thing it was testing.
        *)   afplay -v 0.05 "$file" & APID=$!; sleep 8 ;;
    esac

    got=$("$RB" status | awk '/^current rate/{print $3, $4}')

    if [ "$got" = "$want" ]; then
        printf "  %-9s PASS  device followed to %s\n" "$rate" "$got"
        PASS=$((PASS+1))
    else
        printf "  %-9s FAIL  wanted %s, device is at %s\n" "$rate" "$want" "$got"
        FAIL=$((FAIL+1))
    fi

    case "$PLAYER" in
        vlc) osascript -e 'tell application "VLC" to quit' >/dev/null 2>&1 ;;
        *)   kill "$APID" 2>/dev/null; wait "$APID" 2>/dev/null ;;
    esac
    sleep 1
done

echo
echo "pass $PASS   fail $FAIL   skipped $SKIP"
[ "$FAIL" -eq 0 ]
