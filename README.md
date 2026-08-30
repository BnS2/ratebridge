# ratebridge

Makes your DAC's sample rate follow whatever is actually playing.

```
 kHz                 ← the menu bar item: unit above, rate below
  96
────────────────────────────────
M2s — 96 kHz
Following Musicer
Resting to 48 kHz in 108s
────────────────────────────────
✓ Enabled
────────────────────────────────
Output Device                  ▸
Settings…
Details                        ▸
Quit
```

## The problem

macOS never changes an output device's sample rate on its own, and most players
cannot ask it to. Anything built on AVAudioEngine has no
`AudioObjectSetPropertyData` in the binary at all — the capability is absent,
not merely unused — so it renders into whatever format the device already holds.

Play a 96 kHz file while Audio MIDI Setup says 44.1 kHz and macOS quietly
resamples it. Your DAC never sees the original.

`ratebridge` closes that gap: it works out what is playing, at what rate, and
sets the device to match — then returns it to a resting rate when the music
stops.

## What makes it different

**It does not need to know your player.** Any app holding audio files open is
read directly. Apps worth special handling get a rule, and a rule is one
command, not a code change.

**It never guesses.** Every tier either states a rate or says nothing. A source
it cannot read is skipped, not obeyed — because a wrong rate written into a live
stream is worse than no write at all.

**There is a window when you want one.** Settings shows which app is setting the
rate right now, which ones are excluded from your device, and where it parks when
nothing plays. It is not a second source of truth: the window and the CLI read
and write the same store, so neither can drift from the other.

**It says why.** Every switch is logged with its reason and its evidence:

```
[00:17:12] 48000 → 44100 Hz   Pahintulot — shirebound  [FLAC / 44.1kHz / 628kbps]
[01:54:02] 44100 → 96000 Hz   afplay — tone-96000.wav  [generic]
[03:14:08] 48000 → 44100 Hz   Musicer — Purple Rain.flac  (2 files open at
                              different rates; this is the one the player is
                              showing)  [file — no rate on screen]
```

## Requirements

- macOS 14.2 or newer (it needs `kAudioHardwarePropertyProcessObjectList`)
- Xcode command line tools, for `swiftc`
- A DAC worth doing this for

## Install

```bash
git clone https://github.com/<you>/ratebridge.git
cd ratebridge
./install.sh
```

The installer checks the OS version, builds, bundles and launches. Three steps
it cannot do for you, and it prints them:

1. **Accessibility** — System Settings → Privacy & Security → Accessibility, add
   `/Applications/Ratebridge.app`. Wanted by any player that keeps several
   tracks open at once — reading what it shows on screen is what says which of
   them you are hearing — and required by players that publish no scripting
   interface and must be read from their own window.
2. **Pin your DAC** — `ratebridge device "Your DAC"`. Skip it if exactly one USB
   DAC is attached; it is found automatically.
3. **Open at Login** — tick it in the menu bar menu.

`./uninstall.sh` removes everything, including the launch agent.

## Use

It runs as a menu bar app and needs nothing day to day. The CLI is for setting
it up and for finding out what it thinks:

```bash
ratebridge status      # device, rate, what is playing, and the verdict
ratebridge probe       # what every detector sees — the debugging command
ratebridge match       # set the device to the current source's rate, now
ratebridge rest        # back to the resting rate
ratebridge on / off    # start and stop the bridge
```

Everything tunable lives in settings rather than in the source, because a
rebuild re-signs the bundle and voids its Accessibility grant:

```bash
ratebridge config idle-rate 48000          # where it goes when nothing plays
ratebridge config idle-delay 30            # seconds of silence first
ratebridge rule com.example.player ui      # read the rate off its own window
ratebridge rule com.example.player 48000   # or just declare it
ratebridge priority com.apple.Music com.spotify.client
```

Adding a player costs a command, not a re-grant.

## How it decides

**What is playing** comes from `kAudioHardwarePropertyProcessObjectList` — every
process actually holding an output stream, filtered to the device you are
targeting.

**At what rate** comes from the first tier that can answer:

| Tier | How | Example |
|---|---|---|
| The player says so | Apple Events | Apple Music's `sample rate of current track` |
| The player shows so | Accessibility | a window or status bar reading `FLAC / 96kHz` |
| The file says so | `afinfo` | any app with audio files open |
| Known constant | rule table | Spotify 44.1, browsers 48 |

The file tier is the one that makes this player-agnostic, and it is where the
care went. A real player holds several files at once — the one playing, the one
queued, sometimes the last few — often at different rates. So:

- if every open file agrees, that is the answer;
- if they disagree, the player is asked which one, by matching its **on-screen
  title** against the filenames, then its **on-screen duration** against the
  container length — an Accessibility read, and the reason step 1 of the install
  is worth doing whichever player you use;
- if neither identifies exactly one file, it returns nothing.

The player is read from its windows *and its status bar item*, so a player
parked in the menu bar with no window open is still followed. The same read
picks up the transport button — by macOS convention it shows the action pressing
it would take, so "Play" on screen means paused — which is the only way to know
for a player that publishes no scripting interface.

**When several things play at once**, the highest-ranked live source wins and
the rest are resampled, which is what macOS was doing to all of them anyway.
Every write names what it was chosen over. A source that cannot state a rate is
skipped rather than allowed to veto.

**When nothing plays**, the device returns to a resting rate — 48 kHz by
default, because that is what system sounds and browsers want. A merely *paused*
player gets a much longer grace period than a finished session.

## Per-app routing

macOS has no per-app output setting. Every tool that adds one — FineTune,
SoundSource, Loopback, Audio Hijack, a BlackHole chain — taps the process and
carries its audio elsewhere. That tap is **private**: the system tap list reads
empty while a redirect is running, and `kAudioProcessPropertyDevices` goes on
reporting where the app *renders*.

What follows from that depends on one thing — whether your target device is also
the system output.

**When it is** (no router, DAC selected in Sound settings), CoreAudio's report is
the answer. An app it puts on another device is on another device, and nothing
needs declaring.

**When it is not**, nothing about routing is measurable. A redirected app reports
the system output because that is where it renders; an app that is *not*
redirected reports the same thing. The two are indistinguishable, so ratebridge
assumes anything playing reaches your device and you mark the exceptions:

| What is happening | Tell it |
|---|---|
| This app's sound comes out somewhere else — a browser, a chat app | `ratebridge rule <id> off` (Settings: **Excluded**) |
| This app reaches my device and I want it ignored anyway | the same mark; one effect, one control |

`status` marks each playing app `[not on <device>]` when it is excluded, and
`probe` says whether being counted was measured, declared or assumed.

`ratebridge routed add <id>` still exists as an explicit override — it wins over
the assumption — but it is rarely needed now. It matters mainly if you later pin
the target to the system output, where the assumption does not apply.

Nothing here names a particular utility. What is described is a state — *this
app's sound does or does not come out of my target device* — not whose software
put it there.

## What it will not do

- **Read the rate from the audio stream.** The rate is a property of the file,
  and every client resamples before a sample reaches the audio path — so a
  process tap reports the *device* rate (measured: a 44.1 kHz file on a 96 kHz
  device reads back 96000), and a stereo mixdown tap reports its own fixed
  format. MediaRemote's now-playing dictionary is entitlement-gated and comes
  back empty. There is no third place to look.
- **Follow a player that shows nothing and holds ambiguous files.** It will say
  so rather than pick.
- **Make browsers accurate.** WebKit decodes outside Core Audio's codec path and
  emits no rate events. 48 kHz is the Web Audio default and every streaming
  service uses it, so a constant is exactly as accurate as measurement.
- **Prevent a wedged `coreaudiod`.** A rate write is what a DAC occasionally
  chokes on, and it is also the whole job. ratebridge bounds its own calls so it
  reports the condition in about five seconds instead of hanging, and enforces a
  floor between writes to provoke it less often. See **Troubleshooting**.

## Troubleshooting

```bash
ratebridge probe        # what every detector sees, tier by tier
ratebridge files <pid>  # which open files a process has, and their rates
ratebridge routed       # per-app routing declarations
```

**The menu bar shows ⚠.** The bridge is deliberately not switching, and the menu
says why — usually a source it cannot read, or audio playing on a device other
than the one it targets.

**Nothing happens at all.** Check `ratebridge status` for a line reading
`⚠ output`: a pinned target that is not the system output will correctly do
nothing, for ever, unless something routes audio to it.

**Every audio app on the Mac freezes.** That is `coreaudiod`, not ratebridge —
confirm with `system_profiler SPAudioDataType`, which will hang too. Re-plug the
DAC, or `sudo killall coreaudiod`.

## Testing

```bash
./verify.sh --no-audio   # 36 checks: policy parsing, settings, matchers
./verify.sh              # plays exact-rate tones and checks the device followed
```

The audible suite generates 440 Hz tones at 44.1 / 48 / 96 / 176.4 / 192 kHz, so
a run is deterministic where a music library is not. It refuses to run — rather
than scoring you — when the target is not the system output, or when something
is already playing that would outrank the tones.

The matcher tests are lifted out of `Sources/main.swift` at test time rather than
copied, because a copy that drifts is a test that lies.

## Licence

MIT. See [LICENSE](LICENSE).
