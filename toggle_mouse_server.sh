#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Phone Mouse Server
# @raycast.mode fullOutput
# @raycast.packageName Mouse Controller
# @raycast.currentDirectoryPath /Users/robert/Documents/antigravity/bold-darwin

# Optional parameters:
# @raycast.icon 🖱️

echo "Starting Mac Remote Controller Server..."

# Check if virtual environment exists
if [ -d ".venv" ]; then
    # Activate virtual environment
    source .venv/bin/activate
else
    echo "Error: Virtual environment (.venv) not found in the current directory."
    echo "Please ensure the .venv directory exists."
    exit 1
fi

# Start the python controller server
python3 mouse_controller.py
