#!/usr/bin/env zsh 



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

    # Create cache directory with proper permissions
    /bin/mkdir -p "/Users/${2}/Library/Caches/Homebrew"
    /bin/mkdir -p "/Users/${2}/.cache/Homebrew"
    
    logging "info" "Creating symlink to ${1}/bin/brew..."
    /bin/ln -sf "${1}/Homebrew/bin/brew" "${1}/bin/brew"

   # Logging config
LOG_NAME="homebrew_install.log"
LOG_DIR="/Library/Logs"
LOG_PATH="$LOG_DIR/$LOG_NAME"
MAX_LOG_SIZE_MB=10
MAX_LOG_FILES=5
    logging "info" "Setting homebrew ownership to ${2}..."
    /usr/sbin/chown -R "${2}" "${1}"
    /usr/sbin/chown -R "${2}" "/Users/${2}/Library/Caches/Homebrew"
    /usr/sbin/chown -R "${2}" "/Users/${2}/.cache/Homebrew"

    logging "info" "Setting permissions for brew directories and files..."
    /bin/chmod -R u+rwX "${1}"
    /bin/chmod -R 755 "${1}/Homebrew"
    /bin/chmod -R u+rwX "/Users/${2}/Library/Caches/Homebrew"
    /bin/chmod -R u+rwX "/Users/${2}/.cache/Homebrew"

    # Setup shell environment for the user
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

# ... [Rest of the original script remains the same] ...
