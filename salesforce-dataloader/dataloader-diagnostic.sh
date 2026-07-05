#!/bin/bash
# DataLoader Diagnostic Script
# Finds all DataLoader installations and identifies version conflicts

echo "=== DataLoader Diagnostic Report ==="
echo "Date: $(date)"
echo

# Get the actual logged-in user
CONSOLE_USER=$(stat -f%Su /dev/console)
USER_HOME=$(eval echo "~${CONSOLE_USER}")
echo "Console User: $CONSOLE_USER"
echo "User Home: $USER_HOME"
echo

# Function to get version from Info.plist
get_app_version() {
    local app_path="$1"
    local version
    if [[ -f "$app_path/Contents/Info.plist" ]]; then
        version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_path/Contents/Info.plist" 2>/dev/null)
        echo "${version:-Unknown}"
    else
        echo "No Info.plist"
    fi
}

# Function to check if app bundle is valid
check_app_validity() {
    local app_path="$1"
    local executable_path="$app_path/Contents/MacOS/DataLoader"
    local jar_path
    jar_path=$(find "$app_path/Contents/Resources" -name "dataloader-*.jar" 2>/dev/null | head -1)
    
    echo "    Executable exists: $([ -f "$executable_path" ] && echo "Yes" || echo "No")"
    echo "    Executable permissions: $([ -x "$executable_path" ] && echo "Executable" || echo "Not executable")"
    echo "    JAR file exists: $([ -n "$jar_path" ] && echo "Yes ($jar_path)" || echo "No")"
    
    if [[ -f "$executable_path" ]]; then
        echo "    Launcher script content:"
        head -5 "$executable_path" | sed 's/^/      /'
    fi
}

echo "=== Searching for DataLoader installations ==="

# Check common locations
locations=(
    "/Applications"
    "$USER_HOME/Applications"
    "/System/Applications"
    "$USER_HOME/Desktop"
    "$USER_HOME/Downloads"
)

found_installations=()

for location in "${locations[@]}"; do
    if [[ -d "$location" ]]; then
        echo "Checking: $location"
        
        # Look for Data Loader.app
        if [[ -d "$location/Data Loader.app" ]]; then
            app_path="$location/Data Loader.app"
            version=$(get_app_version "$app_path")
            echo "  ✓ Found: $app_path"
            echo "    Version: $version"
            echo "    Size: $(du -sh "$app_path" | cut -f1)"
            echo "    Modified: $(stat -f%Sm "$app_path")"
            check_app_validity "$app_path"
            found_installations+=("$app_path:$version")
            echo
        fi
        
        # Look for DataLoader.app (alternative name)
        if [[ -d "$location/DataLoader.app" ]]; then
            app_path="$location/DataLoader.app"
            version=$(get_app_version "$app_path")
            echo "  ✓ Found: $app_path"
            echo "    Version: $version"
            echo "    Size: $(du -sh "$app_path" | cut -f1)"
            echo "    Modified: $(stat -f%Sm "$app_path")"
            check_app_validity "$app_path"
            found_installations+=("$app_path:$version")
            echo
        fi
        
        # Look for any other DataLoader-related apps
        while IFS= read -r -d '' app_path; do
            if [[ "$app_path" != *"Data Loader.app" ]] && [[ "$app_path" != *"DataLoader.app" ]]; then
                version=$(get_app_version "$app_path")
                echo "  ✓ Found (other): $app_path"
                echo "    Version: $version"
                echo "    Size: $(du -sh "$app_path" | cut -f1)"
                echo "    Modified: $(stat -f%Sm "$app_path")"
                found_installations+=("$app_path:$version")
                echo
            fi
        done < <(find "$location" -maxdepth 1 -name "*ataloader*" -type d -print0 2>/dev/null)
    fi
done

echo "=== Spotlight Search for DataLoader ==="
# Use Spotlight to find any DataLoader apps we might have missed
while IFS= read -r item; do
    if [[ -d "$item" ]] && [[ "$item" == *.app ]]; then
        version=$(get_app_version "$item")
        echo "Spotlight found: $item (Version: $version)"
    fi
done < <(mdfind "kMDItemDisplayName == '*DataLoader*' || kMDItemDisplayName == '*Data Loader*'" 2>/dev/null)

echo
echo "=== LaunchServices Database Check ==="
# Check what the system thinks is the default DataLoader app
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -dump | grep -i dataloader | head -10

echo
echo "=== Process Check ==="
# Check if DataLoader is currently running
if pgrep -f -i dataloader >/dev/null 2>&1; then
    echo "DataLoader processes found:"
    pgrep -f -l -i dataloader
else
    echo "No DataLoader processes running"
fi

echo
echo "=== Configuration Files ==="
# Check for DataLoader config files
config_locations=(
    "$USER_HOME/.dataloader"
    "$USER_HOME/Library/Application Support/dataloader"
    "$USER_HOME/Library/Preferences/com.salesforce.dataloader.plist"
)

for config in "${config_locations[@]}"; do
    if [[ -e "$config" ]]; then
        echo "Config found: $config"
        echo "  Modified: $(stat -f%Sm "$config")"
        if [[ -f "$config" ]]; then
            echo "  Size: $(wc -c < "$config") bytes"
        fi
    fi
done

echo
echo "=== Summary ==="
if [[ ${#found_installations[@]} -eq 0 ]]; then
    echo "❌ No DataLoader installations found"
elif [[ ${#found_installations[@]} -eq 1 ]]; then
    echo "✓ Single DataLoader installation found"
else
    echo "⚠️  Multiple DataLoader installations found (${#found_installations[@]} total)"
    echo "This could cause version conflicts!"
fi

echo
echo "=== Recommendations ==="
if [[ ${#found_installations[@]} -gt 1 ]]; then
    echo "1. Remove all old DataLoader installations"
    echo "2. Keep only the latest version (64.1.0) in ~/Applications/"
    echo "3. Clear LaunchServices database: /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -kill -r -domain local -domain system -domain user"
fi

echo "4. Test launching DataLoader from Finder"
echo "5. If issues persist, check Console.app for error messages"

echo
echo "=== End of Report ==="
