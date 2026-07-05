#!/usr/bin/env zsh
# Enhanced Homebrew installer for Apple Silicon Macs
# Based on original work by Nicholas McDonald

# Function to get admin password via GUI prompt
get_admin_password() {
    local prompt="$1"
    local password
    
    # Try to get password via GUI prompt
    password=$(/usr/bin/osascript -e 'tell application "System Events"' \
        -e "display dialog \"${prompt}\" with title \"Homebrew Installation\" with icon caution with hidden answer default answer \"\" buttons {\"Cancel\", \"OK\"} default button \"OK\"" \
        -e 'text returned of result' \
        -e 'end tell' 2>/dev/null)
    
    if [[ $? -eq 0 && -n "$password" ]]; then
        echo "$password"
        return 0
    fi
    
    return 1
}

# Function to run command with admin privileges
run_with_password() {
    local cmd="$1"
    local prompt="$2"
    local password
    
    password=$(get_admin_password "$prompt")
    if [[ $? -eq 0 ]]; then
        echo "$password" | /usr/bin/sudo -S bash -c "$cmd" 2>/dev/null
        return $?
    fi
    
    logging "error" "Failed to get admin password"
    return 1
}

# Logging config
LOG_NAME="homebrew_install.log"
LOG_DIR="$HOME/Library/Logs"
LOG_PATH="$LOG_DIR/$LOG_NAME"
MAX_LOG_SIZE_MB=10
MAX_LOG_FILES=5

# Enhanced logging function with rotation and error handling
logging() {
    local log_level script_name prefix log_statement current_size
    
    # Ensure log directory exists and is writable
    if [[ ! -d "$LOG_DIR" ]]; then
        if ! /bin/mkdir -p "$LOG_DIR" 2>/dev/null; then
            LOG_DIR="$HOME/.cache/logs"
            if ! /bin/mkdir -p "$LOG_DIR" 2>/dev/null; then
                /bin/echo "ERROR: Cannot create log directory $LOG_DIR" >&2
                return 1
            fi
        fi
        LOG_PATH="$LOG_DIR/$LOG_NAME"
        /bin/echo "Log directory created at $LOG_DIR"
    fi
    
    # Touch log file to ensure it exists and is writable
    if ! /usr/bin/touch "$LOG_PATH" 2>/dev/null; then
        /bin/echo "ERROR: Cannot write to log file $LOG_PATH" >&2
        return 1
    fi
    
    log_level=$(printf "%s" "${1:-INFO}" | /usr/bin/tr '[:lower:]' '[:upper:]')
    log_statement="${2:-}"
    script_name="$(/usr/bin/basename "$0")"
    prefix=$(/bin/date +"[%b %d, %Y %Z %T $log_level]:")
    
    # Rotate log if needed
    if [[ -f "$LOG_PATH" ]]; then
        current_size=$(/usr/bin/stat -f %z "$LOG_PATH" 2>/dev/null || echo "0")
        if (( current_size > MAX_LOG_SIZE_MB * 1024 * 1024 )); then
            for (( i=MAX_LOG_FILES-1; i>=1; i-- )); do
                if [[ -f "${LOG_PATH}.$i" ]]; then
                    /bin/mv "${LOG_PATH}.$i" "${LOG_PATH}.$((i+1))" 2>/dev/null
                fi
            done
            /bin/mv "$LOG_PATH" "${LOG_PATH}.1" 2>/dev/null
        fi
    fi
    
    # Create log file if it doesn't exist
    if ! /usr/bin/touch "$LOG_PATH" 2>/dev/null; then
        /bin/echo "ERROR: Cannot create/access log file $LOG_PATH" >&2
        return 1
    fi
    
    # Ensure log file is writable
    if ! /bin/chmod 644 "$LOG_PATH" 2>/dev/null; then
        /bin/echo "WARNING: Cannot set permissions on $LOG_PATH" >&2
    fi
    
    /bin/echo "$prefix $log_statement"
    printf "%s %s\n" "$prefix" "$log_statement" >>"$LOG_PATH" 2>/dev/null || {
        /bin/echo "ERROR: Failed to write to log file $LOG_PATH" >&2
        return 1
    }
}

check_brew_install_status() {
    # Check if Homebrew is already installed
    local brew_path
    brew_path="$(/usr/bin/find /opt -maxdepth 3 -name brew 2>/dev/null)"

    if [[ -n $brew_path ]]; then
        logging "info" "Homebrew already installed at $brew_path"
        logging "info" "Updating homebrew..."
        logging "info" "Note: If Homebrew needs to update system files, it may ask for your password"
        # Check if we need sudo for the update
        if [[ -n "$(/opt/homebrew/bin/brew outdated --quiet)" ]]; then
            logging "info" "Updates available that may require admin privileges"
            password=$(get_admin_password "Homebrew needs to update some system files.\n\nPlease enter your password to continue.")
            if [[ $? -eq 0 ]]; then
                # Verify sudo access first
                if echo "$password" | /usr/bin/sudo -S /usr/bin/true 2>/dev/null; then
                    echo "$password" | /usr/bin/sudo -S /usr/bin/su - "$current_user" -c "/opt/homebrew/bin/brew update --force" 2>&1 | /usr/bin/tee -a "${LOG_PATH}"
                else
                    logging "error" "Invalid password provided"
                    # Try without sudo
                    /usr/bin/su - "$current_user" -c "/opt/homebrew/bin/brew update --force" 2>&1 | /usr/bin/tee -a "${LOG_PATH}"
                fi
            else
                logging "warning" "Could not get admin password for Homebrew update"
                # Try without sudo anyway
                /usr/bin/su - "$current_user" -c "/opt/homebrew/bin/brew update --force" | /usr/bin/tee -a "${LOG_PATH}"
            fi
        else
            # No updates requiring sudo
            /usr/bin/su - "$current_user" -c "/opt/homebrew/bin/brew update --force" | /usr/bin/tee -a "${LOG_PATH}"
        fi
        logging "info" "Done..."
        exit 0
    else
        logging "info" "Homebrew is not installed..."
    fi
}

xcode_cli_tools() {
    local install_timeout=1800  # 30 minutes timeout for installation
    local list_timeout=300     # 5 minutes timeout for listing updates
    local verify_wait=180      # 3 minutes wait for verification

    # Check for and install Xcode CLI tools if needed
    if ! /usr/bin/pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1; then
        logging "info" "Installing Xcode Command Line Tools..."
        logging "info" "Your password will be required to install the Xcode Command Line Tools"
        /bin/echo "\nNOTE: Password required for Xcode Command Line Tools installation"
        /bin/echo "This is a one-time requirement from Apple for installing system components.\n"
        
        # Create the placeholder file that's checked by CLI updates
        /usr/bin/touch "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
        
        # Get admin password for software update
        logging "info" "Requesting admin password for Xcode Command Line Tools installation..."
        local password
        password=$(get_admin_password "Administrator password required to install Xcode Command Line Tools.\n\nThis is a one-time requirement from Apple for installing system components.")
        
        if [[ $? -ne 0 ]]; then
            logging "error" "Failed to get admin password"
            /bin/rm -f "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
            return 1
        fi
        
        # Store password for subsequent commands
        export SUDO_ASKPASS=/bin/echo
        export SUDO_PASSWORD="$password"
        
        # Force software update catalog refresh with retries
        logging "info" "Refreshing software update catalog..."
        
        local max_attempts=3
        local attempt=1
        local wait_time=10
        local success=false
        
        while (( attempt <= max_attempts )) && [[ "$success" = false ]]; do
            logging "info" "Attempt $attempt of $max_attempts (waiting ${wait_time}s between retries)..."
            
            # First try to download updates only
            if echo "$SUDO_PASSWORD" | /usr/bin/sudo -S /usr/bin/true 2>/dev/null && \
               echo "$SUDO_PASSWORD" | /usr/bin/sudo -S /usr/sbin/softwareupdate --download-updates >/dev/null 2>&1; then
                success=true
                logging "info" "Catalog refresh successful"
                break
            fi
            
            logging "warning" "Standard catalog refresh failed, trying alternative method..."
            
            # If that fails, try to fetch the full installer
            if echo "$SUDO_PASSWORD" | /usr/bin/sudo -S /usr/bin/true 2>/dev/null && \
               echo "$SUDO_PASSWORD" | /usr/bin/sudo -S /usr/sbin/softwareupdate --fetch-full-installer --full-installer-version "$(sw_vers -productVersion)" >/dev/null 2>&1; then
                success=true
                logging "info" "Full installer fetch successful"
                break
            fi
            
            if (( attempt < max_attempts )); then
                logging "warning" "Attempt $attempt failed, waiting ${wait_time}s before retry..."
                /bin/sleep $wait_time
                wait_time=$((wait_time * 2))
            fi
            
            ((attempt++))
        done
        
        if [[ "$success" = false ]]; then
            logging "error" "Software update catalog refresh failed after $max_attempts attempts"
            /bin/rm -f "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
            return 1
        fi
        
        # Give the system a moment to process the catalog updates
        /bin/sleep 5
        
        # Find the latest version of Command Line Tools
        cli_label=$(/usr/bin/timeout 60 /usr/sbin/softwareupdate --list --all 2>&1 | \
            /usr/bin/grep -i "label: command line tools" | \
            /usr/bin/tail -n 1 | \
            /usr/bin/awk -F": " '{print $2}')
        
        if [[ -n "$cli_label" ]]; then
            logging "info" "Found Command Line Tools package: $cli_label"
            logging "info" "Installing Command Line Tools (this may take 15-20 minutes)..."
            
            # Install Command Line Tools with extended timeout
            if echo "$SUDO_PASSWORD" | /usr/bin/sudo -S /usr/bin/true 2>/dev/null && \
               echo "$SUDO_PASSWORD" | /usr/bin/sudo -S /usr/bin/timeout $install_timeout /usr/sbin/softwareupdate --install "$cli_label" --agree-to-license --verbose; then
                logging "info" "Command Line Tools installation process completed"
                /bin/rm -f "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
                
                # Wait for installation to fully complete and verify
                logging "info" "Waiting for installation to finalize (up to $verify_wait seconds)..."
                for (( i=1; i<=$verify_wait; i+=10 )); do
                    if /usr/bin/pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1; then
                        logging "info" "Verified Command Line Tools installation after $i seconds"
                        break
                    fi
                    /bin/sleep 10
                done
                
                # Final verification
                if ! /usr/bin/pkgutil --pkg-info=com.apple.pkg.CLTools_Executables >/dev/null 2>&1; then
                    logging "error" "Command Line Tools installation verification failed after $verify_wait seconds"
                    exit 1
                fi
            else
                logging "error" "Command Line Tools installation timed out after $install_timeout seconds"
                /bin/rm -f "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
                exit 1
            fi
        else
            logging "error" "Could not find Command Line Tools in Software Update"
            /bin/rm -f "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
            exit 1
        fi
    else
        logging "info" "Xcode Command Line Tools already installed"
    fi

    # Double check that git is available (should be part of CLI tools)
    if ! /usr/bin/which git >/dev/null 2>&1; then
        logging "error" "git not found after CLI tools installation"
        exit 1
    fi

    logging "info" "Xcode Command Line Tools installation completed successfully"
}

create_brew_environment() {
    # Create the brew environment with enhanced permissions for standard users
    #
    # $1: brew_prefix
    # $2: current_user
    
    local dirs=(
        "${1}/Caskroom"
        "${1}/Cellar"
        "${1}/Frameworks"
        "${1}/Homebrew"
        "${1}/bin"
        "${1}/etc"
        "${1}/include"
        "${1}/lib"
        "${1}/opt"
        "${1}/sbin"
        "${1}/man/man1"
        "${1}/share/doc"
        "${1}/share/man/man1"
        "${1}/share/zsh/site-functions"
        "${1}/var"
        "${1}/var/homebrew/linked"
    )

    logging "info" "Creating directories required by brew..."
    for dir in "${dirs[@]}"; do
        /bin/mkdir -p "$dir"
    done

    # Create cache directories with proper permissions
    /bin/mkdir -p "/Users/${2}/Library/Caches/Homebrew"
    /bin/mkdir -p "/Users/${2}/.cache/Homebrew"
    
    logging "info" "Creating symlink to ${1}/bin/brew..."
    /bin/ln -sf "${1}/Homebrew/bin/brew" "${1}/bin/brew"

    logging "info" "Setting homebrew ownership to ${2}..."
    /usr/sbin/chown -R "${2}" "${1}"
    /usr/sbin/chown -R "${2}" "/Users/${2}/Library/Caches/Homebrew"
    /usr/sbin/chown -R "${2}" "/Users/${2}/.cache/Homebrew"

    logging "info" "Setting permissions for brew directories and files..."
    /bin/chmod -R u+rwX "${1}"
    /bin/chmod -R 755 "${1}/Homebrew"
    /bin/chmod -R u+rwX "/Users/${2}/Library/Caches/Homebrew"
    /bin/chmod -R u+rwX "/Users/${2}/.cache/Homebrew"

    setup_shell_environment "${1}" "${2}"
}

setup_shell_environment() {
    # Setup shell environment for Homebrew
    #
    # $1: brew_prefix
    # $2: current_user
    
    local shell_profile
    local user_shell
    
    user_shell=$(/usr/bin/dscl . -read "/Users/${2}" UserShell | /usr/bin/awk '{print $2}')
    
    case "${user_shell}" in
        */bash)
            shell_profile="/Users/${2}/.bash_profile"
            ;;
        */zsh)
            shell_profile="/Users/${2}/.zprofile"
            ;;
        *)
            shell_profile="/Users/${2}/.profile"
            ;;
    esac
    
    logging "info" "Setting up shell environment in ${shell_profile}..."
    
    # Create profile if it doesn't exist
    /usr/bin/touch "${shell_profile}"
    /usr/sbin/chown "${2}" "${shell_profile}"
    
    # Add Homebrew to PATH and set other important environment variables
    cat << EOF | /usr/bin/tee -a "${shell_profile}" > /dev/null
# Homebrew environment setup
export HOMEBREW_PREFIX="${1}"
export HOMEBREW_CELLAR="${1}/Cellar"
export HOMEBREW_REPOSITORY="${1}/Homebrew"
export PATH="${1}/bin:${1}/sbin:\$PATH"
export MANPATH="${1}/share/man:\$MANPATH"
export INFOPATH="${1}/share/info:\$INFOPATH"
EOF
    
    # Source the profile for immediate effect
    /usr/bin/su - "${2}" -c "source ${shell_profile}"
}

###################################################################################################
############################ MAIN SCRIPT EXECUTION #################################################
###################################################################################################

logging "info" "--- Start homebrew install log ---"
/bin/echo "Log file at $LOG_PATH"

# Get the current logged in user excluding system users
current_user=$(/usr/sbin/scutil <<<"show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ && ! /root/ && ! /_mbsetupuser/ { print $3 }' | /usr/bin/awk -F '@' '{print $1}')

# If no logged in user found, get most active user
if [[ -z "$current_user" ]]; then
    logging "info" "Current user not logged in..."
    logging "info" "Determining most common user..."
    current_user=$(/usr/sbin/ac -p | /usr/bin/sort -nk 2 | /usr/bin/grep -E -v "total|admin|root|mbsetup|adobe" | /usr/bin/tail -1 | /usr/bin/xargs | /usr/bin/cut -d " " -f1)
fi

logging "info" "Target user: $current_user"

# Verify the current_user is valid
if ! /usr/bin/dscl . -read "/Users/$current_user" >/dev/null 2>&1; then
    logging "error" "Invalid user: $current_user"
    exit 1
fi

logging "info" "Checking Homebrew installation status..."
check_brew_install_status

logging "info" "Installing Xcode CLI tools if needed..."
xcode_cli_tools

# Set brew prefix for Apple Silicon
brew_prefix="/opt/homebrew"

logging "info" "Creating Homebrew directory at $brew_prefix..."
/bin/mkdir -p "$brew_prefix/Homebrew"

logging "info" "Downloading Homebrew..."
/usr/bin/curl --fail --silent --show-error --location --url "https://github.com/Homebrew/brew/tarball/master" | /usr/bin/tar xz --strip 1 -C "$brew_prefix/Homebrew" | /usr/bin/tee -a "${LOG_PATH}"

if [[ ! -f "$brew_prefix/Homebrew/bin/brew" ]]; then
    logging "error" "Homebrew binary not found after download"
    exit 1
fi

logging "info" "Setting up Homebrew environment..."
create_brew_environment "$brew_prefix" "$current_user"

logging "info" "Running initial brew update..."
/usr/bin/su - "$current_user" -c "$brew_prefix/bin/brew update --force" 2>&1 | /usr/bin/tee -a "${LOG_PATH}"

logging "info" "Running brew cleanup..."
/usr/bin/su - "$current_user" -c "$brew_prefix/bin/brew cleanup" 2>&1 | /usr/bin/tee -a "${LOG_PATH}"

logging "info" "Verifying installation..."
if /usr/bin/su - "$current_user" -c "$brew_prefix/bin/brew doctor" 2>&1 | /usr/bin/tee -a "${LOG_PATH}"; then
    logging "info" "Homebrew installation successful!"
else
    logging "warning" "Homebrew installed but 'brew doctor' reported issues. Check the logs for details."
fi

logging "info" "--- End homebrew install log ---"
exit 0
