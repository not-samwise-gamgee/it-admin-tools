#!/bin/bash

# Exit on non-zero status and variable errors, report back individual pipefails 
set -euo pipefail

# MDM logging setup
# Determine log file location based on user
if [ "$EUID" -eq 0 ]; then
    LOG_FILE="/var/log/chrome_install.log"
else
    LOG_FILE="/tmp/chrome_install.log"
fi
readonly LOG_FILE

touch "$LOG_FILE" 2>/dev/null || true

# Constants
readonly BASE_URL="https://dl.google.com/chrome/mac/universal/stable/gcem/googlechrome.pkg"
readonly CHROME_APP="/Applications/Google Chrome.app"
readonly MIN_VERSION="120.0.0"  # Minimum required version
readonly MAX_RETRIES=5
readonly RETRY_DELAY=10
readonly CONNECT_TIMEOUT=30
readonly MAX_TIME=300
# NOTE: The public Chrome download endpoint does not require authentication cookies.
# Leave this empty, or supply your own browser session cookies only if a specific
# environment requires them. Do NOT commit real account/session cookies here.
readonly COOKIE_HEADER="[OPTIONAL_SESSION_COOKIES]"
readonly CURL_OPTS=(
    --silent
    --fail
    --show-error
    --location
    --connect-timeout "$CONNECT_TIMEOUT"
    --max-time "$MAX_TIME"
    --retry "$MAX_RETRIES"
    --retry-delay "$RETRY_DELAY"
    --retry-max-time $((MAX_TIME * 2))
    --retry-all-errors
    --user-agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    --referer "https://chromeenterprise.google/browser/download/"
    --header "Accept: application/octet-stream"
    --cookie "$COOKIE_HEADER"
)


# For testing purposes only
readonly FORCE_VERSION=${1:-}

# Get the real console user and home directory
get_real_user_and_home() {
    if [ "$EUID" -eq 0 ]; then
        CONSOLE_USER=$(stat -f "%Su" /dev/console)
        CONSOLE_HOME=$(dscl . -read /Users/"$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')
    else
        CONSOLE_USER="$USER"
        CONSOLE_HOME="$HOME"
    fi
    if [ -z "$CONSOLE_USER" ] || [ -z "$CONSOLE_HOME" ]; then
        log "ERROR" "Could not determine real user or home directory"
        exit 1
    fi
}

# Logging and error handling functions
log() {
    local level msg
    level="$1"
    shift
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg" | tee -a "$LOG_FILE" >&2
}

die() {
    log "ERROR" "$*"
    exit 1
}

# Function to verify internet connectivity
check_connectivity() {
    local test_urls=(
        "https://www.google.com"
        "https://dl.google.com"
        "https://chromiumdash.appspot.com"
    )
    
    for url in "${test_urls[@]}"; do
        log "DEBUG" "Testing connectivity to $url"
        if curl --connect-timeout 5 -Is "$url" >/dev/null 2>&1; then
            return 0
        fi
    done
    
    return 1
}

# Function to verify URL is accessible
verify_url() {
    local url="$1"
    local attempt=1
    local max_attempts=3
    
    while [ $attempt -le $max_attempts ]; do
        log "DEBUG" "Verifying URL accessibility (attempt $attempt/$max_attempts): $url"
        local response_code
        response_code=$(curl -sL -w "%{http_code}" "$url" -o /dev/null)
        
        case $response_code in
            200|301|302)
                log "DEBUG" "URL is accessible (HTTP $response_code)"
                return 0
                ;;
            403)
                log "ERROR" "Access forbidden (HTTP 403)"
                return 1
                ;;
            404)
                log "ERROR" "URL not found (HTTP 404)"
                return 1
                ;;
            *)
                log "WARN" "Unexpected HTTP response code: $response_code"
                ;;
        esac
        
        ((attempt++))
        [ $attempt -le $max_attempts ] && sleep $((RETRY_DELAY * attempt))
    done
    
    return 1
}

# Function to download Chrome package
download_chrome() {
    local url="$1"
    local output_file="$2"
    local attempt=1
    local success=false
    local last_error=""
    
    # DEBUG: Log user, home, PATH, whoami
    log "DEBUG" "download_chrome running as: $(whoami), HOME=$HOME, PATH=$PATH, USER=$USER, LOG_FILE=$LOG_FILE"
    
    # If root, make log file world-writable for troubleshooting
    if [ "$EUID" -eq 0 ]; then
        chmod 666 "$LOG_FILE" 2>/dev/null || true
    fi
    
    # Verify internet connectivity first
    log "DEBUG" "Verifying internet connectivity"
    if ! check_connectivity; then
        die "No internet connectivity detected"
    fi
    
    # Verify URL is accessible
    if ! verify_url "$url"; then
        die "Chrome download URL is not accessible"
    fi
    
    while [ $attempt -le $MAX_RETRIES ]; do
        log "DEBUG" "Download attempt $attempt of $MAX_RETRIES"
        
        # Try download with progress
        if curl \
            --fail \
            --location \
            --progress-bar \
            --write-out "\n" \
            --user-agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36" \
            --header "Referer: https://chromeenterprise.google/browser/download/" \
            --header "Accept: application/octet-stream" \
            --dump-header "$output_file.headers" \
            --output "$output_file" \
            "$url" 2>&1; then
            
            # Verify downloaded file
            if [ -f "$output_file" ] && [ -s "$output_file" ]; then
                local file_type
                file_type=$(file -b "$output_file")
                if [[ $file_type == *"xar archive"* ]] || [[ $file_type == *"package"* ]]; then
                    log "INFO" "Successfully downloaded Chrome package"
                    success=true
                    break
                elif grep -qsi '<html' "$output_file"; then
                    local html_error_file
                    html_error_file="$(dirname "$output_file")/chrome_download_error.html"
                    head -20 "$output_file" > "$html_error_file"
                    log "ERROR" "Downloaded file is HTML (likely an error page). Saved first 20 lines to: $html_error_file"
                    log "ERROR" "HTML error content follows:"
                    while read -r line; do log "ERROR" "$line"; done < "$html_error_file"
                    if [ -f "$output_file.headers" ]; then
                        log "ERROR" "HTTP headers for failed download:"
                        while read -r line; do log "ERROR" "$line"; done < "$output_file.headers"
                    fi
                    rm -f "$output_file" "$output_file.headers"
                    return 1
                else
                    log "WARN" "Downloaded file is not a valid package (type: $file_type)"
                    rm -f "$output_file"
                fi
            else
                log "WARN" "Downloaded file is empty or missing"
            fi
        else
            last_error=$?
            log "WARN" "Download failed with error $last_error (attempt $attempt)"
            
            # Check specific curl exit codes
            case $last_error in
                56) # Recv failure
                    log "DEBUG" "Connection was reset, waiting longer before retry"
                    sleep $((RETRY_DELAY * 2 * attempt))
                    ;;
                28) # Operation timeout
                    log "DEBUG" "Operation timed out, increasing timeout for next attempt"
                    CONNECT_TIMEOUT=$((CONNECT_TIMEOUT + 30))
                    MAX_TIME=$((MAX_TIME + 60))
                    ;;
                22) # HTTP page not retrieved
                    log "DEBUG" "HTTP error, checking URL validity"
                    if ! verify_url "$url"; then
                        log "ERROR" "URL is not accessible: $url"
                        return 1
                    fi
                    ;;
            esac
        fi
        
        # Exponential backoff with jitter
        local delay=$((RETRY_DELAY * 2 ** (attempt - 1) + RANDOM % 5))
        log "DEBUG" "Waiting $delay seconds before next attempt"
        sleep "$delay"
        ((attempt++))
    done
    
    if ! $success; then
        log "ERROR" "Failed to download Chrome package after $MAX_RETRIES attempts (last error: $last_error)"
        return 1
    fi
    
    return 0
}

# Function to get latest Chrome version
get_latest_version() {
    local latest_version
    latest_version=$(curl "${CURL_OPTS[@]}" "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac" | grep -o '"version":"[^"]*"' | cut -d'"' -f4 | head -n1)
    if [ -z "$latest_version" ]; then
        log "WARN" "Failed to fetch latest version, using minimum version as fallback"
        echo "$MIN_VERSION"
        return
    fi
    echo "$latest_version"
}

# Function to check if Chrome needs to be updated
should_update_chrome() {
    local current_ver="$1"
    local min_ver="$2"
    local latest_ver="$3"
    
    # First check if current version meets minimum requirement
    local min_comparison
    min_comparison=$(version_compare "$current_ver" "$min_ver")
    if [[ "$min_comparison" == "less" ]]; then
        log "INFO" "Current version ($current_ver) is below minimum requirement ($min_ver)"
        return 0
    fi
    
    # Then check if current version is latest
    local latest_comparison
    latest_comparison=$(version_compare "$current_ver" "$latest_ver")
    if [[ "$latest_comparison" == "less" ]]; then
        log "INFO" "Current version ($current_ver) is below latest version ($latest_ver)"
        return 0
    fi
    
    return 1
}

# Cleanup function
cleanup() {
    local temp_dir="$1"
    local mount_point="${2:-}"
    local exit_code=$?
    
    if [ -n "$mount_point" ] && hdiutil info | grep -q "$mount_point"; then
        log "INFO" "Detaching DMG from $mount_point"
        hdiutil detach "$mount_point" || log "WARN" "Failed to detach DMG"
    fi
    
    if [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
        log "INFO" "Deleted temporary directory: $temp_dir"
    fi
    
    exit $exit_code
}

# Version comparison function
version_compare() {
    if [[ "$1" == "$2" ]]; then
        echo "equal"
        return
    fi
    local IFS=.
    local i ver1 ver2
    read -r -a ver1 <<< "$1"
    read -r -a ver2 <<< "$2"
    # Fill empty positions in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++)); do
        # Fill empty positions in ver2 with zeros
        if [[ -z ${ver2[i]:-} ]]; then
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]})); then
            echo "greater"
            return
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]})); then
            echo "less"
            return
        fi
    done
    echo "equal"
}

# Main installation block
main() {
    local arg1="${1:-}"
    local arg2="${2:-}"
    local arg3="${3:-}"
    # Special mode for download as user from sudo context
    if [ "$arg1" = "_download_only" ]; then
        download_chrome "$arg2" "$arg3"
        exit $?
    fi
    # Check if Chrome is already installed
    if [ -d "$CHROME_APP" ]; then
        if [ -n "$FORCE_VERSION" ]; then
            current_version="$FORCE_VERSION"
            log "INFO" "Test mode: Using version $current_version"
        else
            current_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$CHROME_APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")
        fi
        log "INFO" "Current Chrome version: $current_version"
        
        # Get latest version
        latest_version=$(get_latest_version)
        log "INFO" "Latest Chrome version: $latest_version"
        
        # Check if update is needed
        if ! should_update_chrome "$current_version" "$MIN_VERSION" "$latest_version"; then
            log "INFO" "Chrome version $current_version is up to date"
            exit 0
        fi
        
        # Remove old version if update is needed
        log "INFO" "Stopping Chrome"
        pkill -f "Google Chrome" 2>/dev/null || true
        sleep 2  # Wait for Chrome to fully close
        
        log "INFO" "Removing old Chrome installation"
        rm -rf "$CHROME_APP" || {
            log "ERROR" "Failed to remove existing installation"
            sleep 2  # Add additional delay
            rm -rf "$CHROME_APP" || {  # Second attempt
                log "ERROR" "Failed to remove existing installation after retry"
                exit 74  # Exit code for removal failure
            }
        }
        # Verify removal
        if [ -d "$CHROME_APP" ]; then
            log "ERROR" "Chrome.app still exists after removal attempts"
            exit 74
        fi
        log "INFO" "Successfully removed old Chrome installation"
    fi
    
    # Create temp directory
    DATE=$(date '+%Y-%m-%d-%H-%M-%S')
    TEMP_DIR="/tmp/chrome-install-$DATE"
    mkdir -p "$TEMP_DIR" || die "Failed to create temp directory"
    get_real_user_and_home
    if [ "$EUID" -eq 0 ]; then
        chown "$CONSOLE_USER" "$TEMP_DIR"
    fi
    trap 'cleanup "$TEMP_DIR"' EXIT
    
    # Download Chrome
    local pkg_file="$TEMP_DIR/GoogleChrome.pkg"
    local download_url

    local download_url="$BASE_URL"
    get_real_user_and_home
    log "INFO" "Downloading Chrome PKG from $download_url"
    log "DEBUG" "Using browser-exported cookie for authentication."
    # Minimal curl test for debugging
    log "DEBUG" "Running minimal curl: curl -L --cookie \"$COOKIE_HEADER\" -o \"$pkg_file\" \"$download_url\""
    curl -L --cookie "$COOKIE_HEADER" -o "$pkg_file" "$download_url" >> "$LOG_FILE" 2>&1
    local curl_status=$?
    if [ $curl_status -ne 0 ]; then
        log "ERROR" "Minimal curl failed with exit code $curl_status. Aborting."
        return 1
    fi
    if [ ! -s "$pkg_file" ]; then
        log "ERROR" "Downloaded file is missing or empty: $pkg_file. Aborting."
        return 1
    fi
    log "INFO" "Chrome PKG downloaded successfully: $pkg_file"
    # Continue with the rest of the installation logic below...


    # Install package
    log "INFO" "Installing Chrome package"
    if ! installer -pkg "$pkg_file" -target /; then
        die "Failed to install Chrome package"
    fi
    
    # Verify installation
    if [ ! -d "$CHROME_APP" ]; then
        die "Chrome.app not found after installation"
    fi
    
    log "INFO" "Chrome installation completed successfully"
    # Restore log file permissions if root
    if [ "$EUID" -eq 0 ]; then
        chmod 644 "$LOG_FILE" 2>/dev/null || true
    fi
    return 0
}

# Run main function
main
