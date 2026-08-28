// ratebridge — make the output device's sample rate follow what is actually playing.
// macOS 14.2+ (uses kAudioHardwarePropertyProcessObjectList). See README.md.

import AppKit
import CoreAudio
import Foundation
import ServiceManagement

// MARK: - Configuration

/// Shared between the CLI and the .app — they have different bundle identities,
/// so `UserDefaults.standard` would give each its own store.
let settings = UserDefaults(suiteName: "com.bns.ratebridge") ?? .standard

/// Where the device goes when nothing at all is playing.
///
/// 48 kHz, not 44.1. The original 44.1 came from library composition (62% of the
/// collection is 44.1), which is the right answer for *Musicer* and the wrong
/// answer for *idle* — idle is exactly when Musicer is not the consumer.
/// Measured on this machine 2026-08-28: all 14 macOS system sounds are 48 kHz,
/// and every other output device (TYPEC, HDMI, both TANCHJIM endpoints,
/// MacStereoFix) sits at 48 kHz. Browsers are 48 kHz by the Web Audio default.
/// So 48 kHz is what macOS and everything-that-is-not-a-music-player want; the
/// per-track matching then handles the music.
///
/// Runtime-overridable (`ratebridge config idle-rate`) on purpose: changing it
/// must never need a rebuild, because a rebuild re-signs the bundle and voids
/// the Accessibility grant.
var restingRate: Float64 {
    let stored = settings.double(forKey: "idleRate")
    return stored > 0 ? stored : 48000
}

/// How long everything must be silent before dropping back to the resting rate.
///
/// Wall time, not poll count: the loop sleeps 0.25s in musicer mode and 0.5s
/// otherwise, so a poll count would mean two different delays.
///
/// Two values, because a paused player is not a finished session. SPEC gate G4
/// found Musicer releases its output stream while merely *paused*, so one short
/// delay would drop the device to 48 kHz during a coffee break and then relock
/// to 44.1 the moment you press play. While a known player is still running we
/// wait much longer; with none running, the session is genuinely over.
var idleRestDelay: TimeInterval {
    let stored = settings.double(forKey: "idleRestDelay")
    return stored > 0 ? stored : 30
}
var idleRestDelayPlayerOpen: TimeInterval {
    let stored = settings.double(forKey: "idleRestDelayPlayerOpen")
    return stored > 0 ? stored : 120
}

/// Pick the DAC automatically when nothing is pinned — but only when the choice
/// is unambiguous. This machine has three USB audio endpoints (M2s plus two
/// TANCHJIM BUNNY DSP), so "grab the USB one" would be a coin flip. Auto-detect
/// therefore fires only when exactly one USB DAC is present; otherwise we fall
/// back to the system default and say so.
var autoDetectDAC: Bool {
    settings.object(forKey: "autoDetectDAC") == nil
        ? true : settings.bool(forKey: "autoDetectDAC")
}


/// What to do when more than one thing is playing at once.
///
/// The original answer was `hold`: refuse to pick, leave the device alone. The
/// reasoning was measured and is still true — writing a rate that suits one
/// source while another holds a stream at a different rate makes the second
/// one's aggregate device rebuild, and 2026-08-27 that measured 20 aggregate
/// activations in five minutes against 2-3 when the rates agreed.
///
/// But `hold` is too blunt to live with. A browser tab holding an output stream
/// is the normal state of a Mac, and under `hold` that single tab wedges the
/// bridge shut for as long as it is open — so the common case became "does
/// nothing". Worse, `hold` made whole *classes* of source unreachable: Spotify
/// is in `mediaPlayerBundleIDs` and its policy is a constant, so Spotify playing
/// by itself matched no branch except the final "something holds output" and was
/// never once followed.
///
/// `priority` instead picks the highest-ranked live source and accepts that
/// everything below it gets resampled — which is exactly what macOS was doing to
/// all of them before this tool existed. The cost is not hidden: every write
/// that lands while another stream is live says so in the log.
enum ConflictPolicy: String {
    case priority   // follow the highest-ranked live source
    case hold       // refuse to choose; leave the device alone
}

var conflictPolicy: ConflictPolicy {
    ConflictPolicy(rawValue: settings.string(forKey: "conflict") ?? "") ?? .priority
}

/// How long a rate we did not write suppresses our own writes, in seconds.
///
/// FineTune's picker writes the same property we do. Without this, setting a rate
/// by hand there and having the bridge overwrite it on the next poll is a fight
/// the user cannot win and cannot see the cause of. Observing a rate we did not
/// write is unambiguous evidence that something else — or someone — has an
/// opinion, so we yield for a while and say so. 0 disables it.
var manualOverrideGrace: TimeInterval {
    settings.object(forKey: "manualOverrideGrace") == nil
        ? 300 : settings.double(forKey: "manualOverrideGrace")
}

/// Explicit source ranking, highest first. Empty means "use the rule table
/// order", which is already ordered deliberately and documented as first-match-
/// wins. `ratebridge priority` edits this without a rebuild.
var priorityOrder: [String] {
    (settings.array(forKey: "priority") as? [String]) ?? []
}

/// Rank a bundle id: lower sorts higher. Unranked sources sort last, in rule
/// table order, so adding a rule never silently outranks a player you chose.
func sourceRank(_ bundleID: String, table: [(bundleID: String, policy: Policy)]) -> Int {
    if let index = priorityOrder.firstIndex(of: bundleID) { return index }
    if let index = table.firstIndex(where: { $0.bundleID == bundleID }) {
        return priorityOrder.count + index
    }
    return Int.max
}

/// Always active because its process tap never stops; must not count as "audio playing".
let excludedBundleIDs: Set<String> = [
    "com.finetuneapp.FineTune",
]

/// The same exclusion, for processes that have no bundle id to be listed by.
///
/// The Android emulator holds an output stream continuously, for as long as it
/// runs, whether or not it is making a sound — exactly like FineTune's process
/// tap. Counted as "audio is playing" it does two things, one of them silent:
/// the conflict guard already ignored it, but the *idle* rule reads
/// `activeOutputProcesses().isEmpty`, so with the emulator running the set is
/// never empty, silence is never observed, and the device never returns to the
/// idle rate. That is the original bug, reintroduced through a side door.
///
/// Overridable at runtime (`ratebridge ignore`), because the next one of these
/// will be some other daemon and finding out must not cost a rebuild.
let builtinExcludedProcessNames: Set<String> = [
    "qemu-system-aarch64",   // Android emulator
]

var excludedProcessNames: Set<String> {
    let extra = (settings.array(forKey: "ignoredProcesses") as? [String]) ?? []
    return builtinExcludedProcessNames.union(extra)
}

/// Apps whose sound comes out of the target device even though CoreAudio says it
/// renders somewhere else.
///
/// This is the counterpart to `rule <id> off`. Both exist because per-app routing
/// on macOS is done with process taps, and a tap is private: the redirect is real,
/// audible, and completely invisible to every property this tool can read. So the
/// two directions are declared:
///
///   `rule <id> off`      this app's sound does not come out of my target
///   `routed <id>`        this app's sound does come out of my target
///
/// Empty by default, and nothing here names a particular utility — the state
/// being described is "its audio arrives at my DAC", however it got there.
var routedProcesses: Set<String> {
    Set((settings.array(forKey: "routedProcesses") as? [String]) ?? [])
}

func isDeclaredRouted(_ process: AudioProcess) -> Bool {
    let routed = routedProcesses
    guard !routed.isEmpty else { return false }
    if let bundleID = process.bundleID, routed.contains(bundleID) { return true }
    return routed.contains(process.name)
}

/// Apps whose audio counts when deciding whether two sources are fighting.
///
/// The conflict guard exists to stop two *media players* pulling the device to
/// different rates, which causes continuous aggregate churn. A notification chime
/// is not a rival: Pandan playing a two-second break reminder should not stop a
/// track change from being matched. Anything not listed here is ignored for
/// conflict purposes.
let mediaPlayerBundleIDs: Set<String> = [
    "com.wangchujiang.musicer",
    "org.videolan.vlc",
    "com.spotify.client",
    "com.apple.Music",
    "com.apple.Safari",
    "com.apple.WebKit.GPU",
    "com.google.Chrome",
    "com.google.Chrome.helper",
    "com.colliderli.iina",
    "com.apple.QuickTimePlayerX",
    "com.coppertino.VoxMac",
    "app.zen-browser.zen",
    "org.mozilla.firefox",
]

/// How much a rate reading is worth. Surfaced everywhere a rate is reported,
/// because "96 kHz because the player says so" and "96 kHz because we assume
/// this app is always 96 kHz" are very different claims and the difference is
/// invisible once they are both just a number.
enum Confidence: String {
    case measured  // the source itself stated the rate, or we read its file
    case assumed   // a known-constant for this app, not observed
}

enum Policy {
    /// Read the rate the player displays. Ground truth: the player stating what
    /// it is rendering right now.
    /// Read the rate off the player's own window through Accessibility.
    ///
    /// Not Musicer-specific, despite having been written for it: the reader looks
    /// for a static text containing "kHz" among the front window's first group,
    /// which is how every player that shows a format string presents one. The
    /// pid comes from the audio process being evaluated, so no app needs naming.
    /// `process` is only for the diagnostic paths (`probe`, the health thread)
    /// that have a rule but no live audio process to take a pid from.
    case uiReader(process: String?)
    /// afinfo the audio file the player has open. `fallback` is used when the
    /// open set is unreadable (streaming, network source) — nil means "give up
    /// rather than guess".
    case fileBased(fallback: Float64?)
    /// Ask the player itself over Apple Events. Apple Music exposes
    /// `sample rate of current track`, which is a stated fact rather than an
    /// inference — the same tier as Musicer's UI reader.
    case scripted
    /// The rate is a known constant for this source (Spotify 44.1, YouTube 48).
    case fixed(Float64)
    /// Explicitly ignore this app as a rate source.
    case off

    var confidence: Confidence {
        switch self {
        case .uiReader, .fileBased, .scripted: return .measured
        case .fixed, .off:                     return .assumed
        }
    }

    var describe: String {
        switch self {
        case .uiReader(let process): return process.map { "ui:\($0)" } ?? "ui"
        case .scripted:              return "script"
        case .fileBased(let f):      return f.map { "file(\(Int($0)))" } ?? "file"
        case .fixed(let rate):       return "\(Int(rate))"
        case .off:                   return "off"
        }
    }

    /// Parse the CLI/settings form: "ui", "file", "file:44100", "48000", "off".
    static func parse(_ text: String) -> Policy? {
        let value = text.lowercased()
        if value == "ui" { return .uiReader(process: nil) }
        if value.hasPrefix("ui:") {
            return .uiReader(process: String(text.dropFirst(3)))
        }
        if value == "script" { return .scripted }
        if value == "off" { return .off }
        if value == "file" { return .fileBased(fallback: nil) }
        if value.hasPrefix("file:"), let rate = Float64(value.dropFirst(5)) {
            return .fileBased(fallback: rate)
        }
        if let rate = Float64(value), rate > 0 { return .fixed(rate) }
        return nil
    }
}

/// The rules we ship with. Ordered: first match wins when several apps are active.
///
/// Everything below `.uiReader` is file-based where a file can be read, because a
/// declared constant is only ever as good as the assumption behind it — Apple
/// Music at a flat 44.1 kHz is simply wrong for a lossless or hi-res library, and
/// that was the single biggest accuracy gap against Heimdall.
let builtinRuleTable: [(bundleID: String, policy: Policy)] = [
    ("com.wangchujiang.musicer",   .uiReader(process: "Musicer")),
    ("org.videolan.vlc",           .fileBased(fallback: nil)),  // no prefetch
    ("com.colliderli.iina",        .fileBased(fallback: nil)),
    ("com.apple.QuickTimePlayerX", .fileBased(fallback: nil)),
    ("com.coppertino.VoxMac",      .fileBased(fallback: nil)),
    ("com.apple.Music",            .scripted),  // asks Music for the real rate
    // Spotify sits with the players, not after the browsers. This order is now
    // load-bearing: it is the default source ranking, and a music player must
    // outrank a background tab. Spotify streams Ogg Vorbis at 44.1 kHz and its
    // lossless tier is 44.1 too, so the constant is the whole truth available —
    // there is no file to read and its notifications carry no rate.
    ("com.spotify.client",         .fixed(44100)),
    // Browsers last. WebKit decodes outside Core Audio's codec path and emits no
    // rate events, but 48 kHz is the Web Audio default and every streaming
    // service uses it, so the constant is exactly as accurate as measurement.
    ("com.apple.Safari",           .fixed(48000)),  // YouTube is always 48k
    ("com.apple.WebKit.GPU",       .fixed(48000)),
    ("com.google.Chrome",          .fixed(48000)),
    ("com.google.Chrome.helper",   .fixed(48000)),  // Chrome audio runs in the helper
    ("app.zen-browser.zen",        .fixed(48000)),
    ("org.mozilla.firefox",        .fixed(48000)),
]

/// Built-ins with the user's runtime overrides applied.
///
/// Overrides live in UserDefaults rather than the binary so a new app never costs
/// a rebuild — and on this machine a rebuild costs an Accessibility re-grant,
/// which is the most expensive thing we can ask of the user. `ratebridge rule`
/// edits this. An override for an unknown bundle id is appended; one for a known
/// bundle id replaces its policy in place, preserving precedence order.
var ruleTable: [(bundleID: String, policy: Policy)] {
    let overrides = (settings.dictionary(forKey: "rules") as? [String: String]) ?? [:]
    var table = builtinRuleTable.map { entry -> (bundleID: String, policy: Policy) in
        guard let raw = overrides[entry.bundleID], let policy = Policy.parse(raw) else {
            return entry
        }
        return (entry.bundleID, policy)
    }
    let known = Set(builtinRuleTable.map(\.bundleID))
    for (bundleID, raw) in overrides.sorted(by: { $0.key < $1.key })
    where !known.contains(bundleID) {
        if let policy = Policy.parse(raw) { table.append((bundleID, policy)) }
    }
    return table
}

// MARK: - Exit codes (SPEC §6)

enum Exit: Int32 {
    case ok = 0
    case restFailed = 1
    case unsupportedRate = 2
    case writeRefused = 3
    case noDevice = 4
}

func die(_ code: Exit, _ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code.rawValue)
}

// MARK: - CoreAudio helpers

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func getValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 default fallback: T) -> T {
    var addr = address(selector)
    var value = fallback
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else {
        return fallback
    }
    return value
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &cf) == noErr,
          let value = cf?.takeRetainedValue() else { return nil }
    let string = value as String
    return string.isEmpty ? nil : string
}

func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 _ empty: T,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var items = [T](repeating: empty, count: Int(size) / MemoryLayout<T>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &items) == noErr
    else { return [] }
    return items
}

/// The floor between two rate writes to the same device, enforced inside
/// `Device.setRate` so it applies to every caller, CLI included.
let minRateWriteSpacing: TimeInterval = 0.4
var lastRateWriteAt = Date.distantPast

// MARK: - Bounded subprocesses

/// Run a subprocess and return its stdout, or nil if it overruns `timeout`.
///
/// `readDataToEndOfFile()` blocks until the child closes stdout, and a child that
/// never exits blocks it for ever. Every helper this tool shells out to — afinfo,
/// lsof, ps — opens or inspects things that a sick system can make hang.
///
/// Sampled 2026-08-28: the menu bar app's bridge loop was in
/// `audioFileRate` -> `readDataOfLength:` -> `read` for 2305 of 2305 samples,
/// having stopped iterating four minutes earlier. The app was alive, the menu
/// bar icon was drawn, and nothing in the log said anything was wrong. `afinfo`
/// opens the file through AudioToolbox, so an unwell coreaudiod hangs it — the
/// same failure that hung every other audio client on the machine, arriving here
/// through a subprocess where no CoreAudio deadline could see it.
///
/// A killed child is reported as no answer, which every caller already handles:
/// nil means "do nothing", never "guess".
func runBounded(_ executable: String, _ args: [String],
                timeout: TimeInterval = 5) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return nil }

    // Read on another thread: the child can fill the pipe buffer and block on
    // write while we wait for it to exit, which deadlocks the pair.
    let done = DispatchSemaphore(value: 0)
    let box = Box<Data>()
    DispatchQueue.global().async {
        box.value = pipe.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    if done.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        if done.wait(timeout: .now() + 1) == .timedOut, task.isRunning {
            kill(task.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
        }
        note("\((executable as NSString).lastPathComponent) did not answer in "
           + "\(Int(timeout))s — killed it and carried on")
        return nil
    }
    task.waitUntilExit()
    return box.value.flatMap { String(data: $0, encoding: .utf8) }
}

// MARK: - CoreAudio watchdog

/// Run a CoreAudio call with a deadline, or give up on it.
///
/// Every HAL call is IPC to coreaudiod, and when coreaudiod wedges the call
/// blocks in `mach_msg` with no timeout of its own — for ever.
///
/// Observed 2026-08-28: the M2s dropped off the USB bus during a rate change,
/// and afterwards `ratebridge set 44100` sat in `HALC_ProxySystem`'s constructor
/// for over three minutes, still on the *first* CoreAudio call in the process.
/// So did every other audio client on the machine. Nothing was wrong with
/// ratebridge's logic; there was simply nobody left to answer. But with no
/// deadline the tool hangs with no output at all, which is indistinguishable
/// from a crash and is exactly what "it became not responding" looks like.
///
/// A blocked `mach_msg` cannot be cancelled, so the worker thread is abandoned
/// and the caller returns nil. That leaks one thread in a process that is about
/// to exit or skip a poll, which is the cheap half of the trade.
func withAudioDeadline<T>(_ seconds: TimeInterval, _ work: @escaping () -> T) -> T? {
    let done = DispatchSemaphore(value: 0)
    let box = Box<T>()
    let thread = Thread {
        box.value = work()
        done.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    guard done.wait(timeout: .now() + seconds) == .success else { return nil }
    return box.value
}

final class Box<T> { var value: T? }

/// True when coreaudiod answers a trivial query promptly.
func audioServerResponds(within seconds: TimeInterval = 5) -> Bool {
    withAudioDeadline(seconds) {
        _ = getArray(AudioObjectID(kAudioObjectSystemObject),
                     kAudioHardwarePropertyDevices, AudioObjectID(0))
        return true
    } ?? false
}

let audioWedgedAdvice = """
CoreAudio is not responding. Every audio client on this Mac is blocked on
coreaudiod, not just ratebridge — this is a system condition, not a ratebridge
one. It is most often a USB DAC that disappeared during a rate change.

  1. Unplug the DAC, wait a few seconds, plug it back in.
  2. If that does not clear it:  sudo killall coreaudiod
     (it restarts immediately; audio apps may need reopening.)
"""

// MARK: - Output device

struct Device {
    let id: AudioObjectID
    let name: String

    /// What the device is plugged into. `usb ` for a USB DAC, `bltn` built-in,
    /// `virt` a HAL plug-in, `bltp`/`hdmi`/`dprt` display audio, and so on.
    var transportType: UInt32 {
        getValue(id, kAudioDevicePropertyTransportType, default: UInt32(0))
    }

    /// A real external DAC on the USB bus, as opposed to built-in speakers, a
    /// monitor's audio-out, a Bluetooth headset, or a virtual HAL device.
    ///
    /// Bluetooth is deliberately excluded even though it is "external": those
    /// devices negotiate their own rate over the codec and cannot be driven the
    /// way a USB Audio Class 2 DAC can.
    var isUSBDAC: Bool { transportType == kAudioDeviceTransportTypeUSB }

    /// Output devices on the USB bus. On this machine that is three endpoints
    /// (M2s plus two TANCHJIM BUNNY DSP), which is exactly why auto-detect only
    /// commits when the answer is unique.
    static func usbDACs() -> [Device] { allOutputs().filter(\.isUSBDAC) }

    /// All output-capable devices.
    static func allOutputs() -> [Device] {
        getArray(AudioObjectID(kAudioObjectSystemObject),
                 kAudioHardwarePropertyDevices, AudioObjectID(0))
            .compactMap { id -> Device? in
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreamConfiguration,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain)
                var size: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
                      size > MemoryLayout<UInt32>.size else { return nil }
                return Device(id: id, name: getString(id, kAudioObjectPropertyName) ?? "unknown")
            }
    }

    /// The device the bridge acts on.
    ///
    /// Defaults to the system output, but can be pinned by name. Pinning matters:
    /// if output gets switched to the built-in speakers, following the system
    /// default means silently operating on a device that cannot do 96 or 192 kHz,
    /// and the DAC you actually care about never moves.
    /// Resolving a pinned device means enumerating every device and querying each
    /// one's stream configuration. That is far too much work to repeat four times
    /// a second for something that changes only when hardware is plugged in.
    private static var targetCache: (device: Device?, at: Date) = (nil, .distantPast)
    private static let targetTTL: TimeInterval = 3

    static func target() -> Device? {
        let cached = targetCache
        if Date().timeIntervalSince(cached.at) < targetTTL, let device = cached.device,
           device.nominalRate > 0 {   // still live
            return device
        }
        let resolved = resolveTarget()
        targetCache = (resolved, Date())
        return resolved
    }

    /// Why the current target was chosen. Shown in `status`, `device` and the
    /// menu, because "we are driving the wrong device" is the failure that looks
    /// like no failure at all — it cost a whole evening once, with the M2s
    /// sitting at 44.1 while every write landed on the Mac mini speakers.
    private(set) static var targetReason = "system default"

    private static func resolveTarget() -> Device? {
        if let preferred = settings.string(forKey: "preferredDevice"), !preferred.isEmpty {
            if let match = allOutputs().first(where: { $0.name == preferred }) {
                targetReason = "pinned"
                return match
            }
            // Pinned to something that is not plugged in. Falling through to the
            // system default here would silently drive the built-in speakers,
            // so say it instead.
            targetReason = "pinned to \"\(preferred)\" — not connected"
            return nil
        }
        if autoDetectDAC {
            let dacs = usbDACs()
            if dacs.count == 1 {
                targetReason = "auto-detected USB DAC"
                return dacs[0]
            }
            if dacs.count > 1 {
                targetReason = "\(dacs.count) USB DACs present — pin one; "
                             + "using system default"
            }
        }
        if targetReason.isEmpty || !targetReason.contains("USB DACs present") {
            targetReason = "system default"
        }
        return defaultOutput()
    }

    /// Drop the cached target. Called from the hot-plug listener: a device
    /// arriving or leaving is precisely the event the 3-second cache would
    /// otherwise hide.
    static func invalidateTargetCache() { targetCache = (nil, .distantPast) }

    static var isPinned: Bool {
        let preferred = settings.string(forKey: "preferredDevice") ?? ""
        return !preferred.isEmpty
    }

    static func defaultOutput() -> Device? {
        let id = getValue(AudioObjectID(kAudioObjectSystemObject),
                          kAudioHardwarePropertyDefaultOutputDevice,
                          default: AudioObjectID(0))
        guard id != 0 else { return nil }
        return Device(id: id, name: getString(id, kAudioObjectPropertyName) ?? "unknown")
    }

    var nominalRate: Float64 {
        getValue(id, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    var availableRates: [Float64] {
        getArray(id, kAudioDevicePropertyAvailableNominalSampleRates, AudioValueRange())
            .flatMap { $0.mMinimum == $0.mMaximum ? [$0.mMinimum] : [$0.mMinimum, $0.mMaximum] }
            .sorted()
    }

    /// -1 means no process holds exclusive access.
    var hogModeOwner: pid_t {
        getValue(id, kAudioDevicePropertyHogMode, default: pid_t(-1))
    }

    func supports(_ rate: Float64) -> Bool {
        availableRates.contains { abs($0 - rate) < 1 }
    }

    /// Writes the nominal rate and verifies the device took it.
    /// Returns nil on success, or a human-readable reason on failure.
    func setRate(_ rate: Float64) -> String? {
        // Never renegotiate a USB endpoint twice in quick succession.
        //
        // The bridge loop already spaces its writes seconds apart, but nothing
        // enforced that on the CLI, and `verify.sh` parked the device at one rate
        // and immediately set another. On 2026-08-28 the M2s dropped off the USB
        // bus partway through such a run and coreaudiod wedged behind it,
        // blocking every audio client on the machine — FineTune and Apple Music
        // included — until it was restarted by hand.
        //
        // Whether the back-to-back writes caused the drop is not proven. But a
        // USB Audio Class 2 device re-negotiating its endpoint twice inside a
        // few hundred milliseconds is not something any real listening session
        // asks of it, the floor costs nothing that anyone can hear, and the
        // failure it might prevent takes the whole machine's audio down.
        let sinceLastWrite = Date().timeIntervalSince(lastRateWriteAt)
        if sinceLastWrite < minRateWriteSpacing {
            usleep(useconds_t((minRateWriteSpacing - sinceLastWrite) * 1_000_000))
        }
        lastRateWriteAt = Date()

        var addr = address(kAudioDevicePropertyNominalSampleRate)

        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue
        else { return "device reports the sample rate is not settable" }

        var value = rate
        let status = AudioObjectSetPropertyData(id, &addr, 0, nil,
                                                UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else {
            let owner = hogModeOwner
            let hint = owner != -1 ? " (hog mode held by pid \(owner))" : ""
            return "write refused, OSStatus \(status)\(hint)"
        }

        // Remember what we wrote. This is what makes a *foreign* write
        // detectable: FineTune's picker sets exactly this property, and without
        // a record of our own writes there is no way to tell "the user chose
        // 96 kHz by hand" from "the device is where we left it".
        defer { if abs(nominalRate - rate) < 1 { recordOurWrite(device: id, rate: rate) } }

        // The device settles asynchronously; poll rather than assume. Poll finely:
        // the DAC's physical relock is what it is, but a coarse poll adds up to
        // its own interval on top of it, and this sits directly in the path
        // between a track starting and the rate being right.
        for _ in 0..<200 {
            if abs(nominalRate - rate) < 1 { return nil }
            usleep(5_000)
        }
        return "wrote \(Int(rate)) Hz but device settled at \(Int(nominalRate)) Hz"
    }
}

/// The rate ratebridge itself last wrote, and to which device.
///
/// Stored in settings rather than in memory because the writer and the observer
/// are often different processes: `ratebridge set 96000` in a shell, and the
/// daemon that sees the device move a quarter-second later. In memory, the
/// daemon would read its own tool's write as a foreign one and yield to it for
/// five minutes — which would, among other things, make `verify.sh` fail every
/// case, since it parks the device with `set` before each tone.
///
/// Anything that moves the rate *without* going through ratebridge leaves no
/// record here, and is therefore identifiable by exclusion. That is the whole
/// mechanism behind the manual override.
func recordOurWrite(device: AudioObjectID, rate: Float64) {
    settings.set(Double(rate), forKey: "lastWrittenRate")
    settings.set(Int(device), forKey: "lastWrittenDevice")
}

func ourLastWrite() -> (device: AudioObjectID, rate: Float64)? {
    let rate = settings.double(forKey: "lastWrittenRate")
    guard rate > 0, settings.object(forKey: "lastWrittenDevice") != nil else { return nil }
    return (AudioObjectID(settings.integer(forKey: "lastWrittenDevice")), rate)
}

// MARK: - Active audio processes

struct AudioProcess {
    let pid: pid_t
    let bundleID: String?   // nil for bundle-less processes (emulators, daemons)
    let name: String
    let deviceIDs: [AudioObjectID]

    /// Where CoreAudio says this process renders.
    ///
    /// Note *renders*, which is not always where the sound comes out. Anything
    /// that redirects an app by tapping it — FineTune, SoundSource, Loopback,
    /// Audio Hijack, a BlackHole chain — leaves this reporting the app's original
    /// destination, because that is genuinely where it writes its samples before
    /// the tap carries them elsewhere. Verified 2026-08-28: a browser being
    /// actively redirected to the built-in speakers still reported the DAC.
    func uses(_ device: Device) -> Bool { deviceIDs.contains(device.id) }

    /// Whether this process's audio actually comes out of the device we target.
    ///
    /// A player on a different output cannot conflict with ours, so it must not
    /// block a switch — the guard is about churn on one device, not about any
    /// audio existing anywhere. But `uses` alone answers the wrong question on a
    /// Mac with per-app routing, and in both directions:
    ///
    ///   - Routed *away* from the target: CoreAudio still reports it here, so the
    ///     bridge follows a rate for audio that is coming out of another device.
    ///     `ratebridge rule <id> off` is the existing cure.
    ///   - Routed *to* the target: CoreAudio reports it on the system default, so
    ///     the bridge filters it out and rests at the idle rate while the DAC is
    ///     playing a 96 kHz track. Nothing covered this until `routed`.
    ///
    /// A tap is private by design — `kAudioHardwarePropertyTapList` returned zero
    /// taps while a redirect was running — so this can only ever be declared, not
    /// detected. `routed` is that declaration, and it is deliberately about the
    /// *state* an app is in, not about whichever tool put it there.
    func reaches(_ device: Device) -> Bool { uses(device) || isDeclaredRouted(self) }

    /// Bundle id when there is one, else the executable name.
    var label: String { bundleID ?? name }
}

/// Executable name for a pid. Bundle-less processes still hold output streams
/// (the Android emulator does), so they need something readable in `status`.
var processNameCache: [pid_t: String] = [:]

func processName(_ pid: pid_t) -> String {
    // A pid's executable name cannot change while it lives, so this is a pure
    // cache. Without it the daemon spawned `ps` for every audio process on every
    // poll — four times a second, for a value that is constant.
    if let cached = processNameCache[pid] { return cached }
    let name = uncachedProcessName(pid)
    if processNameCache.count > 256 { processNameCache.removeAll() }
    processNameCache[pid] = name
    return name
}

func uncachedProcessName(_ pid: pid_t) -> String {
    let path = (runBounded("/bin/ps", ["-p", String(pid), "-o", "comm="], timeout: 3) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? "pid \(pid)" : (path as NSString).lastPathComponent
}

/// Expand aggregate devices to the real hardware behind them.
///
/// Anything running a process tap — FineTune here, but also Rogue Amoeba tools and
/// eqMac — makes macOS route each app through a `CADefaultDeviceAggregate` wrapper.
/// `kAudioProcessPropertyDevices` then reports that wrapper's ID rather than the
/// DAC's, so a naive ID comparison concludes nothing is playing on the DAC and the
/// bridge silently never fires.
func expandAggregates(_ devices: [AudioObjectID]) -> [AudioObjectID] {
    var result = Set(devices)
    for device in devices {
        for selector in [kAudioAggregateDevicePropertyActiveSubDeviceList,
                         kAudioAggregateDevicePropertyFullSubDeviceList] {
            let subs = getArray(device, selector, AudioObjectID(0))
            result.formUnion(subs)
            // A UID-shaped fallback used to live here; it called Device.allOutputs()
            // inside this nested loop, which enumerates every device and queries each
            // one's stream config. Not worth it — kAudioProcessPropertyDevices in the
            // output scope already returns the real device on this system.
        }
    }
    return Array(result)
}

/// Guards the two caches below.
///
/// They are written by the bridge loop and cleared by `MusicEventWatcher`, which
/// runs its own thread — so a track-change notification could land inside the
/// loop's read. Swift's Dictionary and Array are not atomic, and concurrent
/// mutation is undefined behaviour, not a stale read.
///
/// Observed 2026-08-28: the menu bar app's loop simply stopped iterating. It was
/// alive, the menu still drew, and the log went silent for four minutes while
/// the identical binary run as `ratebridge daemon` followed every tone
/// correctly. The daemon has the same watcher thread; what it does not have is
/// the app's extra main-thread activity racing alongside it.
let cacheLock = NSLock()

var activeProcessCache: (processes: [AudioProcess], at: Date) = ([], .distantPast)
/// Who is playing changes on human timescales; a track change needs sub-second
/// detection. Enumerating every audio process object is IPC to coreaudiod and is
/// by far the most expensive thing in the loop, so it runs on its own slower
/// cadence while the cheap Accessibility read keeps polling fast.
let activeProcessTTL: TimeInterval = 3.0

/// Drop the cached process list. A track change is exactly the moment the 3 s
/// cache is most wrong, and the moment its staleness is most expensive.
func invalidateActiveProcesses() {
    PlayerUIReader.resetScanBackoff()
    cacheLock.lock(); defer { cacheLock.unlock() }
    activeProcessCache = ([], .distantPast)
    openFilesCache.removeAll()
}

/// Processes whose rule is `off`. Invisible to ratebridge in every respect.
///
/// This is the declaration that makes per-app routing work. FineTune can send a
/// browser to the built-in speakers while music goes to the DAC, but that split
/// is invisible from outside: FineTune's taps are **private**, so they do not
/// appear in `kAudioHardwarePropertyTapList` (verified 2026-08-28 — the system
/// tap list was empty with FineTune actively redirecting), and
/// `kAudioProcessPropertyDevices` keeps reporting the browser on the DAC because
/// that is still where it renders before the tap takes it away.
///
/// So the split cannot be detected, only declared:
///
///     ratebridge rule app.zen-browser.zen off
///
/// `off` used to mean "not a rate source, not a blocker", but the process stayed
/// in the active set, which decides whether the device may return to its idle
/// rate. A browser routed elsewhere therefore held the DAC at its last rate for
/// ever — silently, since nothing was playing on it. `off` now means invisible,
/// which is the only reading that matches what the user is declaring.
func isRuledOff(_ process: AudioProcess) -> Bool {
    guard let bundleID = process.bundleID,
          let matched = ruleTable.first(where: { $0.bundleID == bundleID }) else { return false }
    if case .off = matched.policy { return true }
    return false
}

func activeOutputProcesses() -> [AudioProcess] {
    cacheLock.lock()
    if Date().timeIntervalSince(activeProcessCache.at) < activeProcessTTL {
        defer { cacheLock.unlock() }
        return activeProcessCache.processes
    }
    cacheLock.unlock()
    // Enumerating is slow IPC, so it happens outside the lock. Two threads may
    // both refresh; that is wasteful, never wrong.
    let fresh = uncachedActiveOutputProcesses().filter { !isRuledOff($0) }
    cacheLock.lock(); defer { cacheLock.unlock() }
    activeProcessCache = (fresh, Date())
    return fresh
}

func uncachedActiveOutputProcesses() -> [AudioProcess] {
    getArray(AudioObjectID(kAudioObjectSystemObject),
             kAudioHardwarePropertyProcessObjectList, AudioObjectID(0))
        .compactMap { object -> AudioProcess? in
            guard getValue(object, kAudioProcessPropertyIsRunningOutput,
                           default: UInt32(0)) != 0 else { return nil }
            let bundleID = getString(object, kAudioProcessPropertyBundleID)
            if let bundleID, excludedBundleIDs.contains(bundleID) { return nil }
            let pid = getValue(object, kAudioProcessPropertyPID, default: pid_t(0))
            // Bundle-less always-on holders are excluded by executable name.
            if bundleID == nil, excludedProcessNames.contains(processName(pid)) { return nil }
            // MUST be the output scope. In the global scope this comes back empty
            // for every process, which silently reads as "nothing is on our device"
            // and stops the bridge from ever firing.
            let devices = getArray(object, kAudioProcessPropertyDevices, AudioObjectID(0),
                                   scope: kAudioObjectPropertyScopeOutput)
            return AudioProcess(pid: pid, bundleID: bundleID, name: processName(pid),
                                deviceIDs: expandAggregates(devices))
        }
}


// MARK: - Rate resolution

enum Resolution {
    case rate(Float64, because: String, confidence: Confidence)
    case conflict([String: Float64], fallback: Float64)
    case noPolicy(String)
    case unknownRate(String)
}

/// Resolve one rule to a rate, or nil if this source cannot be read right now.
func evaluate(_ rule: (bundleID: String, policy: Policy),
              in active: [AudioProcess]) -> (rate: Float64, detail: String)? {
    switch rule.policy {
    case .off:
        return nil
    case .fixed(let rate):
        return (rate, "\(rule.bundleID) is playing (assumed \(Int(rate)) Hz)")
    case .uiReader(let process):
        // The pid comes from the process we are already looking at, so the reader
        // needs no name and no pgrep. `process` is only a fallback for the app
        // being open while holding no output stream.
        let live = active.first { $0.bundleID == rule.bundleID }
        let label = process ?? rule.bundleID
        let pid = live?.pid ?? uiReaderPID(bundleID: rule.bundleID, process: process)
        let reading = pid.flatMap { PlayerUIReader.read(pid: $0, label: label) }

        // Paused, according to its own transport button. Reported *after* the read
        // above, because that read is what refreshes the button state — checking
        // first would latch the player at whatever it last said.
        //
        // Returning nil rather than filtering the process out is what makes this
        // safe: an unreadable source is already never a veto, so the ranking falls
        // straight through to whatever is below it. Before this, a paused Musicer
        // holding an output stream outranked a *playing* Spotify for as long as it
        // stayed open, and nothing in the log said why.
        if let pid, PlayerUIReader.transportState(pid: pid) == .paused { return nil }
        if let reading { return (reading.rate, reading.detail) }
        // Nothing on screen to read. That is not always a closed window: reported
        // 2026-08-29, Musicer follows correctly in the player style that shows
        // `FLAC / 44.1kHz / …` and holds with a ⚠ in the other two. Whichever the
        // cause, the outcome was the same — the rule matched, the player was
        // plainly playing, and the bridge sat at whatever rate it happened to be
        // at, resampling a track whose real rate was on disk all along.
        //
        // So fall back to the file. This is safe here for the same reason the file
        // reader is safe anywhere: it commits on agreement, or on having watched
        // the queued track open behind the playing one, and otherwise says
        // nothing. It never picks between files it cannot order.
        guard let live else { return nil }
        let showing = PlayerUIReader.visibleTexts(pid: live.pid)
        return openFileRate(pid: live.pid, label: label, showing: showing)
            .map { ($0.rate, $0.detail + "  [file — no rate on screen]") }
    case .scripted:
        return AppleMusicReader.read()
    case .fileBased(let fallback):
        guard let process = active.first(where: { $0.bundleID == rule.bundleID }) else {
            return nil
        }
        let label = (rule.bundleID as NSString).pathExtension
        return openFileRate(pid: process.pid,
                            label: label.isEmpty ? rule.bundleID : label,
                            fallback: fallback)
    }
}

/// The rate the device should be at right now, and why.
///
/// Shares its decision with the bridge loop deliberately. These were two
/// separate implementations and they drifted: the loop learned to rank sources
/// and follow the top one, while this still returned CONFLICT and told you to
/// quit an app — so `ratebridge status` reported a stand-off at the same moment
/// the daemon was happily following Spotify. A status command that disagrees
/// with the daemon is worse than no status command.
func resolveTargetRate(on device: Device? = nil) -> Resolution {
    // Only what actually comes out of the device we are about to write to.
    //
    // This used to consider every process on the machine, which made `status`
    // and `match` disagree with the daemon exactly when it mattered: a track
    // playing out of the built-in speakers resolved a target rate for a DAC that
    // was silent, and `match` would have written it. The daemon has filtered by
    // device all along. A status command that contradicts the daemon is worse
    // than no status command.
    let active = device.map { d in activeOutputProcesses().filter { $0.reaches(d) } }
        ?? activeOutputProcesses()
    guard !active.isEmpty else {
        return .rate(restingRate, because: "nothing is playing — resting rate",
                     confidence: .assumed)
    }

    let table = ruleTable
    func rule(for process: AudioProcess) -> (bundleID: String, policy: Policy)? {
        guard let bundleID = process.bundleID else { return nil }
        return table.first { $0.bundleID == bundleID }
    }

    // A player that is demonstrably paused has not torn down its IO context yet.
    // It is neither a source nor a rival.
    let live = active.filter { PlayerState.of($0.bundleID) != .paused }

    // Ranked candidates: anything with a policy that yields a rate, measured or
    // constant. `off` opts out entirely.
    let sources = live
        .filter { process in
            guard let matched = rule(for: process) else { return false }
            if case .off = matched.policy { return false }
            return true
        }
        .sorted {
            sourceRank($0.bundleID ?? "", table: table)
                < sourceRank($1.bundleID ?? "", table: table)
        }

    // `hold` keeps the original stand-off report: no single device rate suits two
    // sources at different rates, and forcing one rebuilds the other's aggregate
    // every couple of seconds (measured 2026-08-27: 20 activations in five
    // minutes, against 2-3 when the rates agreed).
    if conflictPolicy == .hold, live.count > 1 {
        var targets: [String: Float64] = [:]
        for process in sources {
            guard let matched = rule(for: process),
                  let reading = evaluate(matched, in: active) else { continue }
            targets[matched.bundleID] = reading.rate
        }
        if Set(targets.map { Int($0.value) }).count > 1 {
            return .conflict(targets, fallback: restingRate)
        }
    }

    // Highest-ranked source that can actually state a rate. Walking past one that
    // cannot is the point: Musicer holds an output stream with its window closed,
    // where the AX reader has nothing to read, and it must not veto a readable
    // Spotify one rank below it.
    var firstFailure: Resolution?
    for process in sources {
        guard let matched = rule(for: process) else { continue }
        if let reading = evaluate(matched, in: active) {
            let others = sources.filter { $0.pid != process.pid }.map(\.label)
            let alongside = others.isEmpty ? ""
                : "  (chosen over \(others.joined(separator: ", ")))"
            return .rate(reading.rate, because: reading.detail + alongside,
                         confidence: matched.policy.confidence)
        }
        guard firstFailure == nil else { continue }
        switch matched.policy {
        case .uiReader:
            firstFailure = .unknownRate("\(matched.bundleID) is playing but its rate display "
                              + "could not be read, and its open files do not agree on a rate "
                              + "— player window closed, a player style that shows no format "
                              + "string, or Accessibility not granted")
        case .fileBased:
            firstFailure = .unknownRate("\(matched.bundleID) is playing but no unambiguous "
                              + "audio file to read a rate from (streaming, network source, "
                              + "or several files open at different rates)")
        case .scripted:
            firstFailure = .unknownRate("\(matched.bundleID) is playing but would not answer "
                              + "over Apple Events — grant Automation for Music"
                              + (AppleMusicReader.lastError.isEmpty
                                 ? "" : " (\(AppleMusicReader.lastError))"))
        case .fixed, .off:
            continue
        }
    }

    // Nothing in the table answered. Last resort: any player holding audio files
    // that agree on a rate. This is what covers a player we have never heard of —
    // the generic tier, and the reason a new app does not need a new rule.
    for process in live where !mediaPlayerBundleIDs.contains(process.bundleID ?? "") {
        guard let reading = openFileRate(pid: process.pid, label: process.label) else { continue }
        return .rate(reading.rate, because: reading.detail + "  [generic]",
                     confidence: .measured)
    }

    if let failure = firstFailure { return failure }
    return .noPolicy(active.map(\.label).joined(separator: ", "))
}

// MARK: - Commands

func formatRate(_ rate: Float64) -> String {
    rate.truncatingRemainder(dividingBy: 1000) == 0
        ? "\(Int(rate / 1000)) kHz"
        : String(format: "%.1f kHz", rate / 1000)
}

func apply(_ target: Float64, to device: Device, because reason: String) -> Never {
    let current = device.nominalRate

    guard device.supports(target) else {
        die(.unsupportedRate, "\(device.name) does not support \(formatRate(target)). "
                            + "Supported: \(device.availableRates.map(formatRate).joined(separator: ", "))")
    }

    if abs(current - target) < 1 {
        print("\(device.name) already at \(formatRate(current))  —  \(reason)")
        exit(Exit.ok.rawValue)
    }

    // Writing the rate while any process holds an output IO context makes that
    // process's IO fail to restart (EAGAIN / "StartIO error 35"). Players recover,
    // but it is audible. Merely pausing does not close the window — the engine
    // stays alive — so warn rather than pretend the write was free. A daemon must
    // refuse outright here; see SPEC §7.
    let holders = activeOutputProcesses()
    if !holders.isEmpty {
        print("note: \(holders.map(\.label).joined(separator: ", ")) "
            + "\(holders.count == 1 ? "holds" : "hold") an output stream — "
            + "expect a brief relock (StartIO error 35)")
    }

    if let message = device.setRate(target) {
        die(.writeRefused, message)
    }
    print("\(device.name): \(formatRate(current)) → \(formatRate(target))")
    print("  \(reason)")
    exit(Exit.ok.rawValue)
}

/// A line for the CLI when the target is not where macOS is sending audio, or nil.
///
/// The same blind spot the daemon reports as `elsewhere`, asked as a one-shot: a
/// pinned DAC that is not the system output is a bridge that will correctly do
/// nothing, for ever, without a word about why.
func targetIsNotSystemOutput(_ device: Device) -> String? {
    guard let system = Device.defaultOutput(), system.id != device.id else { return nil }
    return "system output is \"\(system.name)\" — audio reaches "
         + "\"\(device.name)\" only if something routes it there. "
         + "If a per-app router does, declare it: `ratebridge routed add <id>`. "
         + "Otherwise `ratebridge device default` follows the system output."
}

func commandStatus(_ device: Device) -> Never {
    print("device        \(device.name)  [\(Device.targetReason)]")
    if let mismatch = targetIsNotSystemOutput(device) { print("⚠ output       \(mismatch)") }
    print("current rate  \(formatRate(device.nominalRate))")
    print("supported     \(device.availableRates.map(formatRate).joined(separator: ", "))")

    let owner = device.hogModeOwner
    print("hog mode      \(owner == -1 ? "free" : "held by pid \(owner)")")

    let active = activeOutputProcesses()
    if active.isEmpty {
        print("playing       nothing")
    } else {
        // Say which of them actually reach this device. Everything else on the
        // list is audible somewhere, just not somewhere this bridge can act on,
        // and the two used to be printed identically.
        print("playing       " + active.map { process -> String in
            let where_ = process.uses(device) ? ""
                : isDeclaredRouted(process) ? " [routed here]" : " [elsewhere]"
            return "\(process.label) (pid \(process.pid))\(where_)"
        }.joined(separator: ", "))
    }
    print("daemon        \(daemonIsRunning() ? "ON" : "off")")
    let ignored = excludedBundleIDs.sorted() + excludedProcessNames.sorted()
    if !ignored.isEmpty {
        print("ignoring      \(ignored.joined(separator: ", "))")
    }
    print("idle rate     \(formatRate(restingRate))  after "
        + "\(Int(knownPlayerRunning() ? idleRestDelayPlayerOpen : idleRestDelay))s of silence")

    print("")
    switch resolveTargetRate(on: device) {
    case .rate(let target, let reason, let confidence):
        let verdict = abs(device.nominalRate - target) < 1
            ? "match — no change needed"
            : "MISMATCH — `ratebridge match` would set \(formatRate(target))"
        print("target        \(formatRate(target))  [\(confidence.rawValue)]")
        print("reason        \(reason)")
        print("verdict       \(verdict)")
    case .conflict(let targets, let fallback):
        let detail = targets.sorted { $0.key < $1.key }
            .map { "\($0.key) wants \(Int($0.value)) Hz" }.joined(separator: ", ")
        print("target        \(formatRate(fallback))  (conflict fallback)")
        print("verdict       CONFLICT — \(detail).")
        print("              No single rate suits both; forcing one causes audible")
        print("              aggregate-device churn. Quit one source, or accept the")
        print("              resting rate.")
    case .noPolicy(let names):
        print("target        —")
        print("verdict       no policy for: \(names).  Add it to ruleTable in Sources/main.swift")
    case .unknownRate(let why):
        print("target        —")
        print("verdict       \(why)")
    }
    exit(Exit.ok.rawValue)
}

func commandMatch(_ device: Device) -> Never {
    switch resolveTargetRate(on: device) {
    case .rate(let target, let reason, _):
        apply(target, to: device, because: reason)
    case .conflict(let targets, let fallback):
        let detail = targets.sorted { $0.key < $1.key }
            .map { "\($0.key) wants \(Int($0.value)) Hz" }.joined(separator: ", ")
        print("conflict: \(detail)")
        print("no single rate suits both — falling back to the resting rate")
        apply(fallback, to: device, because: "conflict fallback")
    case .noPolicy(let names):
        print("no policy for: \(names) — leaving \(device.name) at \(formatRate(device.nominalRate))")
        exit(Exit.ok.rawValue)
    case .unknownRate(let why):
        print("cannot determine rate: \(why)")
        print("leaving \(device.name) at \(formatRate(device.nominalRate))")
        exit(Exit.ok.rawValue)
    }
}



// MARK: - File-based rate detection

/// Audio files a process currently has open.
/// What `lsof` last reported for a pid, and when.
///
/// `lsof` is a subprocess, and it measured at ~110 ms per call. Once the daemon
/// gained the generic tier it ran one per poll for every player with no rule —
/// four times a second, for a list that changes only at a track boundary. That
/// was 45% of a core for as long as an unrecognised player was active, and it
/// was the single most expensive thing in the loop by an order of magnitude
/// (`[prof] procs 0.0  branch 114.3`).
///
/// Two seconds is short enough that a track change is still picked up inside the
/// existing settle window, and long enough to take the cost off the hot path. A
/// track-change notification clears the cache outright, so the players that can
/// announce themselves do not wait for it at all.
var openFilesCache: [pid_t: (files: [String], at: Date)] = [:]
let openFilesTTL: TimeInterval = 2.0

func openAudioFiles(pid: pid_t) -> [String] {
    cacheLock.lock()
    if let cached = openFilesCache[pid],
       Date().timeIntervalSince(cached.at) < openFilesTTL {
        defer { cacheLock.unlock() }
        return cached.files
    }
    cacheLock.unlock()
    // `lsof` is a subprocess; never hold the lock across it.
    let files = uncachedOpenAudioFiles(pid: pid)
    cacheLock.lock(); defer { cacheLock.unlock() }
    if openFilesCache.count > 64 { openFilesCache.removeAll() }
    openFilesCache[pid] = (files, Date())
    return files
}

/// Drop one pid's cached file list. `watch` needs a fresh sample per tick, and
/// clearing the whole cache would throw away every other player's too.
func invalidateOpenFiles(pid: pid_t) {
    cacheLock.lock(); defer { cacheLock.unlock() }
    openFilesCache[pid] = nil
}

func uncachedOpenAudioFiles(pid: pid_t) -> [String] {
    guard let text = runBounded("/usr/sbin/lsof", ["-p", String(pid), "-Fn"], timeout: 5)
    else { return [] }

    let extensions = ["flac", "m4a", "mp3", "wav", "aiff", "aif", "alac", "ogg", "opus",
                      "dsf", "dff", "ape", "wv", "mka", "mp4", "mkv",
                      // Apple Music streams into extensionless/.tmp cache files;
                      // afinfo reads them fine, so let them through and let the
                      // rate read be the filter.
                      "tmp", "asset", "m4p"]
    // lsof emits one name line per descriptor, so the same file can appear more
    // than once. Dedupe before any count-based logic runs on the result.
    var seen = Set<String>()
    return text.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("n") else { return nil }
        let path = String(line.dropFirst())
        guard extensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return seen.insert(path).inserted ? path : nil
    }
}

var fileInfoCache: [String: (rate: Float64, duration: Double)] = [:]

/// What afinfo knows about a media file: its true rate, and how long it is.
///
/// Duration is here because it is a second, independent way to say *which* file a
/// player is playing. A title has to be spelled the same way on screen as it is
/// on disk; a duration does not care about spelling, language, or whether the
/// library was tagged by a human.
func audioFileInfo(_ path: String) -> (rate: Float64, duration: Double)? {
    if let cached = fileInfoCache[path] { return cached }
    guard let text = runBounded("/usr/bin/afinfo", [path], timeout: 4) else { return nil }
    let lines = text.split(separator: "\n")
    guard let format = lines.first(where: { $0.contains("Data format") }),
          let range = format.range(of: #"[0-9]+(\.[0-9]+)? Hz"#, options: .regularExpression)
    else { return nil }
    let rate = Float64(format[range].replacingOccurrences(of: " Hz", with: "")) ?? 0
    guard rate > 0 else { return nil }

    var duration = 0.0
    if let line = lines.first(where: { $0.contains("duration") }),
       let range = line.range(of: #"[0-9]+(\.[0-9]+)?"#, options: .regularExpression) {
        duration = Double(line[range]) ?? 0
    }
    let info = (rate: rate, duration: duration)
    if fileInfoCache.count > 256 { fileInfoCache.removeAll() }
    fileInfoCache[path] = info
    return info
}

/// True sample rate of a media file.
func audioFileRate(_ path: String) -> Float64? { audioFileInfo(path)?.rate }

/// Normalised for comparing a filename against text on the player's window.
///
/// "Panis ka boy" on screen and `Panis ka boy - GA Chillerong Ghetto.flac` on
/// disk are the same track spelled two ways, so punctuation, spacing and case all
/// have to go before they can be compared.
func squashed(_ text: String) -> String {
    String(String.UnicodeScalarView(
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
}

/// A duration written as `m:ss` or `h:mm:ss`, in seconds.
func parseClock(_ text: String) -> Double? {
    let parts = text.split(separator: ":")
    guard parts.count == 2 || parts.count == 3 else { return nil }
    var total = 0.0
    for part in parts {
        guard part.count <= 2, let value = Double(part), value >= 0 else { return nil }
        total = total * 60 + value
    }
    return total > 0 ? total : nil
}

/// The open file whose name matches text the player is displaying, if exactly one
/// does.
///
/// This answers a question a single `lsof` cannot: of the several files a player
/// holds, which one are you hearing? Observed 2026-08-29 — Musicer held **four**
/// at once, and after a skip the playing file was the *newest*, while in ordinary
/// playback the queued one is opened first. Opened-first and opened-last are each
/// right about half the time, which makes both of them guesses.
///
/// The player is not guessing, though. Even the styles that show no format string
/// still show the title and the artist, so matching that against the filename is a
/// fact about the track being played rather than an inference about descriptors.
///
/// Longest candidate first, and only ever one match: an album called "WILD" would
/// happily match half a library, and a wrong file here is a wrong rate written
/// into a live stream.
func fileMatchingOnScreenText(_ files: [String], showing texts: [String]) -> String? {
    let candidates = texts.map(squashed).filter { $0.count >= 4 }
        .sorted { $0.count > $1.count }
    guard !candidates.isEmpty else { return nil }
    let names = files.map { (path: $0, squashed: squashed(($0 as NSString).lastPathComponent)) }
    for candidate in candidates {
        let hits = names.filter { $0.squashed.contains(candidate) }
        if hits.count == 1 { return hits[0].path }
    }
    return nil
}

/// The open file whose length matches the running time the player is showing.
///
/// The second, independent identifier. A title has to be spelled on screen the way
/// it is on disk — which fails on a library tagged in another language, on files
/// named `01 - track.flac`, and on any player that shows only a clock. A duration
/// has none of those problems.
///
/// Two seconds of tolerance, because a player rounds to the second and container
/// duration is estimated; and still only ever one match, because two tracks of the
/// same length are common and a wrong file is a wrong rate.
func fileMatchingDuration(_ files: [String], showing texts: [String]) -> String? {
    let clocks = texts.compactMap(parseClock)
    guard !clocks.isEmpty else { return nil }
    for clock in clocks {
        let hits = files.filter { path in
            guard let info = audioFileInfo(path), info.duration > 0 else { return false }
            return abs(info.duration - clock) <= 2
        }
        if hits.count == 1 { return hits[0] }
    }
    return nil
}

/// Which open file the player is playing, from anything it is willing to show.
///
/// The order is deliberate: a name match is a stronger claim than a length match,
/// because two tracks of the same length are ordinary and two tracks with the same
/// name are not.
func identifyPlayingFile(_ files: [String], showing texts: [String]) -> String? {
    fileMatchingOnScreenText(files, showing: texts)
        ?? fileMatchingDuration(files, showing: texts)
}

func openFileRate(pid: pid_t, label: String, fallback: Float64? = nil,
                  showing texts: [String] = [])
    -> (rate: Float64, detail: String)? {
    let files = openAudioFiles(pid: pid)
    let rates = files.compactMap { path -> (String, Float64)? in
        audioFileRate(path).map { (path, $0) }
    }
    let distinct = Set(rates.map { Int($0.1) })

    if distinct.count == 1, let (path, rate) = rates.first {
        let extra = rates.count > 1 ? "  (\(rates.count) files, all \(Int(rate)) Hz)" : ""
        return (rate, "\(label) — \((path as NSString).lastPathComponent)\(extra)")
    }
    if distinct.count > 1 {
        // Several files open at different rates. Measured 2026-08-29: Musicer held
        // four at once — three already played, one queued — so "the open files
        // disagree" is the normal state of a real player, not an edge case.
        //
        // Ask the player which one, by matching its own on-screen text against the
        // filenames. When it is not showing anything usable there is still no
        // answer, and no answer is better than a guess: a rate written from the
        // wrong file lands in a live stream and relocks the DAC for nothing.
        guard let playing = identifyPlayingFile(rates.map(\.0), showing: texts),
              let rate = rates.first(where: { $0.0 == playing })?.1
        else { return nil }
        return (rate, "\(label) — \((playing as NSString).lastPathComponent)"
                    + "  (\(rates.count) files open at different rates; this is the "
                    + "one the player is showing)")
    }
    guard let fallback else { return nil }
    return (fallback, "\(label) — no readable file, assuming \(Int(fallback)) Hz")
}

/// Kept as a named entry point: VLC does NOT switch the device rate itself
/// (verified — a 192 kHz file played with the device stuck at 44.1), so it needs
/// the bridge just as much as Musicer does.
func vlcRate(pid: pid_t) -> (rate: Float64, detail: String)? {
    openFileRate(pid: pid, label: "VLC")
}

// MARK: - Play state

/// Whether a player is actually playing, as distinct from holding an output stream.
///
/// These are not the same thing and the difference is the whole problem. CoreAudio
/// reports `IsRunningOutput` for a player that is merely *paused* — its IO context
/// survives the pause and only tears down later (SPEC gate G4). So "two players
/// hold output" usually means "one is playing and one is paused", which the
/// conflict guard used to treat as an unresolvable clash and refuse to act on.
///
/// Where a player can be asked directly, ask. `unknown` is not a failure: it means
/// fall back to the stream-level evidence, which is what we did for everything
/// before.
enum PlayState { case playing, paused, unknown }

/// Whether an app is running right now, by bundle id.
///
/// Every Apple Event in this file is gated on this, and that is not an
/// optimisation — it is a correctness rule, learned the hard way twice in one
/// minute:
///
///  1. `tell application "Music" to ...` **launches Music** if it is not running.
///     A status command that silently opens a music player is unacceptable, and
///     it happened.
///  2. Referring to an app that is not installed can put up a "Where is...?"
///     chooser and block the sender until someone clicks it. `ratebridge status`
///     hung indefinitely this way, and so would the daemon.
///
/// Checking the running-application list first costs microseconds and removes
/// both failure modes outright.
func appIsRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

/// Run a compiled AppleScript without ever being able to hang the caller.
///
/// `NSAppleScript.executeAndReturnError` has no timeout of its own; a busy or
/// wedged target simply never answers. `with timeout` inside the script bounds
/// the Apple Event, and everything here is on the path between a track starting
/// and the rate being correct, so an unbounded wait is not survivable.
func runScript(_ script: NSAppleScript?) -> String? {
    var error: NSDictionary?
    guard let value = script?.executeAndReturnError(&error).stringValue else { return nil }
    return value
}

/// Ask a player its transport state over Apple Events.
///
/// In-process NSAppleScript, compiled once and cached — never `osascript` from the
/// poll loop. Only apps that actually publish a scripting interface appear here;
/// **Musicer does not** (no sdef, no NSAppleScriptEnabled — verified), which is
/// why its state stays `unknown` and its window remains the only signal.
struct PlayerState {
    private static let lock = NSLock()
    private static var scripts: [String: NSAppleScript] = [:]
    private static var cache: [String: (state: PlayState, at: Date)] = [:]
    private static let ttl: TimeInterval = 2

    /// bundle id -> a script returning "playing", "paused" or "stopped".
    private static let sources: [String: String] = [
        "com.apple.Music": """
            with timeout of 2 seconds
                tell application "Music" to return player state as text
            end timeout
            """,
        "org.videolan.vlc": """
            with timeout of 2 seconds
                tell application "VLC"
                    if playing then return "playing"
                    return "paused"
                end tell
            end timeout
            """,
        "com.spotify.client": """
            with timeout of 2 seconds
                tell application "Spotify" to return player state as text
            end timeout
            """,
    ]

    static func of(_ bundleID: String?) -> PlayState {
        guard let bundleID, let source = sources[bundleID] else { return .unknown }
        // Never send an Apple Event to an app that is not already running.
        guard appIsRunning(bundleID) else { return .unknown }
        lock.lock()
        defer { lock.unlock() }

        if let hit = cache[bundleID], Date().timeIntervalSince(hit.at) < ttl {
            return hit.state
        }
        if scripts[bundleID] == nil { scripts[bundleID] = NSAppleScript(source: source) }
        guard let text = runScript(scripts[bundleID]) else {
            // Automation denied, or the app went away mid-query. Unknown, not
            // paused — guessing "paused" here would silently stop following a
            // player that is in fact playing.
            scripts[bundleID] = nil
            return .unknown
        }
        let state: PlayState
        switch text.lowercased() {
        case "playing":          state = .playing
        case "paused", "stopped": state = .paused
        default:                 state = .unknown
        }
        cache[bundleID] = (state, Date())
        return state
    }
}

// MARK: - Apple Music reader

/// Reads the playing track's rate straight out of Apple Music.
///
/// Music.app holds **no audio file open at all** — verified with `lsof`, which
/// shows only databases and caches. Playback runs through MediaPlaybackCore, so
/// the file-based reader can never see the track and quietly falls back to a
/// constant. That constant was 44100, and it is wrong: an Apple Music AAC stream
/// measured here reported 48000.
///
/// `sample rate of current track` is the player stating a fact about what it is
/// playing, which puts this in the same tier as the Musicer UI reader rather than
/// with the assumed constants.
///
/// Uses NSAppleScript in-process, not `osascript`. Spawning a subprocess from the
/// poll loop is the specific mistake SPEC "Measuring CPU" records; a compiled
/// NSAppleScript costs one Apple Event round trip. Cached anyway, because that
/// round trip still crosses a process boundary and the answer only changes at a
/// track boundary.
///
/// Needs Automation permission for Music (NSAppleEventsUsageDescription is in the
/// bundle). Denied, it returns nil and the bridge does nothing — same failure
/// shape as the Accessibility path.
struct AppleMusicReader {
    private static let lock = NSLock()
    private static var script: NSAppleScript?
    private static var cached: (rate: Float64, detail: String, at: Date)?
    /// Short, because this value is what decides *when* the rate changes.
    ///
    /// It was 2 s, and that alone made Apple Music unseamless: the new track's
    /// rate could be seen up to two seconds late, so the write landed well after
    /// audio had started and the DAC relock was heard as a gap rather than as
    /// part of the track's first instant. This is the same trap SPEC records for
    /// the osascript path, reintroduced through a cache.
    ///
    /// The TTL is now only a backstop — `MusicEventWatcher` invalidates on the
    /// track-change notification, which is what actually delivers the timing.
    private static let ttl: TimeInterval = 0.5

    /// Drop the cached reading. Called the instant Music says the track changed.
    static func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
    }
    private(set) static var lastError = ""

    static func read() -> (rate: Float64, detail: String)? {
        lock.lock()
        defer { lock.unlock() }

        if let cached, Date().timeIntervalSince(cached.at) < ttl {
            return (cached.rate, cached.detail)
        }

        if script == nil {
            // `player state is playing`, not `is not stopped`. A paused player
            // still answers with a track, and following one lets a paused app beat
            // a playing one to the device.
            script = NSAppleScript(source: """
                tell application "Music"
                    if player state is not playing then return ""
                    set t to current track
                    return ((sample rate of t) as text) & "|" & (name of t) & "|" & (kind of t)
                end tell
                """)
        }
        var error: NSDictionary?
        guard let result = script?.executeAndReturnError(&error).stringValue else {
            lastError = (error?["NSAppleScriptErrorMessage"] as? String)
                ?? "Apple Events refused — grant Automation for Music"
            // A failed compile leaves a poisoned script object; rebuild next time.
            script = nil
            return nil
        }
        lastError = ""

        let parts = result.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 1, let rate = Float64(parts[0]), rate > 0 else { return nil }
        let title = parts.count > 1 ? String(parts[1]) : "current track"
        let kind = parts.count > 2 ? String(parts[2]) : ""
        let detail = "Apple Music — \(title)\(kind.isEmpty ? "" : "  [\(kind)]")"
        cached = (rate, detail, Date())
        return (rate, detail)
    }
}

// MARK: - Player UI reader (ground truth)

/// Reads the sample rate straight off a player's own window.
///
/// This is the only signal that is correct by construction. Everything else we
/// tried describes the wrong track:
///   - MediaRemote's assetURL is entitlement-gated on macOS 15.4+ (verified dead).
///   - The CoreAudio decoder log fires on load AND on prefetch, in interleaved
///     bursts, and is silent while a track actually plays.
///   - lsof reports files Musicer has opened, which with shuffle on are the tracks
///     it is about to play, not the one you are hearing.
///
/// Musicer displays "FLAC / 44.1kHz / 996kbps" for the playing track. That string
/// is the player stating what it is rendering right now — the same thing VLC knows
/// internally and acts on. Reading it costs ~0.17s via System Events.
///
/// Requires Accessibility permission for whatever runs this (System Events).
/// If the player window is closed the query returns nothing and we do nothing.
struct PlayerUIReader {
    struct Reading { let rate: Float64; let detail: String }

    /// True when this process holds an Accessibility grant. Definitive, unlike
    /// inferring it from a failed read.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Read the player's static texts through the Accessibility API directly.
    ///
    /// The osascript path costs ~170ms per read, which forces a slow poll, which
    /// puts the rate switch 2-3s into the new track — after music has started, so
    /// the DAC relock is audible as an interruption rather than part of the
    /// track's first instant. Talking to AX directly is ~1ms and allows a poll
    /// fast enough that the switch lands before you hear anything.
    /// Guards every access to the caches below.
    ///
    /// These are static mutable state reached from more than one thread — the
    /// bridge loop, the menu's Match Now, and `probe`. Swift arrays are not
    /// atomic, so an unsynchronised concurrent read and write here is undefined
    /// behaviour outright; the milder and much more common symptom is one thread
    /// clearing the cache while another is mid-read, which drops that read into
    /// the slow path and re-walks Musicer's whole AX tree. Each walk is
    /// synchronous IPC that Musicer's main thread has to service, so a burst of
    /// them is audible as ticking during playback.
    private static let lock = NSLock()

    /// The element that turned out to hold the format string. Every AX call is a
    /// synchronous IPC into the player, so re-walking app -> windows -> ... on each
    /// poll costs dozens of round trips for a chain that is stable for as long as
    /// the window is. Cache it and only walk again when it stops answering.
    private static var cachedGroup: (element: AXUIElement, pid: pid_t)?
    /// The handful of child elements that actually carry the format string and
    /// track title. Of ~15 static texts in the player group, only these change in
    /// a way we care about, and reading just them turns ~16 IPC round trips per
    /// poll into 3.
    private static var cachedFields: [AXUIElement] = []

    /// When a full window scan last ran, so a failed one is not repeated on every
    /// poll.
    ///
    /// The scan below is bounded, but it is still dozens of synchronous IPC calls
    /// into the player, and in musicer mode the loop polls four times a second.
    /// "Shows no rate" is not a rare state: the window can be closed, and Musicer
    /// switches between Mini, Standard and Large Cover players — reported
    /// 2026-08-29 as reading correctly in one of the three and holding with a ⚠ in
    /// the other two. Either state lasts for hours, and without a cooldown each
    /// would pay for a whole walk four times a second for the duration. A
    /// successful scan caches its elements and never comes back here.
    private static var lastScanAt = Date.distantPast
    /// What the last scan saw, whether or not it contained a rate.
    ///
    /// The styles that show no format string still show the title and artist, and
    /// that is enough to say which of a player's open files is the one playing.
    /// Kept from the same walk rather than costing a second one.
    private static var lastTexts: (pid: pid_t, texts: [String])?
    /// What the transport button looked like on the last walk.
    ///
    /// A play/pause button says which state the player is in, because by macOS
    /// convention it shows the action pressing it would take: "Play" visible means
    /// paused. Verified 2026-08-29 against Musicer, which flips both the
    /// description (`Play`/`Pause`) and the SF Symbol identifier
    /// (`play.fill`/`pause.fill`) — and those symbol names are what almost every
    /// macOS player uses for that button.
    ///
    /// This matters because a paused player that holds its output stream outranks
    /// a playing one below it, for as long as it stays open. Apple Events answer
    /// this for the apps that are scriptable; for the ones that are not, their own
    /// window has been saying it all along.
    private static var lastTransport: (pid: pid_t, state: PlayState, at: Date)?
    private static var scanCooldown: TimeInterval = minScanCooldown
    private static let minScanCooldown: TimeInterval = 2.0
    private static let maxScanCooldown: TimeInterval = 4.0

    static func readNative(pid: pid_t) -> [String]? {
        guard pid > 0, AXIsProcessTrusted() else { return nil }
        lock.lock()
        defer { lock.unlock() }

        // Fast path: read only the cached fields.
        if let cached = cachedGroup, cached.pid == pid, !cachedFields.isEmpty {
            let values = cachedFields.compactMap { element -> String? in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                                    &value) == .success else { return nil }
                return value as? String
            }
            // Still the right elements only if the format field still looks like one.
            if values.count == cachedFields.count,
               values.contains(where: { $0.lowercased().contains("khz") }) {
                return values
            }
        }
        cachedGroup = nil
        cachedFields = []

        guard Date().timeIntervalSince(lastScanAt) >= scanCooldown else { return nil }
        lastScanAt = Date()

        var seen: [String] = []
        for (_, window) in roots(of: pid) {
            // The window title too. Musicer's is just "Musicer", but VLC, IINA and
            // QuickTime put the track there, and it rides along on a round trip we
            // are already making.
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString,
                                             &titleValue) == .success,
               let title = titleValue as? String, !title.isEmpty {
                seen.append(title)
            }
            let found = scan(window)
            seen += found.texts
            lastTexts = (pid, seen)
            if found.transport != .unknown { lastTransport = (pid, found.transport, Date()) }
            guard let parent = found.formatParent else { continue }
            cachedGroup = (parent, pid)
            cacheFields(of: parent)
            scanCooldown = minScanCooldown
            return found.texts
        }
        // Back off. A window that has no rate on it now very probably still has
        // none in two seconds — it is a player style, or a closed window, and both
        // last for hours. Every scan is IPC that the player's own main thread has
        // to service, so repeating a hopeless one on a fixed short interval is a
        // tax on the app we are trying to follow. Capped low, and reset by
        // anything that means the picture just changed, so opening the window or
        // switching style is noticed in seconds rather than eventually.
        scanCooldown = min(scanCooldown * 2, maxScanCooldown)
        return nil
    }

    /// Whatever text the player is showing, from the most recent walk.
    ///
    /// Deliberately not a fresh scan: `read` runs first on every poll and refreshes
    /// this as a side effect, and the answer only changes at a track boundary —
    /// which resets the backoff anyway.
    static func visibleTexts(pid: pid_t) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastTexts, last.pid == pid else { return [] }
        return last.texts
    }

    /// Play state as the player's own transport button reports it, from the most
    /// recent walk. `.unknown` when it showed neither, or has not been walked.
    /// A stale reading expires rather than sticking. The walk that refreshes this
    /// only happens while the player is being evaluated, so a value that could
    /// outlive its own refresh would be a player latched to "paused" for ever.
    static func transportState(pid: pid_t) -> PlayState {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastTransport, last.pid == pid,
              Date().timeIntervalSince(last.at) < 10 else { return .unknown }
        return last.state
    }

    /// Look again on the next poll. Called when something has plainly changed —
    /// a track boundary, a play/pause — because that is also when a window is
    /// opened or a player style switched, and a backoff earned during an hour of
    /// silence should not outlive it.
    static func resetScanBackoff() {
        lock.lock(); defer { lock.unlock() }
        scanCooldown = minScanCooldown
        lastScanAt = .distantPast
    }

    /// Everywhere a player might be saying what it is playing: every window, and
    /// its status bar item.
    ///
    /// `windows.first` was enough for exactly one Musicer layout, and it is the
    /// wrong question in general — a player can have a library or settings window
    /// in front of the one showing the format string, and Musicer answers with two
    /// windows at once.
    ///
    /// The status bar item matters more. "Is the player window open?" was the most
    /// common thing this reader ever had to say, and it is a question about window
    /// management rather than about music: a player parked in the menu bar is
    /// still playing. Verified 2026-08-29 — with **zero** windows and no menu
    /// open, Musicer's extras menu still carried the title, the artist, the album
    /// and its transport buttons. That is enough to name the file being played and
    /// to know whether it is paused, which is everything this reader wants.
    ///
    /// Reading a menu's attributes does not open it or send it any event.
    private static func roots(of pid: pid_t) -> [(label: String, element: AXUIElement)] {
        let app = AXUIElementCreateApplication(pid)
        var found: [(String, AXUIElement)] = []

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString,
                                         &value) == .success,
           let windows = value as? [AXUIElement] {
            for (index, window) in windows.prefix(8).enumerated() {
                found.append(("window \(index)", window))
            }
        }
        var extras: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString,
                                         &extras) == .success, let extras {
            found.append(("status bar", extras as! AXUIElement))
        }
        return found
    }

    /// Walk one window for static text, stopping well short of the playlist.
    ///
    /// The direct path this replaces — window -> first group -> its immediate
    /// static-text children — is simply where Musicer puts the format string in
    /// one particular player style. Nothing makes that true of the next player, or
    /// of the same player in another style, and when it is not true the reader
    /// reports "no rate shown" for a rate that is on screen.
    ///
    /// Unbounded recursion is not the answer either: it descends the playlist
    /// table (hundreds of rows, each its own subtree) on every poll, measured at
    /// ~200% of a core. So the walk is capped three ways — depth, a node budget,
    /// and any container fat enough to be a list of tracks is not entered at all.
    private static func scan(_ window: AXUIElement)
        -> (formatParent: AXUIElement?, texts: [String], transport: PlayState) {
        var texts: [String] = []
        var parent: AXUIElement?
        var transport: [String] = []
        var budget = 150
        walk(window, parent: nil, depth: 0, budget: &budget,
             texts: &texts, formatParent: &parent, transport: &transport)
        return (parent, texts, readTransport(transport))
    }

    /// Turn the transport button's label into a play state.
    ///
    /// Only when exactly one of the two is on screen. A window showing both a Play
    /// and a Pause control is telling us nothing about which state it is in, and
    /// `unknown` keeps the player in the running — the same rule the Apple Events
    /// path already follows, because guessing "paused" silently stops following a
    /// player that is in fact playing.
    private static func readTransport(_ labels: [String]) -> PlayState {
        let lowered = labels.map { $0.lowercased() }
        let saysPause = lowered.contains { $0 == "pause" || $0.hasPrefix("pause.") }
        let saysPlay = lowered.contains { $0 == "play" || $0.hasPrefix("play.") }
        if saysPause && !saysPlay { return .playing }
        if saysPlay && !saysPause { return .paused }
        return .unknown
    }

    /// Roles that hold a collection rather than a panel. Only skipped when they
    /// are actually large — a two-row list is not the playlist, and a player's
    /// info panel is sometimes inside a scroll area.
    private static let collectionRoles: Set<String> = [
        kAXTableRole, kAXOutlineRole, kAXListRole, kAXRowRole, kAXScrollAreaRole,
    ]

    private static func walk(_ element: AXUIElement, parent: AXUIElement?, depth: Int,
                             budget: inout Int, texts: inout [String],
                             formatParent: inout AXUIElement?,
                             transport: inout [String]) {
        guard depth < 8, budget > 0, texts.count < 40 else { return }
        budget -= 1

        // Transport controls announce themselves by description ("Play") or by the
        // SF Symbol behind them ("play.fill"). Take both; players differ in which
        // they expose, and neither costs an extra walk.
        for key in [kAXDescriptionAttribute, kAXIdentifierAttribute] {
            var label: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, key as CFString, &label) == .success,
               let text = label as? String, !text.isEmpty {
                let lowered = text.lowercased()
                if lowered.hasPrefix("play") || lowered.hasPrefix("pause") {
                    transport.append(text)
                }
            }
        }

        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString,
                                         &value) == .success,
           let text = value as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            texts.append(text)
            if formatParent == nil, text.lowercased().contains("khz") {
                // The parent, not the text itself: the fast path re-reads this
                // element's siblings to pick up the title and artist too.
                formatParent = parent ?? element
                // Enough to pick up the title and artist sitting next to it, and
                // then stop: the rest of the window is not going to say anything
                // this reader wants, and every node costs the player a round trip.
                budget = min(budget, 8)
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                            &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement], !children.isEmpty
        else { return }

        var roleValue: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString,
                                                 &roleValue) == .success
            ? (roleValue as? String ?? "") : ""
        if children.count > 12, collectionRoles.contains(role) { return }
        if children.count > 64 { return }

        for child in children {
            walk(child, parent: element, depth: depth + 1, budget: &budget,
                 texts: &texts, formatParent: &formatParent, transport: &transport)
        }
    }

    /// What the reader can actually see, window by window. For `probe` only:
    /// uncached and unthrottled, because this is a person asking once, and the
    /// question it answers — "is the rate on screen at all in this player style?"
    /// — is exactly the one the bridge cannot answer from its log.
    static func describeWindows(pid: pid_t) -> [String] {
        guard pid > 0 else { return ["no pid to read"] }
        guard AXIsProcessTrusted() else {
            return ["Accessibility not granted to this binary"]
        }
        let all = roots(of: pid)
        guard !all.isEmpty else {
            return ["nothing to read — no windows and no status bar item"]
        }
        return all.map { label, root in
            let found = scan(root)
            let shown = found.texts.prefix(8)
                .map { $0.replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " | ")
            return "\(label): \(found.formatParent == nil ? "no kHz text" : "kHz found")"
                 + "  \(shown.isEmpty ? "(no static text)" : shown)"
        }
    }

    /// Remember the elements carrying the format string and the following title /
    /// artist fields, so later polls can read those directly.
    private static func cacheFields(of group: AXUIElement) {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(group, kAXChildrenAttribute as CFString,
                                            &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }

        var elements: [AXUIElement] = []
        var values: [String] = []
        for child in children {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString,
                                                &value) == .success,
                  let text = value as? String else { continue }
            elements.append(child)
            values.append(text)
        }
        guard let formatIndex = values.firstIndex(where: { $0.lowercased().contains("khz") })
        else { return }
        // Format field plus the next few (duration, title, artist) — enough for
        // parse() to build both the rate and the display name.
        let end = min(formatIndex + 4, elements.count)
        cachedFields = Array(elements[formatIndex..<end])
    }

    static func query(process: String) -> String {
        "tell application \"System Events\" to tell process \"\(process)\" "
            + "to get value of static texts of group 1 of front window"
    }

    /// Last osascript failure, so a permission denial is reportable instead of
    /// looking identical to "nothing playing".
    static var lastError: String = ""

    static func read(pid: pid_t, label: String = "the player") -> Reading? {
        if let fields = readNative(pid: pid) {
            lastError = ""
            if let reading = parse(fields: fields) { return reading }
            lastError = "\(label)'s window is open but shows no rate"
            return nil
        }
        if !isTrusted {
            lastError = "ACCESSIBILITY denied — add Ratebridge under "
                      + "Privacy & Security > Accessibility"
            return nil
        }
        // Deliberately no osascript fallback here. It spawns a process, and this
        // runs twice a second: when the player window is closed the native read
        // returns nil every poll, so the fallback fired continuously and cost
        // ~114ms per poll — more than everything else in the loop combined.
        // `probe` still offers the osascript path for diagnosis.
        //
        // Two different failures, and telling them apart is the difference between
        // "open the window" and "this player never shows a rate". Musicer's Mini
        // and Large Cover styles are the second, and so is its status bar item.
        lastError = visibleTexts(pid: pid).isEmpty
            ? "nothing to read from \(label) — no window and no status bar item"
            : "\(label) is showing a track but no rate; reading its file instead"
        return nil
    }

    /// Shared parsing for both read paths.
    static func parse(fields rawFields: [String]) -> Reading? {
        let fields = rawFields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let format = fields.first(where: { $0.lowercased().contains("khz") }),
              let range = format.range(of: #"[0-9]+(\.[0-9]+)?\s*kHz"#,
                                       options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let digits = format[range]
            .replacingOccurrences(of: "kHz", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        guard let kHz = Double(digits), kHz > 0 else { return nil }
        // Fields may start at the format string (cached fast path) or at the top of
        // the group (first read). Anchor on the format field either way.
        let formatIndex = fields.firstIndex(of: format) ?? 0
        let titleStart = formatIndex + 2
        let title = fields.count > titleStart
            ? fields[titleStart...].filter { !$0.isEmpty }.prefix(2).joined(separator: " — ")
            : ""
        let detail = title.isEmpty ? format : "\(title)  [\(format)]"
        return Reading(rate: Float64((kHz * 1000).rounded()), detail: detail)
    }

    static func readViaOSAScript(process: String) -> Reading? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", query(process: process)]
        let pipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe
        guard (try? task.run()) != nil else {
            lastError = "could not launch osascript"; return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            let raw = (String(data: errData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // -1743: not authorised to send Apple events (Automation).
            // -25211 / "assistive access": Accessibility.
            if raw.contains("-1743") || raw.lowercased().contains("not allowed to send") {
                lastError = "AUTOMATION denied — allow Ratebridge to control "
                          + "System Events (Privacy & Security > Automation)"
            } else if raw.lowercased().contains("assistive") || raw.contains("-25211") {
                lastError = "ACCESSIBILITY denied — add Ratebridge under "
                          + "Privacy & Security > Accessibility"
            } else {
                lastError = raw.isEmpty ? "osascript exited \(task.terminationStatus)" : raw
            }
            return nil
        }
        lastError = ""
        return parse(fields: text.split(separator: ",").map(String.init))
    }
}

// MARK: - Daemon

let agentLabel = "com.bns.ratebridge"
let agentPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist"
let agentLog = NSHomeDirectory() + "/Library/Logs/ratebridge.log"
let installedBinary = NSHomeDirectory() + "/.local/bin/ratebridge"

/// Poll cadence. The process list is cheap to read; the decoder log is not, so
/// this is deliberately unhurried.
let pollInterval: TimeInterval = 0.5
/// A target must hold for this many consecutive polls before we act on it.
/// Decode events arrive in bursts (SPEC §4); this is what stops the thrash.
let requiredStablePolls = 3   // 3 x 0.5s = 1.5s settle
/// Never write more often than this, whatever the signal does.
let minSecondsBetweenWrites: TimeInterval = 2
/// Returning to the resting rate waits much longer than a normal switch. A browser
/// tab grabs and releases its output stream constantly (ads, pauses, autoplay), and
/// without this the device flaps 48000 -> 44100 -> 48000 within seconds, clicking
/// each time. Silence has to persist before we act on it — see `idleRestDelay`,
/// which measures it in wall time so the two poll cadences cannot disagree.

/// When the last output stream went away, or nil while something is playing.
var silentSince: Date?

/// Apps whose mere presence means "a listening session is in progress".
///
/// Deliberately NOT `mediaPlayerBundleIDs`, which includes browsers. A browser is
/// open essentially always, so counting it here would leave the long idle delay in
/// permanent effect and the short one would never run. A *music player* sitting
/// open and paused is the case this exists for.
let sessionPlayerBundleIDs: Set<String> = [
    "com.wangchujiang.musicer",
    "org.videolan.vlc",
    "com.spotify.client",
    "com.apple.Music",
    "com.colliderli.iina",
    "com.coppertino.VoxMac",
]

/// Whether a music player is still open, even if it holds no output stream right
/// now. A paused Musicer is a session in progress; nothing open is a session that
/// ended. SPEC gate G4 found Musicer releases its output stream while merely
/// paused, so without this split a coffee break would drop the device to the idle
/// rate and relock on resume.
func knownPlayerRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { app in
        guard let bundleID = app.bundleIdentifier else { return false }
        return sessionPlayerBundleIDs.contains(bundleID)
            && !excludedBundleIDs.contains(bundleID)
    }
}

/// How long a source that has stopped answering keeps its claim on the device,
/// provided it is still holding an output stream.
///
/// Between two Apple Music tracks the player state is briefly not `playing`, so
/// Music drops out of the candidate list for a second or two. Without a hold-off
/// the next-ranked source — in practice a browser tab sitting at a constant
/// 48 kHz — wins that gap and the device relocks twice per track change:
///
///   [20:58:41] 48000 → 44100 Hz   Apple Music — It Is Well  (over zen)
///   [20:58:53] 44100 → 48000 Hz   zen is playing (assumed 48000 Hz)  (over Music)
///   [20:59:02] 48000 → 44100 Hz   Apple Music — I Will Not Be Afraid  (over zen)
///
/// A gap between tracks is not the end of a listening session, and a background
/// tab should not be able to claim the DAC during one.
let lowerRankHoldOff: TimeInterval = 8

/// Recent rate changes, newest first. Shown in the menu — the log file answers
/// "what happened last night", but the thing you actually want mid-listen is the
/// last few switches without leaving the menu bar.
var switchHistory: [String] = []
let switchHistoryLimit = 8

func recordSwitch(_ from: Float64, _ to: Float64, _ why: String) {
    let entry = "\(stamp())  \(formatRate(from)) → \(formatRate(to))   \(why)"
    switchHistory.insert(entry, at: 0)
    if switchHistory.count > switchHistoryLimit { switchHistory.removeLast() }
}

enum DaemonMode: String {
    /// The default. Rank every live source and follow the best one that can state
    /// a rate — see `ConflictPolicy`.
    ///
    /// This was called `musicer`, which was never what it did. It has always been
    /// "follow players, rank them, do not thrash", and naming it after one app
    /// made the whole daemon read as Musicer-specific on a Mac that has never had
    /// Musicer installed. `--musicer` is still accepted so an existing launch
    /// agent keeps working across the upgrade.
    case follow
    case live    // follow every app in the rule table, on the old single-target path
    case safe    // like live, but only write when nothing holds an output stream
}

func shell(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    guard (try? task.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// A player's pid by executable name, whether or not it currently holds an
/// output stream — the file watcher needs to see opens even while paused.
var processPIDCache: [String: (pid: pid_t?, at: Date)] = [:]
let processPIDTTL: TimeInterval = 5

func pidOf(process name: String) -> pid_t? {
    // Spawning pgrep four times a second to learn something that changes only
    // when the app restarts is pure waste. Re-check occasionally, and at once if
    // the cached pid has died.
    if let cached = processPIDCache[name],
       Date().timeIntervalSince(cached.at) < processPIDTTL,
       let pid = cached.pid, kill(pid, 0) == 0 {
        return pid
    }
    let out = shell("/usr/bin/pgrep", ["-x", name]).output
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = out.split(separator: "\n").first.flatMap { pid_t($0) }
    processPIDCache[name] = (pid, Date())
    return pid
}

/// A pid for a `.uiReader` rule when there is no live audio process to take one
/// from — `probe` and the reader-health thread. The bundle id is authoritative;
/// the process name is the fallback for an app whose bundle id is not registered.
func uiReaderPID(bundleID: String, process: String?) -> pid_t? {
    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        return app.processIdentifier
    }
    if let process { return pidOf(process: process) }
    return nil
}

/// The first `.uiReader` rule in the table, with a pid if its app is running.
/// Used by the diagnostic paths, which have no audio process in hand.
func activeUIReaderRule() -> (bundleID: String, process: String?, pid: pid_t)? {
    for entry in ruleTable {
        guard case .uiReader(let process) = entry.policy else { continue }
        if let pid = uiReaderPID(bundleID: entry.bundleID, process: process) {
            return (entry.bundleID, process, pid)
        }
    }
    return nil
}

func daemonIsRunning() -> Bool {
    // Match the label exactly. The .app has the same bundle identifier, so it
    // registers as "application.com.bns.ratebridge.<n>.<n>" — a substring match
    // reports the daemon as running when only the menu bar app is.
    shell("/bin/launchctl", ["list"]).output
        .split(separator: "\n")
        .contains { line in
            line.split(separator: "\t").last.map(String.init) == agentLabel
        }
}

func stamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// MARK: - Logging

private var lastNote = ""
private var lastNoteCount = 0
private let noteLock = NSLock()

/// Print a timestamped line, collapsing an immediate repeat into a count.
///
/// A log that fills with one repeated line is a log nobody reads, and this file
/// has been exactly that: 977 consecutive `error: no default output device`
/// lines, in which the one interesting event would have been invisible. Repeats
/// are reported when the message finally changes, so nothing is lost — only the
/// 976 duplicate copies of it.
func note(_ message: String) {
    noteLock.lock()
    if message == lastNote {
        lastNoteCount += 1
        noteLock.unlock()
        return
    }
    let repeats = lastNoteCount
    lastNote = message
    lastNoteCount = 0
    noteLock.unlock()
    if repeats > 0 { print("[\(stamp())]    … repeated \(repeats)x") }
    print("[\(stamp())] \(message)")
}

/// Keep the log from growing without bound.
///
/// Called once at daemon start: a long-lived background process that appends
/// for months otherwise leaves a file nobody can open. Truncating to the tail
/// keeps the recent history, which is the part anyone ever reads.
func rotateLogIfLarge(_ path: String, limit: Int = 4 << 20) {
    guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
          size > limit else { return }
    guard let handle = FileHandle(forReadingAtPath: path) else { return }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(size - (limit / 2)))
    guard let tail = try? handle.readToEnd() else { return }
    try? tail.write(to: URL(fileURLWithPath: path))
}

/// Live state, published for the menu bar UI.
var bridgeEnabled = true
var bridgeDeviceName = "—"
/// Set when audio is playing, but not on the device we are pointed at.
///
/// Nothing is broken when this is true and nothing happens either: apps render to
/// the system output, the bridge watches its pinned target, and every poll
/// concludes — correctly — that its device is idle. From outside, that is the
/// same picture as a bridge that has stopped working. Observed 2026-08-29: a
/// display woke, macOS moved the default output to the built-in speakers, and the
/// audible suite failed 4 of 5 while the bridge behaved exactly as designed and
/// logged nothing but "idle".
var bridgeElsewhere: String?
var bridgeCurrentRate: Float64 = 0
var bridgeSourceLabel = "nothing"
var bridgeLastAction = ""
/// Whether the UI reader can actually see the player. Under launchd or without an
/// Accessibility grant it returns nil, which is indistinguishable from "nothing to
/// do" unless we track it explicitly.
var bridgeReaderStatus = "checking…"
/// Set when the bridge is deliberately declining to switch, with the reason.
var bridgeHolding: String?

/// When the bridge loop last got a reading out of Musicer. Published so reader
/// health can be reported without a second thread doing its own AX reads —
/// see the health loop for why that mattered.
var lastReaderSuccess: Date?

func commandDaemon(mode: DaemonMode) -> Never {
    runBridgeLoop(mode: mode)
    exit(Exit.ok.rawValue)
}

/// Set when something happened that invalidates the debounce — a DAC arriving, or
/// a player announcing a new track. The loop clears it.
var forceReevaluate = false

/// Wakes the bridge loop early.
///
/// The loop used to `Thread.sleep`, so even an instant signal waited out the rest
/// of the current tick. When the thing being waited for is a track boundary,
/// those milliseconds are the difference between the relock landing in the gap
/// and landing over the music.
let loopWake = DispatchSemaphore(value: 0)

/// Sleep until `seconds` elapse, or until something signals `loopWake`.
///
/// The semaphore *counts*, which is wrong for a wake-up flag. Spotify and Apple
/// Music both post a notification on play, pause and every track change, and any
/// that arrive while the loop is busy leave their signals banked. The next N
/// sleeps then return instantly and the loop spins through N polls at full tilt
/// — worst at exactly the moment it is doing the most work. Draining the
/// backlog after each wait turns "how many signals arrived" into "did any
/// signal arrive", which is what a wake-up actually means.
func bridgeSleep(_ seconds: TimeInterval) {
    _ = loopWake.wait(timeout: .now() + seconds)
    while loopWake.wait(timeout: .now()) == .success {}
}

/// Listens for players announcing a track change, so the bridge reacts to a push
/// instead of noticing on its next poll.
///
/// Music.app has published `com.apple.Music.playerInfo` since the iTunes days.
/// Verified 2026-08-28: it fires on every track change and on play/pause, with
/// Name, PersistentID and Player State — everything except the sample rate, which
/// is then one 42 ms Apple Event away. Polling for the same information costs
/// 42 ms per read and is still late; this is both cheaper and faster.
///
/// Distributed notifications are delivered through a run loop. The menu bar app
/// has one on the main thread, but `ratebridge daemon` does not — its main thread
/// is the bridge loop — so this runs its own.
final class MusicEventWatcher {
    private var thread: Thread?

    func start() {
        guard thread == nil else { return }
        let thread = Thread {
            let center = DistributedNotificationCenter.default()
            for name in ["com.apple.Music.playerInfo",
                         "com.spotify.client.PlaybackStateChanged"] {
                center.addObserver(forName: NSNotification.Name(name),
                                   object: nil, queue: nil) { _ in
                    // Cheap and idempotent: drop the cached rate, clear the
                    // debounce, and wake the loop. The loop still applies every
                    // safety rule — this only changes *when* it looks, never what
                    // it is allowed to do.
                    AppleMusicReader.invalidate()
                    invalidateActiveProcesses()
                    forceReevaluate = true
                    loopWake.signal()
                }
            }
            RunLoop.current.run()
        }
        thread.name = "ratebridge.player-events"
        thread.start()
        self.thread = thread
    }
}

/// Watches for DACs arriving and leaving.
///
/// Without it the 3-second target cache is exactly wrong at the one moment it
/// matters: unplug the M2s and the bridge keeps writing to a stale AudioObjectID
/// until the cache expires; plug it back in and it comes up at whatever rate its
/// firmware defaults to, with nothing to correct it until the next track change.
final class DeviceHotplugWatcher {
    private var known: Set<String> = []
    private var installed = false

    func start() {
        guard !installed else { return }
        installed = true
        known = Set(Device.allOutputs().map(\.name))

        var addr = address(kAudioHardwarePropertyDevices)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main
        ) { [weak self] _, _ in self?.devicesChanged() }
        if status != noErr {
            print("[\(stamp())] hot-plug listener unavailable (OSStatus \(status)); "
                + "device changes will be picked up on the next cache expiry")
        }
    }

    private func devicesChanged() {
        // The cache is the whole point of the listener: invalidate first, then
        // report, so anything reading Device.target() after this sees the truth.
        Device.invalidateTargetCache()
        let now = Set(Device.allOutputs().map(\.name))
        for gone in known.subtracting(now).sorted() {
            print("[\(stamp())] device disconnected — \(gone)")
        }
        for arrived in now.subtracting(known).sorted() {
            print("[\(stamp())] device connected — \(arrived)")
            // A DAC comes back at its firmware default. Clear the debounce so the
            // next poll re-evaluates immediately instead of treating the new
            // device's rate as a settled state we already agreed with.
            forceReevaluate = true
            // And forget any accumulated silence. While the device was away,
            // nothing could hold an output stream *on it*, which looks exactly
            // like a quiet room — so a reconnect would arrive with the idle timer
            // already expired and rest instantly. Observed 2026-08-28: the M2s
            // re-enumerated, rested 96k->48k in the same second, then switched
            // straight back to 96k six seconds later for the track that had never
            // stopped playing. Two relocks, both avoidable, at the exact moment
            // the DAC was least stable.
            silentSince = nil
        }
        known = now
    }
}

func runBridgeLoop(mode: DaemonMode) {
    setbuf(stdout, nil)
    rotateLogIfLarge(agentLog)

    // Nothing below this may touch the HAL until coreaudiod answers.
    //
    // The loop's own deadline was not enough, because startup gets there first:
    // `DeviceHotplugWatcher.start()` enumerates every output device as its first
    // act, and on a wedged audio server that blocks for ever. The app came up,
    // drew its menu bar icon, and then never logged another line — which is
    // precisely what "I can see the menubar but it isn't working" looks like.
    var waited = false
    while !audioServerResponds() {
        waited = true
        bridgeDeviceName = "no audio"
        bridgeCurrentRate = 0
        bridgeHolding = "CoreAudio is not responding"
        note("CoreAudio is not responding — waiting for coreaudiod. Every audio "
           + "client on this Mac is blocked, not just ratebridge. Usually a USB "
           + "DAC that vanished during a rate change: re-plug it, or "
           + "`sudo killall coreaudiod`.")
        bridgeSleep(10)
    }
    if waited {
        note("CoreAudio is answering again — resuming")
        bridgeHolding = nil
    }

    let hotplug = DeviceHotplugWatcher()
    hotplug.start()
    let playerEvents = MusicEventWatcher()
    playerEvents.start()
    note("ratebridge up — mode: \(mode.rawValue), conflict: \(conflictPolicy.rawValue)")

    // Prove the UI reader works from THIS process. Under launchd the Accessibility
    // grant differs from a shell, and a denied read just returns nil — which is
    // indistinguishable from "nothing to do" unless we say so explicitly.
    // Reader health, reported for the life of the process rather than for the
    // first five minutes.
    //
    // This used to give up after 10 attempts. That made the one state you most
    // need to see invisible: grant Accessibility twenty minutes after launch and
    // the reader starts working with nothing in the log to say so, leaving "the
    // grant did not take" and "the grant took and nothing has played since"
    // looking identical. Both happened, and cost an evening of guessing.
    //
    // `AXIsProcessTrusted()` is checked separately from a successful read,
    // because "not granted" and "granted but Musicer's window is closed" need
    // different actions from the user and only the first is a permissions
    // problem. Transitions are logged; steady state is silent.
    if mode == .follow { DispatchQueue.global().async {
        var lastStatus = ""
        while true {
            let trusted = PlayerUIReader.isTrusted
            // Whatever app the rule table points at, not a hardcoded one.
            let uiApp = activeUIReaderRule()?.process
                ?? ruleTable.first { if case .uiReader = $0.policy { return true }; return false }?
                    .bundleID
                ?? "a UI-read player"
            // Deliberately does NOT read the player itself.
            //
            // It used to, every 15s, forever — racing the bridge loop's four
            // reads a second over the reader's shared AX element cache. When the
            // two collided, the cache was cleared mid-read and the loser re-walked
            // Musicer's entire AX tree: synchronous IPC that Musicer's main thread
            // has to service while it is rendering, heard as ticking. The bridge
            // loop already reads four times a second and publishes the result, so
            // a second reader bought nothing and cost that.
            //
            // `AXIsProcessTrusted()` is a cheap, side-effect-free system call and
            // is the definitive answer on permissions anyway.
            let recent = lastReaderSuccess.map { Date().timeIntervalSince($0) < 30 } ?? false
            let status: String
            if recent {
                status = "OK"
                bridgeReaderStatus = "OK"
                if lastStatus != status {
                    print("[\(stamp())] UI reader OK — reading \(uiApp)")
                }
            } else if !trusted {
                status = "denied"
                bridgeReaderStatus = "NO ACCESS — grant Accessibility"
                if lastStatus != status {
                    print("[\(stamp())] UI reader has no Accessibility grant. "
                        + "System Settings > Privacy & Security > Accessibility: "
                        + "remove any old Ratebridge entry, then add "
                        + "/Applications/Ratebridge.app and switch it on. "
                        + "Removing first matters — TCC will not rebind a stale "
                        + "entry to a changed signature. The app is signed with a "
                        + "stable identity, so once this grant lands a rebuild "
                        + "keeps it; only a change of signing identity voids it.")
                }
            } else {
                status = "idle"
                bridgeReaderStatus = "granted — waiting for \(uiApp)"
                if lastStatus != status {
                    print("[\(stamp())] UI reader is granted; nothing read lately — "
                        + "\(uiApp) idle, or its player window is closed")
                }
            }
            lastStatus = status
            Thread.sleep(forTimeInterval: 15)
        }
    } }

    // Automation health, on the same footing as the Accessibility check above.
    //
    // This half was silent and cost an evening: under launchd the Apple Event to
    // Music is refused, `evaluate` returns nil, the loop falls through to the
    // browser's constant and parks at 48 kHz. Every visible symptom said "the
    // bridge is working and Apple Music is 48 kHz". Nothing said "we were never
    // allowed to ask".
    DispatchQueue.global().async {
        var lastStatus = ""
        while true {
            Thread.sleep(forTimeInterval: 20)
            guard appIsRunning("com.apple.Music") else { lastStatus = ""; continue }
            let ok = AppleMusicReader.read() != nil
            let error = AppleMusicReader.lastError
            let status = ok ? "ok" : (error.isEmpty ? "quiet" : "denied")
            guard status != lastStatus else { continue }
            lastStatus = status
            switch status {
            case "ok":
                note("Apple Music reader OK — Music is answering over Apple Events")
            case "denied":
                note("Apple Music reader DENIED — \(error). "
                   + "System Settings > Privacy & Security > Automation, and allow "
                   + "Ratebridge to control Music. A launchd-started CLI daemon can "
                   + "never be granted this: run /Applications/Ratebridge.app instead.")
            default:
                break   // running but not playing; nothing to report
            }
        }
    }

    var candidate: Float64 = 0
    var stablePolls = 0
    /// The track we last saw. A change here is unambiguous evidence of a new
    /// track, so the rate can be applied at once instead of waiting out a settle.
    /// Timing is the whole point: a relock heard 2-3s into a song is an
    /// interruption, the same relock in its first instant is part of the start.
    var lastSeenTrack = ""
    /// The source we last followed, its rank, and when. See `lowerRankHoldOff`.
    var lastWinner: (bundleID: String, rank: Int, at: Date)?
    /// When `candidate` was first seen. Wall time, not a poll count: the readers
    /// cache for up to half a second, so two consecutive polls can be two reads
    /// of one cached value and prove nothing.
    var candidateSince = Date.distantPast
    var lastWrite = Date.distantPast
    /// While this is in the future, ratebridge does not write. Set when a rate
    /// appears that we did not write. See `manualOverrideGrace`.
    var manualOverrideUntil = Date.distantPast
    /// Consecutive polls that saw a rate we have no record of writing.
    var foreignPolls = 0
    var lastReported: String = ""

    while true {
        // Same deadline as the CLI, for the same reason: a wedged coreaudiod
        // blocks the loop in mach_msg for ever, and a bridge that has stopped
        // polling looks exactly like a bridge with nothing to do.
        guard let resolved = withAudioDeadline(8, { Device.target() }) else {
            bridgeDeviceName = "no device"
            bridgeCurrentRate = 0
            bridgeHolding = "CoreAudio is not responding"
            note("CoreAudio is not responding — coreaudiod did not answer in 8s. "
               + "Usually a USB DAC that vanished during a rate change; "
               + "re-plug it, or `sudo killall coreaudiod`.")
            bridgeSleep(5); continue
        }
        guard let device = resolved else {
            // No target device is not silence. Leaving the timer running here is
            // the other half of the reconnect bug: an unplugged DAC would bank
            // idle time and rest the instant it returned.
            silentSince = nil
            // Say so, in the menu and once in the log. An unplugged DAC used to
            // be indistinguishable from a wedged bridge — the app exited before
            // it could tell you, which is precisely when you need telling.
            bridgeDeviceName = "no device"
            bridgeCurrentRate = 0
            bridgeHolding = Device.targetReason.contains("not connected")
                ? Device.targetReason : "no output device"
            note("waiting — \(bridgeHolding ?? "no output device")")
            bridgeSleep(mode == .follow ? 0.25 : pollInterval); continue
        }

        let profiling = ProcessInfo.processInfo.environment["RATEBRIDGE_PROFILE"] != nil
        let t0 = Date()
        bridgeDeviceName = device.name
        bridgeCurrentRate = device.nominalRate
        let t1 = Date()
        let activeNow = activeOutputProcesses()
        let t2 = Date()
        bridgeSourceLabel = activeNow.isEmpty
            ? "nothing" : activeNow.map(\.label).joined(separator: ", ")
        bridgeElsewhere = activeNow.isEmpty || activeNow.contains(where: { $0.reaches(device) })
            ? nil
            : "\(bridgeSourceLabel) renders to "
              + "\(Device.defaultOutput()?.name ?? "another device"), not \(device.name)"

        if forceReevaluate {
            forceReevaluate = false
            candidate = 0
            stablePolls = 0
        }

        // Wall-clock silence, so the two poll cadences cannot mean two delays.
        if activeNow.isEmpty {
            if silentSince == nil { silentSince = Date() }
        } else {
            silentSince = nil
        }

        guard bridgeEnabled else {
            bridgeSleep(mode == .follow ? 0.25 : pollInterval); continue
        }

        var desired: Float64?
        var why = ""
        /// True when `desired` is the idle rate rather than a player's reading.
        var idleTarget = false
        /// True when this poll is the first to see a new track.
        var trackBoundary = false
        /// Other streams that are live while we write. Not a reason to refuse —
        /// under `priority` they are expected — but the write reports them, so a
        /// relock heard during a video has a written explanation rather than
        /// looking like a fault.
        var liveCompanions: [String] = []
        let tRead = Date()

        if mode == .follow {
            // Pick the highest-ranked source that is actually playing, and let
            // everything below it be resampled.
            //
            // This branch used to gate on `Confidence.measured`, so it consulted
            // only sources whose rate we could observe and treated every other
            // live stream as a reason to do nothing. Two consequences, both bad:
            //
            //  1. The whole `.fixed` tier was unreachable. Spotify's rule is a
            //     constant, so Spotify playing on its own matched no branch but
            //     the final "something holds output" and was never followed. The
            //     same was true of every rule added by hand as a plain rate —
            //     `ratebridge rule <id> 48000` was accepted and then ignored.
            //  2. One browser tab holding an output stream wedged the bridge for
            //     as long as it was open, which on a real Mac is most of the time.
            //
            // Ranking fixes both without pretending the churn cost is zero: the
            // write still happens into a live stream, and it still says so.
            let active = activeOutputProcesses().filter { $0.reaches(device) }
            let table = ruleTable

            func rule(for process: AudioProcess) -> (bundleID: String, policy: Policy)? {
                guard let bundleID = process.bundleID else { return nil }
                return table.first { $0.bundleID == bundleID }
            }

            // A player that is demonstrably paused is neither a source nor a
            // rival — it just has not torn down its IO context yet. Only apps
            // that can be asked are ever excluded; `unknown` stays in.
            let live = active.filter { PlayerState.of($0.bundleID) != .paused }

            // Candidate rate sources: anything with a policy that yields a rate,
            // measured or constant, ranked by `sourceRank`. `off` opts an app out
            // entirely — not a source, and not a blocker either.
            let ruled = live
                .filter { process in
                    guard let matched = rule(for: process) else { return false }
                    if case .off = matched.policy { return false }
                    return true
                }
                .sorted {
                    sourceRank($0.bundleID ?? "", table: table)
                        < sourceRank($1.bundleID ?? "", table: table)
                }

            // Players nobody has written a rule for. They rank last, and they are
            // read the same way the generic tier in `resolveTargetRate` reads
            // them: every audio file the process holds open, committed only when
            // those files agree.
            //
            // Without this the daemon followed *only* apps in the table. A player
            // it had never heard of held its files open, `status` resolved the
            // rate correctly from them, and the daemon ignored it and rested —
            // the one place where the two disagreed about what was possible, and
            // the reason the tool felt like it was about Musicer and Apple Music
            // rather than about whatever you happen to play.
            let unruled = live.filter { rule(for: $0) == nil }
            let sources = ruled + unruled

            // Live streams that cannot tell us a rate at all: nothing is left in
            // this set now that unknown apps are tried generically, but a
            // bundle-less process with no readable files still lands here.
            let bystanders = live.filter { process in
                !sources.contains { $0.pid == process.pid }
            }

            // Do not hand the device to a lower-ranked source while the one we
            // were following is still holding an output stream and only just
            // stopped answering. That is a gap between tracks, not a handover.
            let candidates: [AudioProcess]
            if let previous = lastWinner,
               Date().timeIntervalSince(previous.at) < lowerRankHoldOff,
               active.contains(where: { $0.bundleID == previous.bundleID }) {
                candidates = sources.filter {
                    sourceRank($0.bundleID ?? "", table: table) <= previous.rank
                }
            } else {
                candidates = sources
            }

            /// Try one source. Returns false if it cannot state a rate, so the
            /// caller can move down the ranking.
            func follow(_ winner: AudioProcess) -> Bool {
                let matched = rule(for: winner)
                // A rule if there is one, the generic file reader if there is not.
                guard let reading = matched.flatMap({ evaluate($0, in: active) })
                        ?? (matched == nil
                            ? openFileRate(pid: winner.pid, label: winner.label)
                                .map { ($0.rate, $0.detail + "  [generic]") }
                            : nil)
                else { return false }
                desired = reading.rate
                why = reading.detail
                if let matched, case .uiReader = matched.policy { lastReaderSuccess = Date() }
                let id = matched?.bundleID ?? winner.label
                lastWinner = (id, sourceRank(id, table: table), Date())
                // Everything else that is live when we write. Reported at the
                // write, because "we chose Musicer over the tab" is the one thing
                // that makes an unexpected relock explainable after the fact.
                liveCompanions = (sources.filter { $0.pid != winner.pid }.map(\.label)
                                  + bystanders.map(\.label))
                return true
            }

            if conflictPolicy == .hold, live.count > 1 {
                // The original behaviour, kept because on some setups the churn
                // really is worse than the resampling. Measured 2026-08-27:
                // 20 aggregate activations in five minutes at mismatched rates
                // against 2-3 when they agreed.
                let reason = live.map(\.label).joined(separator: ", ")
                bridgeHolding = "\(reason) are all live"
                if lastReported != "hold-multi" {
                    note("holding — \(reason); conflict policy is `hold`")
                    lastReported = "hold-multi"
                }
                desired = nil
            } else if candidates.contains(where: follow) {
                // Followed. `follow` filled in desired/why/liveCompanions, and
                // `contains(where:)` walks the ranked list in order, so this
                // takes the highest-ranked source that can actually answer.
                //
                // Falling *through* matters as much as the ranking does. Musicer
                // holds its output stream with the player window closed, where
                // the AX reader has nothing to read; ranked first and asked
                // alone, it produced no rate and the bridge held — while Spotify
                // was playing, readable, and one rank below. An unreadable
                // source is not a veto over a readable one.
            } else if active.isEmpty {
                // Nothing holds an output stream at all. This is the one window
                // where a write is provably safe (SPEC gate G5) — and the only
                // chance to undo a leftover rate without touching a live stream.
                //
                // Without this the device simply keeps whatever the last track
                // set: after a 96 kHz album it stays at 96 kHz, so every YouTube
                // video, system sound and notification afterwards gets upsampled
                // by exactly the resampler this app exists to avoid.
                desired = restingRate
                why = "idle — returning to \(formatRate(restingRate))"
                idleTarget = true
                // Silence here is not always silence. Resting is still right —
                // this device has no stream to disturb — but logging only "idle"
                // while music plays out of the speakers is how a working bridge
                // gets mistaken for a broken one.
                if let elsewhere = bridgeElsewhere {
                    why += "  (\(elsewhere))"
                    if lastReported != "elsewhere" {
                        note("elsewhere — \(elsewhere). If a per-app router sends "
                           + "it here anyway, declare it: `ratebridge routed add "
                           + "<id>`. Otherwise `ratebridge device default` follows "
                           + "the system output.")
                        lastReported = "elsewhere"
                    }
                }
            } else {
                // Something is live but nothing in it can tell us a rate: an
                // unknown app, or a source whose reader came back empty. Writing
                // here would be a guess landing in a live stream, which is the
                // one combination with a cost and no benefit.
                let reason = live.isEmpty
                    ? "\(active.map(\.label).joined(separator: ", ")) holds output"
                    : "\(live.map(\.label).joined(separator: ", ")) has no readable rate"
                bridgeHolding = reason
                if lastReported != "unreadable" {
                    note("holding — \(reason)")
                    lastReported = "unreadable"
                }
                desired = nil
            }
            // Clearing lastReported re-arms the once-per-state log lines. Only a
            // reading from an actual player should do that: the idle target is
            // also non-nil, and clearing on it re-armed the "will rest" line on
            // every poll.
            if desired != nil { bridgeHolding = nil }
            if desired != nil, !idleTarget { lastReported = "" }

            // New track: act now rather than waiting out the full settle — but
            // still require one confirming poll.
            //
            // This used to force `stablePolls` straight to the threshold, so the
            // very first reading of a new track was written immediately. Apple
            // Music updates `current track` before it updates `sample rate of
            // current track`, so that first reading is often the *previous*
            // track's rate, and the result was two relocks per track change
            // instead of one:
            //
            //   [16:34:13] 48000 → 44100 Hz   Apple Music — body
            //   [16:34:16] 44100 → 96000 Hz   Apple Music — body
            //
            // Same track, three seconds apart, one of them audibly wrong. Asking
            // for a second agreeing poll costs 250 ms at a boundary and removes
            // the spurious relock entirely. The write-floor exemption below is
            // what keeps the boundary fast; this only stops it being hasty.
            if !why.isEmpty, why != lastSeenTrack {
                lastSeenTrack = why
                trackBoundary = true
                if let target = desired, abs(target - candidate) >= 1 {
                    candidate = target
                    stablePolls = 1
                    candidateSince = Date()
                }
            }
        } else {
        switch resolveTargetRate(on: device) {
        case .rate(let rate, let reason, _):
            desired = rate; why = reason
        case .conflict(let targets, let fallback):
            desired = fallback
            why = "conflict (" + targets.sorted { $0.key < $1.key }
                .map { "\($0.key)→\(Int($0.value))" }.joined(separator: ", ") + ")"
        case .noPolicy, .unknownRate:
            desired = nil
        }
        }

        if profiling {
            let now = Date()
            print(String(format: "[prof] device %.1f  procs %.1f  branch %.1f  total %.1f ms",
                         t1.timeIntervalSince(t0) * 1000,
                         t2.timeIntervalSince(t1) * 1000,
                         now.timeIntervalSince(tRead) * 1000,
                         now.timeIntervalSince(t0) * 1000))
        }

        guard let target = desired else {
            stablePolls = 0
            bridgeSleep(mode == .follow ? 0.25 : pollInterval); continue
        }

        // Debounce: the same answer several polls running, or we do nothing.
        if abs(target - candidate) < 1 {
            stablePolls += 1
        } else {
            candidate = target; stablePolls = 1; candidateSince = Date()
        }

        let current = device.nominalRate

        // Somebody else moved the rate. FineTune's picker writes exactly the
        // property we do, so without this a rate chosen by hand there is undone
        // on the next poll — a fight the user cannot win and cannot see the
        // cause of. Yield for a while, and say so once.
        if manualOverrideGrace > 0, let written = ourLastWrite(),
           written.device == device.id, abs(current - written.rate) >= 1 {
            // Confirm before yielding. Settings cross process boundaries through
            // cfprefsd, so a `ratebridge set` in a shell can land on the device a
            // beat before its record is visible here; one poll of disagreement is
            // not yet evidence of a foreign hand. Two consecutive polls is.
            foreignPolls += 1
            if foreignPolls >= 2 {
                manualOverrideUntil = Date().addingTimeInterval(manualOverrideGrace)
                recordOurWrite(device: device.id, rate: current)
                foreignPolls = 0
                note("\(Int(written.rate)) → \(Int(current)) Hz — set by something else; "
                   + "yielding for \(Int(manualOverrideGrace))s "
                   + "(`ratebridge config manual-override 0` disables this)")
            }
        } else {
            foreignPolls = 0
        }
        let overridden = Date() < manualOverrideUntil
        if overridden {
            bridgeHolding = "yielding to a rate set outside ratebridge "
                          + "(\(Int(manualOverrideUntil.timeIntervalSinceNow))s left)"
        }

        let needsChange = abs(current - target) >= 1

        // Dropping back to rest needs sustained silence; everything else is quick.
        // In musicer mode the reading is ground truth from the player itself, so a
        // short settle is enough — just long enough to skip the transient while a
        // track is being swapped in. The switch then lands in the first moment of
        // the new track rather than mid-song.
        let goingToRest = activeNow.isEmpty
        // 2 polls at 0.25s = 0.5s settle, and a track change bypasses it entirely.
        let needed = mode == .follow ? 2 : requiredStablePolls

        // Resting is gated on wall-clock silence, not a poll count. A player that
        // is merely paused still counts as a session in progress, so it waits far
        // longer than one that has quit.
        var restReady = true
        if goingToRest {
            let delay = knownPlayerRunning() ? idleRestDelayPlayerOpen : idleRestDelay
            let quietFor = silentSince.map { Date().timeIntervalSince($0) } ?? 0
            restReady = quietFor >= delay
            if needsChange, !restReady, lastReported != "settling" {
                print("[\(stamp())] idle — will rest to \(formatRate(target)) "
                    + "after \(Int(delay))s of quiet")
                lastReported = "settling"
            }
        }

        // A track change is a deliberate boundary, not a flapping signal, so it
        // is exempt from the anti-thrash floor. Leaving it subject to that floor
        // is the other half of the "not seamless" problem: a switch detected in
        // the first instant of a new track would still sit and wait if the
        // previous write happened to be recent.
        // A boundary reading must survive longer than the reader's own cache
        // before it is written. Counting polls is not enough: the poll is 250 ms
        // and `AppleMusicReader` caches for 500 ms, so "two agreeing polls" can
        // be one Apple Event read twice. Apple Music updates `current track`
        // before `sample rate of current track`, so the first reading of a new
        // track is often the previous track's rate — written, then corrected,
        // and heard as two relocks:
        //
        //   [20:59:02] 48000 → 44100 Hz   Apple Music — I Will Not Be Afraid
        //   [20:59:04] 44100 → 48000 Hz   Apple Music — I Will Not Be Afraid
        //
        // Same track, two seconds apart. 750 ms of wall-clock agreement
        // guarantees two independent reads and costs nothing anyone can hear.
        let confirmed = !trackBoundary
            || Date().timeIntervalSince(candidateSince) >= 0.75

        let writeFloor = trackBoundary ? 0.25 : minSecondsBetweenWrites
        if needsChange, restReady, !overridden, confirmed, stablePolls >= needed,
           Date().timeIntervalSince(lastWrite) >= writeFloor,
           device.supports(target) {

            // In safe mode we only touch the device when nothing holds an output
            // stream, which is the one condition where StartIO error 35 cannot
            // happen. Musicer keeps its context across tracks, so this window
            // opens between listening sessions, not between songs.
            let holders = activeOutputProcesses()
            if mode == .safe && !holders.isEmpty {
                if lastReported != "deferred" {
                    print("[\(stamp())] deferring \(Int(target)) Hz — "
                        + "\(holders.map(\.label).joined(separator: ", ")) still holds output")
                    lastReported = "deferred"
                }
            } else {
                if let error = device.setRate(target) {
                    print("[\(stamp())] write failed: \(error)")
                } else {
                    // Name what else was live. Under `priority` a write into a
                    // live stream is expected rather than refused, and the one
                    // thing that makes an unexpected relock explainable later is
                    // a record of what we chose over what.
                    let alongside = liveCompanions.isEmpty ? ""
                        : "   (over \(liveCompanions.joined(separator: ", ")))"
                    print("[\(stamp())] \(Int(current)) → \(Int(target)) Hz   \(why)\(alongside)")
                    bridgeLastAction = "\(stamp())  \(formatRate(target))"
                    recordSwitch(current, target, why)
                    lastReported = ""
                }
                lastWrite = Date()
            }
        }

        // Poll fast only when it can matter. A quarter-second cadence exists to
        // catch a track change the instant it happens; with nothing playing there
        // is no track to change, so back off and leave the CPU alone.
        let idle = bridgeSourceLabel == "nothing"
        // bridgeSleep, not Thread.sleep. This is the loop's main sleep and it was
        // the one left uninterruptible, so a track-change notification still
        // waited out the remainder of the tick — up to 1.5s of the latency the
        // wake semaphore exists to remove.
        bridgeSleep(mode == .follow ? (idle ? 1.5 : 0.5) : pollInterval)
    }
}

func writeAgentPlist(mode: DaemonMode) throws {
    let binary = FileManager.default.isExecutableFile(atPath: installedBinary)
        ? installedBinary : CommandLine.arguments[0]
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(agentLabel)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(binary)</string>
        <string>daemon</string>
        <string>--\(mode.rawValue)</string>
      </array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <!-- Insurance, not decoration. `KeepAlive` plus any exit that repeats is a
           respawn loop: a missing DAC once produced 977 identical log lines and
           no running bridge. The daemon no longer exits on that, but the next
           unanticipated exit should cost one line every 30s, not every 10. -->
      <key>ThrottleInterval</key><integer>30</integer>
      <key>ProcessType</key><string>Background</string>
      <key>StandardOutPath</key><string>\(agentLog)</string>
      <key>StandardErrorPath</key><string>\(agentLog)</string>
    </dict>
    </plist>
    """
    try FileManager.default.createDirectory(
        atPath: NSHomeDirectory() + "/Library/LaunchAgents",
        withIntermediateDirectories: true)
    try plist.write(toFile: agentPlist, atomically: true, encoding: .utf8)
}

/// Where a working bridge actually lives.
///
/// The bare CLI daemon under launchd cannot hold a TCC grant: macOS attributes
/// the request to the responsible process, which is launchd, not us. That was
/// already known for Accessibility (hence the .app), but it is just as true of
/// **Automation**, and that half was silent — the daemon asked Apple Music for
/// the track rate, got nothing, fell through to the browser's constant, and sat
/// at 48 kHz through a 44.1 kHz album with nothing in the log to say why.
/// Verified 2026-08-28: the identical binary run from a shell that holds the
/// grant switched on the first poll.
///
/// So `ratebridge on` must not install the one path that cannot work.
func installedAppPath() -> String? {
    for path in ["/Applications/Ratebridge.app",
                 NSHomeDirectory() + "/Applications/Ratebridge.app"]
    where FileManager.default.fileExists(atPath: path) {
        return path
    }
    return nil
}

func commandOn(mode: DaemonMode) -> Never {
    // Prefer the app whenever there is one. It runs the same bridge loop; the
    // only difference is that it can be granted the permissions the loop needs.
    if let app = installedAppPath(), !CommandLine.arguments.contains("--agent") {
        if daemonIsRunning() {
            _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
            print("stopped the launch-agent daemon — it cannot hold Accessibility or")
            print("Automation grants, so it could not read scripted or UI-read players.")
        }
        _ = shell("/usr/bin/open", ["-a", app])
        print("ratebridge ON  (\(app))")
        print("  Tick \"Open at Login\" in the menu to keep it running.")
        print("  off:  ratebridge off")
        print("")
        print("  --agent forces the old launch-agent daemon instead. It follows")
        print("  file-based and fixed-rate players, but never a scripted or")
        print("  UI-read one, because launchd cannot pass it a TCC grant.")
        exit(Exit.ok.rawValue)
    }

    if daemonIsRunning() { _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"]) }
    do { try writeAgentPlist(mode: mode) }
    catch { die(.restFailed, "could not write \(agentPlist): \(error.localizedDescription)") }

    let result = shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist])
    if result.status != 0 && !daemonIsRunning() {
        die(.restFailed, "launchctl bootstrap failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    print("ratebridge daemon ON  (mode: \(mode.rawValue))")
    print("  log:  \(agentLog)")
    print("  off:  ratebridge off")
    if installedAppPath() == nil {
        print("")
        print("  note: this is the bare CLI daemon. launchd cannot pass it an")
        print("  Accessibility or Automation grant, so `script` and `ui` players")
        print("  will not be followed. Run ./package.sh to build the menu bar")
        print("  app, which can hold both.")
    }
    exit(Exit.ok.rawValue)
}

func commandOff() -> Never {
    var stopped = false
    if daemonIsRunning() {
        _ = shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"])
        if daemonIsRunning() { die(.restFailed, "launchctl bootout did not stop \(agentLabel)") }
        print("ratebridge daemon OFF")
        stopped = true
    }
    // `on` may have started the app rather than the agent, so `off` has to be
    // able to stop that too, or the pair stops being symmetrical.
    if appIsRunning("com.bns.ratebridge") {
        _ = shell("/usr/bin/osascript", ["-e", "tell application \"Ratebridge\" to quit"])
        print("Ratebridge.app quit")
        stopped = true
    }
    if !stopped { print("ratebridge already off") }
    exit(Exit.ok.rawValue)
}


// MARK: - Menu bar app

/// Runs the same engine as `ratebridge daemon`, but inside a real .app bundle with
/// a status item. The bundle matters for more than looks: Accessibility and
/// Automation grants are per-executable, and macOS will not reliably hold a grant
/// for a bare CLI binary launched by launchd. Bundling is what makes the UI reader
/// work unattended.
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var refresh: Timer?
    private let mode: DaemonMode

    init(mode: DaemonMode) { self.mode = mode; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched via `open`, stdout goes nowhere. Send it somewhere readable.
        let logPath = NSHomeDirectory() + "/Library/Logs/ratebridge.log"
        freopen(logPath, "a", stdout)
        freopen(logPath, "a", stderr)
        setbuf(stdout, nil)

        // Prompt properly when untrusted. This registers the app with TCC and opens
        // the right pane, which is far more reliable than adding it by hand — and a
        // rebuild changes the ad-hoc signature, so this happens more than once.
        if !AXIsProcessTrusted() {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "♪ —"

        Thread.detachNewThread { [mode] in runBridgeLoop(mode: mode) }

        refresh = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    private func rebuild() {
        let rate = bridgeCurrentRate > 0 ? formatRate(bridgeCurrentRate) : "—"
        // ⚠ means "deliberately not switching", which is very different from idle.
        let mark = bridgeHolding != nil || bridgeElsewhere != nil ? " ⚠" : ""
        statusItem.button?.title = bridgeEnabled ? "♪ \(rate)\(mark)" : "♪ ⏸"

        let menu = NSMenu()
        menu.addItem(info("\(bridgeDeviceName) — \(rate)   [\(Device.targetReason)]"))
        menu.addItem(info("Playing: \(bridgeSourceLabel)"))
        if let holding = bridgeHolding {
            menu.addItem(info("⚠ Holding: \(holding)"))
        }
        if let elsewhere = bridgeElsewhere {
            menu.addItem(info("⚠ \(elsewhere)"))
        }
        menu.addItem(info("Reader: \(bridgeReaderStatus)"))

        // Idle countdown. Without it, "nothing is happening" and "waiting 108 more
        // seconds before resting" look identical from the menu bar, and the second
        // one is the thing you want to see after a listening session.
        if let since = silentSince {
            let delay = knownPlayerRunning() ? idleRestDelayPlayerOpen : idleRestDelay
            let left = Int(delay - Date().timeIntervalSince(since))
            menu.addItem(info(left > 0
                ? "Idle: resting to \(formatRate(restingRate)) in \(left)s"
                : "Idle: at \(formatRate(restingRate))"))
        }

        if !bridgeLastAction.isEmpty { menu.addItem(info("Last: \(bridgeLastAction)")) }

        if !switchHistory.isEmpty {
            let historyItem = NSMenuItem(title: "Recent Switches", action: nil, keyEquivalent: "")
            let historyMenu = NSMenu()
            for entry in switchHistory { historyMenu.addItem(info(entry)) }
            historyItem.submenu = historyMenu
            menu.addItem(historyItem)
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = bridgeEnabled ? .on : .off
        menu.addItem(toggle)

        let match = NSMenuItem(title: "Match Now", action: #selector(matchNow), keyEquivalent: "")
        match.target = self
        menu.addItem(match)

        let rest = NSMenuItem(title: "Rest to \(formatRate(restingRate))",
                              action: #selector(restNow), keyEquivalent: "")
        rest.target = self
        menu.addItem(rest)

        menu.addItem(.separator())

        let deviceItem = NSMenuItem(title: "Target Device", action: nil, keyEquivalent: "")
        let deviceMenu = NSMenu()
        let pinned = settings.string(forKey: "preferredDevice") ?? ""
        let followItem = NSMenuItem(title: "System Default", action: #selector(pinDevice(_:)),
                                    keyEquivalent: "")
        followItem.target = self
        followItem.representedObject = ""
        followItem.state = pinned.isEmpty ? .on : .off
        deviceMenu.addItem(followItem)
        deviceMenu.addItem(.separator())
        // A deadline, because this runs on the main thread every second. An
        // unguarded enumeration here is what froze the menu bar solid while
        // coreaudiod was wedged — the icon was drawn and then nothing responded,
        // including Quit.
        let outputs = withAudioDeadline(1) { Device.allOutputs() } ?? []
        if outputs.isEmpty {
            deviceMenu.addItem(info("(CoreAudio is not responding)"))
        }
        for output in outputs {
            let item = NSMenuItem(title: output.name, action: #selector(pinDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = output.name
            item.state = output.name == pinned ? .on : .off
            deviceMenu.addItem(item)
        }
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem),
                               keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let openLog = NSMenuItem(title: "Reveal Log…", action: #selector(revealLog),
                                 keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggleEnabled() { bridgeEnabled.toggle(); rebuild() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("[\(stamp())] login item toggle failed: \(error.localizedDescription)")
        }
        rebuild()
    }

    @objc private func pinDevice(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String ?? ""
        if name.isEmpty { settings.removeObject(forKey: "preferredDevice") }
        else { settings.set(name, forKey: "preferredDevice") }
        rebuild()
    }

    @objc private func revealLog() {
        let path = NSHomeDirectory() + "/Library/Logs/ratebridge.log"
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @objc private func matchNow() {
        // Same reason as `rebuild`: this is the main thread, and a wedged
        // coreaudiod would hang the menu instead of the click doing nothing.
        guard let device = withAudioDeadline(3, { Device.target() }) ?? nil else { return }
        if case .rate(let target, _, _) = resolveTargetRate(on: device),
           device.supports(target) {
            _ = device.setRate(target)
        } else if let rule = activeUIReaderRule(),
                  let reading = PlayerUIReader.read(pid: rule.pid,
                                                    label: rule.process ?? rule.bundleID),
                  device.supports(reading.rate) {
            _ = device.setRate(reading.rate)
        }
        rebuild()
    }

    @objc private func restNow() {
        guard let device = withAudioDeadline(3, { Device.target() }) ?? nil else { return }
        _ = device.setRate(restingRate)
        rebuild()
    }
}

func commandMenubar(mode: DaemonMode) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    let controller = MenuBarController(mode: mode)
    app.delegate = controller
    app.run()
    exit(Exit.ok.rawValue)
}


/// What a CoreAudio process tap reports for a process.
///
/// **This is a diagnostic, not a rate source, and that is a deliberate finding.**
/// Measured 2026-08-28 with a 44.1 kHz file playing on a 96 kHz device:
///
///   - `initWithProcesses:andDeviceUID:withStream:` reported **96000 Hz** — it
///     mirrors the device stream, so feeding it back would pin the device to
///     whatever it already is, for ever. Circular by construction.
///   - `initStereoMixdownOfProcesses:` reported **48000 Hz** — the mixdown's own
///     fixed format, the same number regardless of source or device.
///
/// Neither reported 44100. The tap reads audio *after* the resampler, which is
/// exactly the wrong side of the question "what rate should the device be at?".
/// It is kept here because the claim is a plausible one to re-test after a macOS
/// update, and a probe output is much cheaper than re-deriving the experiment.
func tapFormats(for object: AudioObjectID, deviceUID: String) -> [(String, String)] {
    func read(_ tap: AudioObjectID) -> String {
        var addr = address(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr
        else { return "format unreadable" }
        return "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, "
             + "\(asbd.mBitsPerChannel)-bit"
    }
    func probe(_ description: CATapDescription, _ label: String) -> (String, String) {
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted
        description.name = "ratebridge-probe"
        var tap = AudioObjectID(0)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != 0 else {
            return (label, "unavailable (OSStatus \(status))")
        }
        defer { AudioHardwareDestroyProcessTap(tap) }
        return (label, read(tap))
    }
    return [
        probe(CATapDescription(__processes: [NSNumber(value: object)],
                               andDeviceUID: deviceUID, withStream: 0),
              "device stream tap  (echoes the device rate — circular)"),
        probe(CATapDescription(stereoMixdownOfProcesses: [object]),
              "stereo mixdown tap (fixed mixdown format — constant)"),
    ]
}

/// Prints exactly what each detector sees. Rate detection fails silently by design
/// (a nil reading means "do nothing"), which makes it invisible when it misfires —
/// this is the command that makes it visible.
func commandProbe(_ device: Device) -> Never {
    print("device        \(device.name) @ \(formatRate(device.nominalRate))"
        + "   [\(Device.targetReason)]")
    if let mismatch = targetIsNotSystemOutput(device) { print("⚠ output       \(mismatch)") }
    print("")

    print("output devices:")
    for output in Device.allOutputs() {
        let kind = output.isUSBDAC ? "USB DAC" : "other"
        let mark = output.id == device.id ? "  ← target" : ""
        let name = output.name.padding(toLength: 24, withPad: " ", startingAt: 0)
        print("  \(name) \(formatRate(output.nominalRate))  \(kind)\(mark)")
    }
    print("")

    let active = activeOutputProcesses()
    // Anything declared `off` never reaches the lists below, so say it here or
    // the user is left comparing what they can hear against a list that silently
    // omits it.
    let ruledOff = uncachedActiveOutputProcesses().filter(isRuledOff)
    if !ruledOff.isEmpty {
        print("ignored by rule (invisible to the bridge — `ratebridge rule <id> default` to undo):")
        for process in ruledOff { print("  \(process.label)  pid \(process.pid)") }
        print("")
    }

    print("active output processes (\(active.count)):")
    if active.isEmpty { print("  (none)") }
    for process in active {
        let onTarget = process.uses(device) ? "on target device"
            : isDeclaredRouted(process) ? "routed to target (declared)"
            : "on another device"
        let state: String
        switch PlayerState.of(process.bundleID) {
        case .playing: state = "playing"
        case .paused:  state = "PAUSED — ignored as a source and as a rival"
        case .unknown: state = "state unknown (app is not scriptable)"
        }
        print("  pid \(process.pid)  bundle=\(process.bundleID ?? "—")  "
            + "name=\(process.name)  [\(onTarget)]  \(state)")
    }
    print("")

    if let rule = activeUIReaderRule() {
        print("UI reader (\(rule.process ?? rule.bundleID), pid \(rule.pid)):")
        if let reading = PlayerUIReader.read(pid: rule.pid,
                                             label: rule.process ?? rule.bundleID) {
            print("  \(Int(reading.rate)) Hz   \(reading.detail)")
        } else {
            print("  nil — \(PlayerUIReader.lastError.isEmpty ? "no reading" : PlayerUIReader.lastError)")
            // What the reader can see, so "no rate shown" can be told apart from
            // "looked in the wrong place". Run it once per player style.
            for line in PlayerUIReader.describeWindows(pid: rule.pid) {
                print("  \(line)")
            }
        }
    } else {
        let configured = ruleTable.filter { if case .uiReader = $0.policy { return true }
                                            return false }.map(\.bundleID)
        print("UI reader: no `ui` player running"
            + (configured.isEmpty
               ? " (no `ui` rules configured — `ratebridge rule <id> ui:<ProcessName>`)"
               : " (configured: \(configured.joined(separator: ", ")))"))
    }
    print("")

    // Every process actually producing output, rather than two named apps. On a
    // Mac with neither VLC nor Musicer the old pair printed two lines about apps
    // that were not installed and nothing at all about the player that was.
    if active.isEmpty { print("open files: nothing is producing output") }
    for process in active {
        let label = process.label
        let files = openAudioFiles(pid: process.pid)
        print("\(label) open audio files (\(files.count)):")
        for path in files {
            let rate = audioFileRate(path).map { "\(Int($0)) Hz" } ?? "rate unknown"
            print("  \(rate)  \((path as NSString).lastPathComponent)")
        }
    }
    print("")

    let uid = getString(device.id, kAudioDevicePropertyDeviceUID) ?? ""
    print("process taps (diagnostic only — see tapFormats):")
    if active.isEmpty { print("  (nothing producing output)") }
    for object in getArray(AudioObjectID(kAudioObjectSystemObject),
                           kAudioHardwarePropertyProcessObjectList, AudioObjectID(0)) {
        guard getValue(object, kAudioProcessPropertyIsRunningOutput,
                       default: UInt32(0)) != 0 else { continue }
        let bundle = getString(object, kAudioProcessPropertyBundleID) ?? "—"
        print("  \(bundle)")
        for (label, value) in tapFormats(for: object, deviceUID: uid) {
            print("    \(label): \(value)")
        }
    }
    print("")

    print("idle state:")
    // Read the live process set, not the daemon's `silentSince` — that belongs to
    // a running loop and is always nil in a one-shot CLI call, which made this
    // line report "something is holding output" even when nothing was.
    if active.isEmpty {
        print("  nothing holds output — the safe window for a write is open")
        if let since = silentSince {
            print("  silent for \(Int(Date().timeIntervalSince(since)))s")
        }
    } else {
        print("  held by \(active.map(\.label).joined(separator: ", "))")
    }
    print("  a player is \(knownPlayerRunning() ? "" : "not ")running → "
        + "rest after \(Int(knownPlayerRunning() ? idleRestDelayPlayerOpen : idleRestDelay))s")
    print("")

    switch resolveTargetRate(on: device) {
    case .rate(let rate, let reason, let confidence):
        print("resolved      \(formatRate(rate))  [\(confidence.rawValue)]  — \(reason)")
    case .conflict(let t, let fallback): print("resolved      CONFLICT \(t) → \(formatRate(fallback))")
    case .noPolicy(let names):           print("resolved      no policy for \(names)")
    case .unknownRate(let why):          print("resolved      unknown — \(why)")
    }
    exit(Exit.ok.rawValue)
}


func commandDevice(_ args: [String]) -> Never {
    let devices = Device.allOutputs()
    guard args.count >= 2 else {
        let pinned = settings.string(forKey: "preferredDevice") ?? ""
        print("output devices:")
        for device in devices {
            let mark = device.name == pinned ? " ← pinned"
                     : (pinned.isEmpty && device.id == Device.defaultOutput()?.id
                        ? " ← system default" : "")
            print("  \(device.name)\(mark)")
        }
        print("")
        let pinnedPresent = devices.contains { $0.name == pinned }
        print(pinned.isEmpty
              ? "following the system default output"
              : "pinned to \"\(pinned)\""
                + (pinnedPresent ? "" : " — NOT CONNECTED, the bridge is idle until it returns"))
        print("")
        print("  ratebridge device \"<name>\"   pin to a device")
        print("  ratebridge device default    follow the system output again")
        exit(Exit.ok.rawValue)
    }

    let wanted = args[1]
    if wanted == "default" {
        settings.removeObject(forKey: "preferredDevice")
        print("following the system default output again")
        exit(Exit.ok.rawValue)
    }
    guard devices.contains(where: { $0.name == wanted }) else {
        die(.noDevice, "no output device named \"\(wanted)\". "
                     + "Known: \(devices.map(\.name).joined(separator: ", "))")
    }
    settings.set(wanted, forKey: "preferredDevice")
    print("pinned to \"\(wanted)\"")
    exit(Exit.ok.rawValue)
}

/// Show or change the runtime settings.
///
/// These live in UserDefaults rather than in the binary for one concrete reason:
/// on this machine every rebuild re-signs the bundle with a new ad-hoc CDHash,
/// which invalidates the Accessibility grant and forces the user to remove and
/// re-add the app by hand. Anything tunable that lives in source costs that
/// ritual; anything tunable that lives here costs a command.
func commandConfig(_ args: [String]) -> Never {
    let keys: [(name: String, describe: () -> String)] = [
        ("idle-rate", { "\(Int(restingRate)) Hz" }),
        ("idle-delay", { "\(Int(idleRestDelay))s  (no player running)" }),
        ("idle-delay-player-open", { "\(Int(idleRestDelayPlayerOpen))s  (a player is open)" }),
        ("auto-detect-dac", { autoDetectDAC ? "on" : "off" }),
        ("conflict", { conflictPolicy.rawValue }),
        ("manual-override", { manualOverrideGrace > 0
            ? "\(Int(manualOverrideGrace))s" : "off" }),
    ]

    guard args.count >= 2 else {
        print("settings:")
        for key in keys { print("  \(key.name.padding(toLength: 24, withPad: " ", startingAt: 0))\(key.describe())") }
        print("")
        print("  ratebridge config idle-rate 44100        rate to return to when idle")
        print("  ratebridge config idle-delay 30          seconds of silence before resting")
        print("  ratebridge config idle-delay-player-open 120")
        print("  ratebridge config auto-detect-dac off    stop picking a USB DAC automatically")
        print("  ratebridge config conflict priority      when several apps play at once:")
        print("                                             priority  follow the top-ranked one")
        print("                                             hold      leave the device alone")
        print("  ratebridge config manual-override 300    seconds to yield after someone else")
        print("                                           sets the rate (FineTune, `ratebridge set`)")
        print("  ratebridge config reset                  back to defaults")
        exit(Exit.ok.rawValue)
    }

    if args[1] == "reset" {
        for key in ["idleRate", "idleRestDelay", "idleRestDelayPlayerOpen", "autoDetectDAC",
                    "conflict", "manualOverrideGrace", "priority"] {
            settings.removeObject(forKey: key)
        }
        print("settings reset to defaults")
        exit(Exit.ok.rawValue)
    }

    guard args.count >= 3 else { die(.unsupportedRate, "usage: ratebridge config <key> <value>") }
    let value = args[2]

    switch args[1] {
    case "idle-rate":
        guard let rate = Float64(value), rate > 0 else {
            die(.unsupportedRate, "idle-rate needs a rate in Hz, e.g. 48000")
        }
        // Validate against the device only when there *is* one. Refusing to
        // store a setting because the DAC happens to be unplugged makes the
        // config unreachable exactly when you are trying to fix things.
        if let device = withAudioDeadline(3, { Device.target() }) ?? nil {
            guard device.supports(rate) else {
                die(.unsupportedRate, "\(device.name) does not support \(Int(rate)) Hz. "
                                    + "Supported: \(device.availableRates.map(formatRate).joined(separator: ", "))")
            }
        }
        settings.set(rate, forKey: "idleRate")
        print("idle rate is now \(formatRate(rate))")
        if (withAudioDeadline(3, { Device.target() }) ?? nil) == nil {
            print("note: no target device right now — not checked against hardware")
        }
    case "idle-delay":
        guard let seconds = Double(value), seconds > 0 else {
            die(.unsupportedRate, "idle-delay needs seconds, e.g. 30")
        }
        settings.set(seconds, forKey: "idleRestDelay")
        print("idle delay is now \(Int(seconds))s")
    case "idle-delay-player-open":
        guard let seconds = Double(value), seconds > 0 else {
            die(.unsupportedRate, "idle-delay-player-open needs seconds, e.g. 120")
        }
        settings.set(seconds, forKey: "idleRestDelayPlayerOpen")
        print("idle delay with a player open is now \(Int(seconds))s")
    case "auto-detect-dac":
        let on = ["on", "true", "yes", "1"].contains(value.lowercased())
        settings.set(on, forKey: "autoDetectDAC")
        print("USB DAC auto-detect is now \(on ? "on" : "off")")
    case "conflict":
        guard let policy = ConflictPolicy(rawValue: value.lowercased()) else {
            die(.unsupportedRate, "conflict is `priority` or `hold`")
        }
        settings.set(policy.rawValue, forKey: "conflict")
        print(policy == .priority
            ? "conflict policy is now `priority` — the top-ranked live source wins, "
              + "everything below it is resampled"
            : "conflict policy is now `hold` — with more than one source live, "
              + "the device is left alone")
    case "manual-override":
        guard let seconds = Double(value), seconds >= 0 else {
            die(.unsupportedRate, "manual-override needs seconds, or 0 to disable")
        }
        settings.set(seconds, forKey: "manualOverrideGrace")
        print(seconds > 0
            ? "a rate set outside ratebridge now holds for \(Int(seconds))s"
            : "ratebridge will no longer yield to rates set elsewhere")
    default:
        die(.unsupportedRate, "unknown setting \"\(args[1])\". "
                            + "Known: \(keys.map(\.name).joined(separator: ", "))")
    }
    exit(Exit.ok.rawValue)
}

/// Show or change which source wins when several are playing at once.
///
/// Separate from `rule` on purpose: a rule says *what rate an app runs at*, and
/// priority says *whose answer we take* when two apps both have one. Conflating
/// them is how the old code ended up using `Confidence.measured` as a stand-in
/// for importance, which silently made every constant-rate source unfollowable.
func commandPriority(_ args: [String]) -> Never {
    let table = ruleTable
    guard args.count >= 2 else {
        let explicit = priorityOrder
        print("source priority, highest first:")
        if explicit.isEmpty {
            print("  (rule table order — no explicit priority set)")
            for entry in table where entry.policy.describe != "off" {
                print("    \(entry.bundleID)")
            }
        } else {
            for bundleID in explicit { print("  \(bundleID)") }
            let rest = table.map(\.bundleID).filter { !explicit.contains($0) }
            if !rest.isEmpty {
                print("  then, in rule table order:")
                for bundleID in rest { print("    \(bundleID)") }
            }
        }
        print("")
        print("  conflict policy: \(conflictPolicy.rawValue)")
        print("")
        print("  ratebridge priority <id> <id> ...   set the order, highest first")
        print("  ratebridge priority default         back to rule table order")
        exit(Exit.ok.rawValue)
    }

    if args[1] == "default" {
        settings.removeObject(forKey: "priority")
        print("priority is back to rule table order")
        exit(Exit.ok.rawValue)
    }

    let order = Array(args.dropFirst())
    settings.set(order, forKey: "priority")
    print("priority set:")
    for (index, bundleID) in order.enumerated() {
        let known = table.contains { $0.bundleID == bundleID }
        print("  \(index + 1). \(bundleID)\(known ? "" : "   (no rule yet — `ratebridge rule` to add one)")")
    }
    exit(Exit.ok.rawValue)
}

/// Show or change per-app rate policy, without a rebuild.
func commandRule(_ args: [String]) -> Never {
    let overrides = (settings.dictionary(forKey: "rules") as? [String: String]) ?? [:]

    guard args.count >= 2 else {
        print("rules (first match wins):")
        for rule in ruleTable {
            let mark = overrides[rule.bundleID] != nil ? "  ← override" : ""
            let id = rule.bundleID.padding(toLength: 30, withPad: " ", startingAt: 0)
            let policy = rule.policy.describe.padding(toLength: 14, withPad: " ", startingAt: 0)
            print("  \(id) \(policy) \(rule.policy.confidence.rawValue)\(mark)")
        }
        print("")
        print("  any app not listed: its open audio files are read when they agree")
        print("")
        print("  ratebridge rule <bundle-id> ui           read the rate off its own window")
        print("  ratebridge rule <bundle-id> ui:Name      the same, naming its process")
        print("  ratebridge rule <bundle-id> file         read its open audio file")
        print("  ratebridge rule <bundle-id> file:44100   read the file, else assume 44100")
        print("  ratebridge rule <bundle-id> 48000        always this rate")
        print("  ratebridge rule <bundle-id> script       ask it over Apple Events")
        print("  ratebridge rule <bundle-id> off          invisible to the bridge entirely")
        print("  ratebridge rule <bundle-id> default      drop the override")
        exit(Exit.ok.rawValue)
    }

    let bundleID = args[1]
    guard args.count >= 3 else {
        die(.unsupportedRate,
            "usage: ratebridge rule <bundle-id> <ui|ui:Process|script|file|file:HZ|HZ|off|default>")
    }

    var updated = overrides
    if args[2] == "default" {
        guard updated.removeValue(forKey: bundleID) != nil else {
            die(.unsupportedRate, "no override set for \(bundleID)")
        }
        settings.set(updated, forKey: "rules")
        print("dropped the override for \(bundleID)")
        exit(Exit.ok.rawValue)
    }

    guard let policy = Policy.parse(args[2]) else {
        die(.unsupportedRate, "cannot read \"\(args[2])\" as a policy. "
                            + "Use ui, ui:<Process>, script, file, file:<hz>, "
                            + "a rate in Hz, or off.")
    }
    // Stored with its case intact. Lowercasing turned `ui:Musicer` into
    // `ui:musicer`, and the process name is matched by `pgrep -x`, which is
    // case-sensitive — so the rule round-tripped through settings looking
    // correct and then never found the app.
    updated[bundleID] = args[2]
    settings.set(updated, forKey: "rules")
    print("\(bundleID) → \(policy.describe)  [\(policy.confidence.rawValue)]")
    exit(Exit.ok.rawValue)
}

/// What the file-based reader makes of one process. Exists because the reader's
/// safety property — commit only when every open file agrees — is invisible from
/// the outside: an ambiguous set and an unreadable one both just return nil.
func commandFiles(_ args: [String]) -> Never {
    guard args.count >= 2, let pid = pid_t(args[1]) else {
        die(.unsupportedRate, "usage: ratebridge files <pid> [watch <seconds>]")
    }
    // A single sample cannot tell the track being played from the one queued
    // behind it — that only becomes visible by watching one of them arrive. The
    // daemon has that history by construction; a one-shot command does not, so
    // `watch` is how the same question gets asked from a terminal, and how a
    // track boundary can be observed as it happens.
    let seconds = args.count >= 4 && args[2] == "watch" ? (Double(args[3]) ?? 0) : 0
    // Populate the reader's view of the window. In the daemon this has always
    // just happened; a one-shot command has to ask for it, or the file matching
    // would have nothing to match against and this diagnostic would disagree with
    // the thing it is meant to diagnose.
    _ = PlayerUIReader.readNative(pid: pid)
    let deadline = Date().addingTimeInterval(seconds)

    repeat {
        let files = openAudioFiles(pid: pid)
        print("open audio files for pid \(pid) (\(files.count)):"
            + (seconds > 0 ? "   \(stamp())" : ""))
        for path in files {
            let rate = audioFileRate(path).map { "\(Int($0)) Hz" } ?? "unreadable"
            print("  \(rate.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + "\((path as NSString).lastPathComponent)")
        }
        if let reading = openFileRate(pid: pid, label: processName(pid),
                                      showing: PlayerUIReader.visibleTexts(pid: pid)) {
            print("verdict       \(formatRate(reading.rate))  — \(reading.detail)")
        } else {
            print("verdict       no rate — the open files disagree and nothing the "
                + "player is showing picks one out, or none is readable")
        }
        print("")
        guard Date() < deadline else { break }
        Thread.sleep(forTimeInterval: 1)
        invalidateOpenFiles(pid: pid)
        PlayerUIReader.resetScanBackoff()
        _ = PlayerUIReader.readNative(pid: pid)
    } while true
    exit(Exit.ok.rawValue)
}

/// Processes that never count as "audio is playing".
func commandRouted(_ args: [String]) -> Never {
    var declared = (settings.array(forKey: "routedProcesses") as? [String]) ?? []

    guard args.count >= 2 else {
        print("apps declared as reaching the target device:")
        if declared.isEmpty {
            print("  (none)")
        } else {
            for id in declared.sorted() { print("  \(id)") }
        }
        print("")
        print("macOS has no per-app output setting, so the tools that add one do it")
        print("with a process tap: the app still renders to its own device and the")
        print("tap carries the sound somewhere else. The tap is private — the whole")
        print("tap list reads as empty while a redirect is running — so ratebridge")
        print("cannot see the redirect, in either direction:")
        print("")
        print("  its sound does NOT come out of my target:  ratebridge rule <id> off")
        print("  its sound DOES come out of my target:      ratebridge routed add <id>")
        print("")
        print("Without the second one, an app routed to your DAC is invisible: the")
        print("bridge sees nothing on the device, rests at the idle rate, and the DAC")
        print("resamples the track it is actually playing.")
        print("")
        print("  ratebridge routed add <bundle-id|process-name>")
        print("  ratebridge routed remove <bundle-id|process-name>")
        exit(Exit.ok.rawValue)
    }

    guard args.count >= 3 else {
        die(.unsupportedRate, "usage: ratebridge routed add|remove <bundle-id|process-name>")
    }
    let name = args[2]

    switch args[1] {
    case "add":
        guard !declared.contains(name) else {
            die(.unsupportedRate, "\(name) is already declared as routed to the target")
        }
        declared.append(name)
        settings.set(declared, forKey: "routedProcesses")
        print("\(name) now counts as playing on the target device")
    case "remove":
        guard let index = declared.firstIndex(of: name) else {
            die(.unsupportedRate, "\(name) is not declared as routed")
        }
        declared.remove(at: index)
        settings.set(declared, forKey: "routedProcesses")
        print("\(name) no longer counts as playing on the target device")
    default:
        die(.unsupportedRate, "usage: ratebridge routed add|remove <bundle-id|process-name>")
    }
    exit(Exit.ok.rawValue)
}

func commandIgnore(_ args: [String]) -> Never {
    var extra = (settings.array(forKey: "ignoredProcesses") as? [String]) ?? []

    guard args.count >= 2 else {
        print("ignored bundle ids:")
        for id in excludedBundleIDs.sorted() { print("  \(id)   (built in)") }
        print("ignored process names:")
        for name in excludedProcessNames.sorted() {
            print("  \(name)   \(builtinExcludedProcessNames.contains(name) ? "(built in)" : "")")
        }
        print("")
        print("These hold an output stream continuously without being something you")
        print("are listening to, so counting them would mean \"audio is playing\" always")
        print("and the device would never return to the idle rate.")
        print("")
        print("  ratebridge ignore add <process-name>")
        print("  ratebridge ignore remove <process-name>")
        exit(Exit.ok.rawValue)
    }

    guard args.count >= 3 else { die(.unsupportedRate, "usage: ratebridge ignore add|remove <name>") }
    let name = args[2]

    switch args[1] {
    case "add":
        guard !excludedProcessNames.contains(name) else {
            die(.unsupportedRate, "\(name) is already ignored")
        }
        extra.append(name)
        settings.set(extra, forKey: "ignoredProcesses")
        print("ignoring \(name)")
    case "remove":
        guard builtinExcludedProcessNames.contains(name) == false else {
            die(.unsupportedRate, "\(name) is built in and cannot be removed")
        }
        guard let index = extra.firstIndex(of: name) else {
            die(.unsupportedRate, "\(name) is not in the ignore list")
        }
        extra.remove(at: index)
        settings.set(extra, forKey: "ignoredProcesses")
        print("no longer ignoring \(name)")
    default:
        die(.unsupportedRate, "usage: ratebridge ignore add|remove <name>")
    }
    exit(Exit.ok.rawValue)
}

func daemonMode(from args: [String]) -> DaemonMode {
    if args.contains("--live") { return .live }
    if args.contains("--safe") { return .safe }
    // `--musicer` is the old spelling of the default and still resolves to it.
    return .follow
}

// MARK: - Entry point

let usage = """
ratebridge — follow the playing source's sample rate

  ratebridge status      show active app, its target rate, and the device rate
  ratebridge match       set the device to the current source's rate
  ratebridge rest        set the device to the resting rate (\(Int(restingRate)) Hz)
  ratebridge set <hz>    set an explicit rate
  ratebridge probe       show what every detector sees (debugging)
  ratebridge files <pid> what the file reader makes of one process
                         add `watch <seconds>` to follow it across a track change
  ratebridge device      list output devices; pin one so the bridge always
                         targets your DAC even if system output changes
  ratebridge config      show or change idle rate, idle delay, DAC auto-detect
  ratebridge ignore      processes that never count as "audio is playing"
  ratebridge routed      apps whose sound reaches the target device even though
                         macOS reports them rendering somewhere else (per-app
                         routing is done with private taps and cannot be detected)
  ratebridge rule        show or change the per-app rate policy. Both of these
                         take effect immediately and never need a rebuild — a
                         rebuild would void the app's Accessibility grant.

  ratebridge priority    who wins when several apps play at once

  ratebridge on          start the bridge. Uses Ratebridge.app when it is
                         installed, because a launchd daemon cannot be granted
                         Accessibility or Automation.
                         --agent force the bare launch-agent daemon
                         --safe  only write when nothing holds an output stream
  ratebridge off         stop the daemon
  ratebridge toggle      flip it

Operates on the default output device.
"""

/// Resolve the target device, or exit naming the reason we actually found.
///
/// Only the commands that *act* on a device call this. `device`, `config`,
/// `rule`, `ignore`, `help`, `daemon` and `menubar` must keep working when the
/// pinned DAC is unplugged, because those are the commands you need in order to
/// recover — and `device` is the one that re-pins.
///
/// Resolving at the top level instead, before argument dispatch, is what made a
/// missing DAC fatal to everything: `resolveTarget()` returns nil for a pinned
/// device that is not connected (deliberately — driving the built-in speakers
/// silently is worse), and that nil killed `--help`. The menu bar app exited
/// before it created a status item, so an unplugged cable looked like a crash,
/// and `KeepAlive` respawned the daemon into the same exit every 10 seconds.
func requireDevice() -> Device {
    guard let resolved = withAudioDeadline(8, { Device.target() }) else {
        die(.noDevice, audioWedgedAdvice)
    }
    guard let device = resolved else {
        let reason = Device.targetReason
        die(.noDevice, reason.contains("not connected")
            ? "\(reason). `ratebridge device` lists what is connected; "
              + "`ratebridge device default` follows system output."
            : "no default output device")
    }
    return device
}

let args = Array(CommandLine.arguments.dropFirst())

// Double-clicked from the .app bundle: run the menu bar UI.
if args.isEmpty, Bundle.main.bundlePath.hasSuffix(".app") {
    commandMenubar(mode: .follow)
}

// One health check, in front of the commands that actually touch the HAL.
//
// The per-command guards were not enough: `requireDevice` covers the commands
// that act on a device, but `ratebridge device` enumerates outputs directly and
// hung just the same — and `device` is the command you reach for when audio is
// misbehaving.
//
// The list is a whitelist rather than a blacklist, because the failure to avoid
// is the original one: gating everything meant `rule`, `config` and `priority`
// refused to run while coreaudiod was wedged, and those touch nothing but
// UserDefaults. Being unable to configure the tool because the audio server is
// unwell is exactly the trap the top-level device guard used to set.
//
// `daemon` and `menubar` are absent deliberately: they have their own watchdog
// and must stay up and report rather than exit.
if ["status", "match", "rest", "set", "probe", "files", "device", nil]
    .contains(args.first), !audioServerResponds() {
    die(.noDevice, audioWedgedAdvice)
}

switch args.first {
case "status", nil:
    commandStatus(requireDevice())

case "match":
    commandMatch(requireDevice())

case "rest":
    let restDevice = requireDevice()
    guard restDevice.supports(restingRate) else {
        die(.restFailed, "\(restDevice.name) does not support \(formatRate(restingRate))")
    }
    apply(restingRate, to: restDevice, because: "resting rate")

case "set":
    guard args.count >= 2, let rate = Float64(args[1]) else {
        die(.unsupportedRate, "usage: ratebridge set <hz>   e.g. ratebridge set 96000")
    }
    apply(rate, to: requireDevice(), because: "explicit override")

case "device":
    commandDevice(args)

case "config":
    commandConfig(args)

case "ignore":
    commandIgnore(args)

case "routed":
    commandRouted(args)

case "rule", "rules":
    commandRule(args)

case "priority":
    commandPriority(args)

case "probe":
    commandProbe(requireDevice())

case "files":
    commandFiles(args)

case "daemon":
    commandDaemon(mode: daemonMode(from: args))

case "menubar":
    commandMenubar(mode: daemonMode(from: args))

case "on":
    commandOn(mode: daemonMode(from: args))

case "off":
    commandOff()

case "toggle":
    daemonIsRunning() ? commandOff() : commandOn(mode: .follow)

case "-h", "--help", "help":
    print(usage)
    exit(Exit.ok.rawValue)

default:
    print(usage)
    die(.unsupportedRate, "unknown command: \(args[0])")
}
