#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Phone Mouse Server
# @raycast.mode fullOutput
# @raycast.packageName Mouse Controller

# Optional parameters:
# @raycast.icon 🖱️

# Resolve the repo directory from this script's own location so it keeps
# working regardless of where the repo is checked out or what cwd Raycast
# launches it from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

echo "Starting Mac Remote Controller Server..."

# Check if virtual environment exists
if [ -d ".venv" ]; then
    # Activate virtual environment
    source .venv/bin/activate
else
    echo "Error: Virtual environment (.venv) not found in $SCRIPT_DIR."
    echo "Run: python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt"
    exit 1
fi

# Start the python controller server
python3 mouse_controller.py
