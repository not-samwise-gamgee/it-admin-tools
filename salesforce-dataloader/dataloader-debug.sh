#!/bin/bash
# DataLoader Debug Script
# Diagnoses why DataLoader won't launch

# Get the actual logged-in user
CONSOLE_USER=$(stat -f%Su /dev/console)
USER_HOME=$(eval echo "~${CONSOLE_USER}")
DATALOADER_APP="$USER_HOME/Applications/Data Loader.app"

echo "=== DataLoader Launch Debug ==="
echo "User: $CONSOLE_USER"
echo "App Path: $DATALOADER_APP"
echo

# Check if app exists
if [[ ! -d "$DATALOADER_APP" ]]; then
    echo "❌ DataLoader app not found at expected location"
    exit 1
fi

echo "=== App Bundle Structure ==="
ls -la "$DATALOADER_APP/Contents/"
echo

echo "=== MacOS Directory ==="
find "$DATALOADER_APP/Contents/MacOS/" -maxdepth 1 -exec ls -la {} \;
echo

echo "=== Resources Directory ==="
find "$DATALOADER_APP/Contents/Resources/" -maxdepth 1 -exec ls -la {} \;
echo

echo "=== Info.plist Contents ==="
cat "$DATALOADER_APP/Contents/Info.plist"
echo

echo "=== Launcher Script Contents ==="
cat "$DATALOADER_APP/Contents/MacOS/DataLoader"
echo

echo "=== Java Check ==="
# Check if Java is available
if command -v java >/dev/null 2>&1; then
    echo "✓ Java found: $(java -version 2>&1 | head -1)"
    echo "Java path: $(which java)"
else
    echo "❌ Java not found in PATH"
fi
echo

echo "=== JAR File Check ==="
JAR_FILE=$(find "$DATALOADER_APP/Contents/Resources" -name "dataloader-*.jar" 2>/dev/null | head -1)
if [[ -n "$JAR_FILE" ]]; then
    echo "✓ JAR file found: $JAR_FILE"
    # shellcheck disable=SC2012  # single quoted file path, not a glob; -h gives human-readable size
    echo "JAR size: $(ls -lh "$JAR_FILE" | awk '{print $5}')"
    
    # Test if JAR is valid
    if java -jar "$JAR_FILE" --help >/dev/null 2>&1; then
        echo "✓ JAR file is executable"
    else
        echo "❌ JAR file cannot be executed"
        echo "JAR test output:"
        java -jar "$JAR_FILE" --help 2>&1 | head -5
    fi
else
    echo "❌ No JAR file found"
fi
echo

echo "=== Permissions Check ==="
echo "App bundle permissions:"
ls -ld "$DATALOADER_APP"
echo "Executable permissions:"
ls -l "$DATALOADER_APP/Contents/MacOS/DataLoader"
echo "JAR permissions:"
if [[ -n "$JAR_FILE" ]]; then
    ls -l "$JAR_FILE"
fi
echo

echo "=== Extended Attributes ==="
xattr -l "$DATALOADER_APP" 2>/dev/null || echo "No extended attributes"
echo

echo "=== Console Logs ==="
echo "Recent console errors for DataLoader:"
log show --predicate 'process CONTAINS "DataLoader" OR process CONTAINS "java"' --info --last 5m 2>/dev/null | tail -10 || echo "No recent console logs"
echo

echo "=== Manual Launch Test ==="
echo "Attempting to launch DataLoader manually..."
cd "$DATALOADER_APP/Contents/Resources" || exit 1
if [[ -n "$JAR_FILE" ]]; then
    timeout 10s java -jar "$(basename "$JAR_FILE")" 2>&1 | head -10 || echo "Launch test completed/timed out"
fi

echo
echo "=== Recommendations ==="
echo "If Java is missing: Install Java runtime"
echo "If JAR is corrupted: Re-download DataLoader"
echo "If permissions are wrong: Fix with chown/chmod"
echo "If extended attributes: Remove with xattr -c"
