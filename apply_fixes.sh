#!/bin/bash
# Script to automatically apply fixes to the cloned 'ost' repository

echo "=== Starting Automatic Fix Application ==="

# Check if we are inside the 'ost' directory or if it exists in current folder
if [ ! -d "clients/linux/ost_tracker_gtk" ] && [ -d "ost" ]; then
    echo "Navigating into 'ost' directory..."
    cd ost
fi

if [ ! -d "clients/linux/ost_tracker_gtk" ]; then
    echo "Error: Could not find the repository structure. Make sure you run this script from inside the 'ost' repository folder!"
    exit 1
fi

# 1. Create a new git branch
echo "Creating git branch: fix-linux-appimage-crash..."
git checkout -b fix-linux-appimage-crash

# 2. Fix pages.py missing theme import
PAGES_FILE="clients/linux/ost_tracker_gtk/pages.py"
if [ -f "$PAGES_FILE" ]; then
    echo "Patching $PAGES_FILE..."
    # Check if import already exists
    if ! grep -q "from . import theme" "$PAGES_FILE"; then
        # Insert 'from . import theme' after the first line (or top imports)
        sed -i '1s/^/from . import theme\n/' "$PAGES_FILE"
        echo "Successfully added theme import."
    else
        echo "Theme import already exists."
    fi
else
    echo "Error: $PAGES_FILE not found!"
fi

# 3. Fix app.py AlertDialog.new incompatibility
APP_FILE="clients/linux/ost_tracker_gtk/app.py"
if [ -f "$APP_FILE" ]; then
    echo "Patching $APP_FILE..."
    if grep -q "Gtk.AlertDialog.new(message)" "$APP_FILE"; then
        # Replace the single line allocation with multi-line setting
        # We handle indent assuming typical python format
        sed -i 's/dialog = Gtk.AlertDialog.new(message)/dialog = Gtk.AlertDialog()\n    dialog.set_message(message)/g' "$APP_FILE"
        echo "Successfully patched Gtk.AlertDialog."
    else
        echo "Gtk.AlertDialog.new(message) not found or already patched."
    fi
else
    echo "Error: $APP_FILE not found!"
fi

# 4. Append missing requirements to requirements.txt
REQ_FILE="requirements.txt"
if [ -f "$REQ_FILE" ]; then
    echo "Updating $REQ_FILE..."
    for pkg in httpx fastapi uvicorn pydantic python-multipart websockets; do
        if ! grep -q "^$pkg" "$REQ_FILE"; then
            echo "$pkg" >> "$REQ_FILE"
            echo "Added $pkg to requirements."
        else
            echo "$pkg already in requirements."
        fi
    done
else
    echo "Error: $REQ_FILE not found!"
fi

echo "=== All code patches applied successfully! ==="
echo "You can now verify your changes using 'git diff'."
echo "To push to your fork, run:"
echo "  git add ."
echo "  git commit -m 'Fix Linux AppImage crash: add missing dependencies, fix theme import, and update GTK AlertDialog compatibility'"
echo "  git push origin fix-linux-appimage-crash"
