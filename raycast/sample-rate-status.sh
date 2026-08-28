#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Sample Rate Status
# @raycast.mode fullOutput
# @raycast.icon 🎚️
# @raycast.packageName ratebridge
# @raycast.description Show the active app, its target rate, and the device rate
exec "$HOME/.local/bin/ratebridge" status
