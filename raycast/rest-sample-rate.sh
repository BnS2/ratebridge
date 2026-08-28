#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Rest Sample Rate (44.1)
# @raycast.mode compact
# @raycast.icon 🎚️
# @raycast.packageName ratebridge
# @raycast.description Return the output device to the 44.1 kHz resting rate
exec "$HOME/.local/bin/ratebridge" rest
