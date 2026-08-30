#!/usr/bin/env python3
"""Build a Swift harness around the pure decisions in the bridge.

Two of them: which of several open files a rate is read from, and whether a
process counts for the managed device at all.

The matchers are the sharpest edge in the tool: they decide which of several
open files a rate is read from, and a wrong answer writes a wrong rate into a
live stream. They are also pure functions, so they can be tested without audio,
without a DAC, and without a player — but only if the test runs the *shipping*
code. So the functions are lifted out of Sources/main.swift rather than copied,
and a copy that drifts is a test that lies.
"""
import sys

src = open("Sources/main.swift").read()

def grab(name):
    i = src.index("func " + name)
    j = src.index("{", i)
    depth, k = 0, src.index("{", i)
    while True:
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    return src[i:k + 1]

def grab_from(marker):
    """Same brace-matching, for a declaration that is not a func."""
    i = src.index(marker)
    depth, k = 0, src.index("{", i)
    while True:
        if src[k] == "{":
            depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0:
                break
        k += 1
    return src[i:k + 1]

parts = ["import Foundation", ""]
parts.append(grab_from("enum ReachVerdict"))
for name in ["reachVerdict(", "squashed(", "parseClock(", "fileMatchingOnScreenText(",
             "fileMatchingDuration(", "identifyPlayingFile("]:
    parts.append(grab(name))

parts.append(open("test/matchers_cases.swift").read())
open(sys.argv[1], "w").write("\n\n".join(parts))
