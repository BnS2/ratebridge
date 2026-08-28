#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Match Sample Rate
# @raycast.mode compact
# @raycast.icon 🎚️
# @raycast.packageName ratebridge
# @raycast.description Set the output device to the rate of whatever is playing
exec "$HOME/.local/bin/ratebridge" match
