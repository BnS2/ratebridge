// Fixture stand-in for afinfo: the matchers only ever ask for duration.
var fixture: [String: Double] = [:]
func audioFileInfo(_ path: String) -> (rate: Float64, duration: Double)? {
    fixture[path].map { (rate: 44100, duration: $0) }
}

var pass = 0, fail = 0
func check(_ name: String, _ got: String?, _ want: String?) {
    if got == want { pass += 1; print("  PASS  \(name)") }
    else { fail += 1; print("  FAIL  \(name)\n        wanted \(want ?? "nil"), got \(got ?? "nil")") }
}

check("clock m:ss", parseClock("2:58").map { String(Int($0)) }, "178")
check("clock h:mm:ss", parseClock("1:02:03").map { String(Int($0)) }, "3723")
check("clock rejects a title", parseClock("KATSEYE").map { String(Int($0)) }, nil)
check("clock rejects a bitrate", parseClock("1.8Mbps").map { String(Int($0)) }, nil)

// Both of these were open at once on 2026-08-29, at 48 kHz and 96 kHz, with the
// player showing the first one.
let files = ["/m/Panis ka boy - GA Chillerong Ghetto, Paul N Ballin.flac",
             "/m/RUDE! - Hearts2Hearts.flac"]
check("name match picks the shown track",
      fileMatchingOnScreenText(files, showing: ["Panis ka boy", "2:58", "GA Chillerong Ghetto"]),
      files[0])
check("name match ignores short noise",
      fileMatchingOnScreenText(files, showing: ["a", "of"]), nil)
check("name match refuses when ambiguous",
      fileMatchingOnScreenText(["/m/live.flac", "/m/live take 2.flac"], showing: ["live"]), nil)
check("name match survives punctuation and case",
      fileMatchingOnScreenText(["/m/RUDE! - Hearts2Hearts.flac"], showing: ["rude"]),
      "/m/RUDE! - Hearts2Hearts.flac")

fixture = ["/m/01.flac": 178.0, "/m/02.flac": 240.0]
let unnamed = ["/m/01.flac", "/m/02.flac"]
check("duration match when names say nothing",
      fileMatchingDuration(unnamed, showing: ["2:58"]), "/m/01.flac")
check("duration tolerates rounding",
      fileMatchingDuration(unnamed, showing: ["2:56"]), "/m/01.flac")
check("duration refuses beyond tolerance",
      fileMatchingDuration(unnamed, showing: ["2:50"]), nil)
fixture = ["/m/01.flac": 178.0, "/m/02.flac": 178.5]
check("duration refuses when two tracks match",
      fileMatchingDuration(unnamed, showing: ["2:58"]), nil)

fixture = ["/m/Panis ka boy - GA Chillerong Ghetto, Paul N Ballin.flac": 999.0,
           "/m/RUDE! - Hearts2Hearts.flac": 178.0]
check("name beats duration when both could fire",
      identifyPlayingFile(files, showing: ["Panis ka boy", "2:58"]), files[0])

print("")
print("pass \(pass)   fail \(fail)")
exit(fail == 0 ? 0 : 1)
