#!/usr/bin/env zsh
# Based on an open-source Homebrew bootstrap script, adapted for internal use.

# Logging config
LOG_NAME="homebrew_install.log"
LOG_DIR="/Library/Logs"
LOG_PATH="$LOG_DIR/$LOG_NAME"
MAX_LOG_SIZE_MB=10
MAX_LOG_FILES=5

# Enhanced logging function with rotation and error handling
logging() {
    # Args:
    #   $1: Log level. Examples "info", "warning", "debug", "error"
    #   $2: Log statement in string format
    local log_level script_name prefix log_statement current_size
    
    # Ensure log directory exists and is writable
    if ! /bin/mkdir -p "$LOG_DIR" 2>/dev/null; then
        /bin/echo "ERROR: Cannot create log directory $LOG_DIR" >&2
        return 1
    fi
    
    # Convert log level to uppercase, defaulting to INFO
    log_level=$(printf "%s" "${1:-INFO}" | /usr/bin/tr '[:lower:]' '[:upper:]')
    log_statement="${2:-}"
    script_name="$(/usr/bin/basename "$0")"
    prefix=$(/bin/date +"[%b %d, %Y %Z %T $log_level]:")
    
    # Rotate log if needed
    if [[ -f "$LOG_PATH" ]]; then
        current_size=$(/usr/bin/stat -f %z "$LOG_PATH" 2>/dev/null || echo "0")
        if (( current_size > MAX_LOG_SIZE_MB * 1024 * 1024 )); then
            # Rotate existing logs
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
    
    # Echo to stdout (properly escaped)
    /bin/echo "$prefix $log_statement"
    
    # Write to log file (properly escaped)
    printf "%s %s\n" "$prefix" "$log_statement" >>"$LOG_PATH" 2>/dev/null || {
        /bin/echo "ERROR: Failed to write to log file $LOG_PATH" >&2
        return 1
    }
}

check_brew_install_status() {
    # Check brew insall status.
    brew_path="$(/usr/bin/find /usr/local/bin /opt -maxdepth 3 -name brew 2>/dev/null)"

    if [[ -n $brew_path   ]]; then
        # If the brew binary is found just run brew update and exit
        logging "info" "Homebrew already installed at $brew_path ..."

        logging "info" "Updating homebrew ..."
        /usr/bin/su - "$current_user" -c "$brew_path update --force" | /usr/bin/tee -a "${LOG_PATH}"

        logging "info" "Done ..."
        exit 0

    else
        logging "info" "Homebrew is not installed ..."
    fi
}

rosetta2_check() {
    # Check for and install Rosetta2 if needed.
    # $1: processor_brand
    # Determine the processor brand
    if [[ "$1" == *"Apple"* ]]; then
        logging "info" "Apple Processor is present..."

        # Check if the Rosetta service is running
        check_rosetta_status=$(/usr/bin/pgrep oahd)

        # Rosetta Folder location
        # Condition to check to see if the Rosetta folder exists. This check was added because
        # the Rosetta2 service is already running in macOS versions 11.5 and greater without
        # Rosseta2 actually being installed.
        rosetta_folder="/Library/Apple/usr/share/rosetta"

        if [[ -n $check_rosetta_status ]] && [[ -e $rosetta_folder ]]; then
            logging "info" "Rosetta2 is installed... no action needed"

        else
            logging "info" "Rosetta is not installed... installing now"

            # Installs Rosetta
            /usr/sbin/softwareupdate --install-rosetta --agree-to-license | /usr/bin/tee -a "${LOG_PATH}"

            # Checks the outcome of the Rosetta install
            if [[ $? -ne 0 ]]; then
                logging "error" "Rosetta2 install failed..."
                exit 1
            fi
        fi

    else
        logging "info" "Apple Processor is not present... Rosetta2 not needed"
    fi
}

xcode_cli_tools() {
    # Check for and install Xcode CLI tools
    # Run command to check for an Xcode cli tools path
    /usr/bin/xcrun --version >/dev/null 2>&1

    # check to see if there is a valid CLI tools path
    if [[ $? -eq 0 ]]; then
        logging "info" "Valid Xcode path found. No need to install Xcode CLI tools ..."

    else
        logging "info" "Valid Xcode CLI tools path was not found ..."

        # find out when the OS was built
        build_year=$(/usr/bin/sw_vers -buildVersion | cut -c 1,2)

        # Trick softwareupdate into giving us everything it knows about xcode cli tools
        xclt_tmp="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

        # create the file above
        logging "info" "Creating $xclt_tmp ..."
        /usr/bin/touch "${xclt_tmp}"

        if [[ ${build_year} -ge 19 ]]; then
            # for Catalina or newer
            logging "info" "Getting the latest Xcode CLI tools available ..."
            cmd_line_tools=$(/usr/sbin/softwareupdate -l | awk '/\*\ Label: Command Line Tools/ { $1=$1;print }' | sed 's/^[[ \t]]*//;s/[[ \t]]*$//;s/*//' | cut -c 9-)

        else
            # For Mojave or older
            logging "info" "Getting the latest Xcode CLI tools available ..."
            cmd_line_tools=$(/usr/sbin/softwareupdate -l | /usr/bin/awk '/\*\ Command Line Tools/ { $1=$1;print }' | /usr/bin/grep -i "macOS" | /ussr/bin/sed 's/^[[ \t]]*//;s/[[ \t]]*$//;s/*//' | /usr/bin/cut -c 2-)

        fi

        if [[ "${cmd_line_tools}" == "" ]]; then
            logging "warning" "Unable to determine available XCode CLI tool updates ..."
            logging "warning" "This may require manual installation ..."

        else
            logging "info" "XCode CLI tool updates found: ${cmd_line_tools}"
        fi

        if (($(/usr/bin/grep -c . <<<"${cmd_line_tools}") > 1)); then
            cmd_line_tools_output="${cmd_line_tools}"
            cmd_line_tools=$(printf "${cmd_line_tools_output}" | /usr/bin/tail -1)

            logging "info" "Latest Xcode CLI tools found: $cmd_line_tools"
        fi

        # run softwareupdate to install xcode cli tools
        logging "info" "Installing the latest Xcode CLI tools ..."

        # Sending this output to the local homebrew_install.log as well as stdout
        /usr/sbin/softwareupdate -i "${cmd_line_tools}" --verbose | /usr/bin/tee -a "${LOG_PATH}"

        # cleanup the temp file
        logging "info" "Cleaning up $xclt_tmp ..."
        /bin/rm "${xclt_tmp}"

    fi
}

set_brew_prefix() {
    # Set the homebrew prefix.
    # Set the brew prefix to either the Apple Silicon location or the Intel location based on the
    # processor_brand information
    #
    # $1: proccessor brand information
    local brew_prefix

    if [[ $1 == *"Apple"* ]]; then
        # set brew prefix for apple silicon
        brew_prefix="/opt/homebrew"
    else
        # set brew prefix for Intel
        brew_prefix="/usr/local"
    fi

    # return the brew_prefix
    /bin/echo "$brew_prefix"
}

create_brew_environment() {
    # Create the brew environment.
    #
    # Create of the directories needed by brew, set the ownership, and set permissions.
    #
    # $1: brew_prefix
    # $2: current_user
    logging "info" "Creating directories required by brew ..."
    /bin/mkdir -p "${1}/Caskroom" "${1}/Cellar" "${1}/Frameworks" "${1}/Homebrew" "${1}/bin" "${1}/etc" "${1}/include" "${1}/lib" "${1}/opt" "${1}/sbin" "${1}/man/man1" "${1}/share/doc" "${1}/share/man/man1" "${1}/share/zsh/site-functions" "${1}/var" "${1}/var/homebrew/linked"

    logging "info" "Creating symlink to ${1}/bin/brew ..."
    /bin/ln -s "${1}/Homebrew/bin/brew" "${1}/bin/brew"

    logging "info" "Setting homebrew ownership to $2 ..."
    /usr/sbin/chown -R "$2" "${1}/Cellar" "${1}/Caskroom" "${1}/Frameworks" "${1}/Homebrew" "${1}/bin" "${1}/bin/brew" "${1}/etc" "${1}/include" "${1}/lib" "${1}/man" "${1}/opt" "${1}/sbin" "${1}/share" "${1}/var"

    logging "info" "Setting permissions for brew directories and files ..."
    /bin/chmod -R 755 "${1}/Homebrew" "${1}/Cellar" "${1}/Caskroom" "${1}/Frameworks" "${1}/bin" "${1}/bin/brew" "${1}/etc" "${1}/include" "${1}/lib" "${1}/man" "${1}/opt" "${1}/sbin" "${1}/share" "${1}/var"

}

reset_source() {
    # Reset the shell source so that brew doctor will find brew in the user's PATH
    if [[ -f "/Users/$current_user/.zshrc" ]]; then
        /usr/bin/su - "$current_user" -c source "/Users/$current_user/.zshrc" | /usr/bin/tee -a "${LOG_PATH}"
    fi

    if [[ -f "/Users/$current_user/.bashrc" ]]; then
        /usr/bin/su - "$current_user" -c source "/Users/$current_user/.bashrc" | /usr/bin/tee -a "${LOG_PATH}"
    fi

}

brew_doctor() {
    # Check Homebrew install status
    #
    # if on Apple Silicon you may see the following output from brew doctor
    #
    # Please note that these warnings are just used to help the Homebrew maintainers
    # with debugging if you file an issue. If everything you use Homebrew for is
    # working fine: please don't worry or file an issue; just ignore this. Thanks!
    #
    # Warning: Your Homebrew's prefix is not /usr/local.
    # Some of Homebrew's bottles (binary packages) can only be used with the default
    # prefix (/usr/local).
    # You will encounter build failures with some formulae.
    # Please create pull requests instead of asking for help on Homebrew's GitHub,
    # Twitter or any other official channels. You are responsible for resolving
    # any issues you experience while you are running this
    # unsupported configuration.
    #
    # $1: brew_prefix
    # $2: current_user

    /usr/bin/su - "$2" -c "$1/bin/brew doctor" 2>&1 | /usr/bin/tee -a "${LOG_PATH}"

    if [[ $? -ne 0 ]]; then
        logging "error" "brew doctor has errors. Review logs to see if action needs to be taken ..."
    else
        logging "info" "Homebrew installation complete! Your system is ready to brew."
    fi
}

###################################################################################################
############################ MAIN LOGIC - DO NOT MODIFY BELOW #####################################
###################################################################################################

# Do not modify the below, there be dragons. Modify at your own risk.

logging "info" "--- Start homebrew install log ---"
/bin/echo "Log file at /Library/Logs/homebrew_install.log"

# Get the processor brand information
processor_brand="$(/usr/sbin/sysctl -n machdep.cpu.brand_string)"

# Get the current logged in user excluding loginwindow, _mbsetupuser, and root
current_user=$(/usr/sbin/scutil <<<"show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ && ! /root/ && ! /_mbsetupuser/ { print $3 }' | /usr/bin/awk -F '@' '{print $1}')

# Make sure that we can find the most recent logged in user
if [[ $current_user == "" ]]; then
    logging "info" "Current user not logged in ..."
    logging "info" "Attempting to determine the most common user..."

    # Because someone other than the current user was returned we are going to look at who uses
    # the this Mac the most and then set current user to that user.
    current_user=$(/usr/sbin/ac -p | /usr/bin/sort -nk 2 | /usr/bin/grep -E -v "total|admin|root|mbsetup|adobe" | /usr/bin/tail -1 | /usr/bin/xargs | /usr/bin/cut -d " " -f1)

fi

logging "info" "Most common user: $current_user"

# Verify the current_user is valid
if /usr/bin/dscl . -read "/Users/$current_user" >/dev/null 2>&1; then
    logging "info" "$current_user is a valid user ..."

else
    logging "error" "Specified user \"$current_user\" is invalid"
    exit 1

fi

logging "info" "Checking to see if Homebew is already install on this Mac ..."
check_brew_install_status

logging "info" "Checking to see if Rosetta2 is needed ..."
rosetta2_check "$processor_brand"

logging "info" "Checking to see if Xcode cli tools are needed ..."
xcode_cli_tools

logging "info" "Determining Homebrew path prefix ..."
brew_prefix=$(set_brew_prefix $processor_brand)

logging "info" "Creating the Homebrew directory at $brew_prefix/Homebrew ..."
/bin/mkdir -p "$brew_prefix/Homebrew"

logging "info" "Downloading homebrew ..."

# Using curl to download the latest release of homebrew tarball and put it in brew_prefix/Homebew
# If brew updates to master to main, the url will need to be adjusted.
/usr/bin/curl --fail --silent --show-error --location --url "https://github.com/Homebrew/brew/tarball/master" | /usr/bin/tar xz --strip 1 -C "$brew_prefix/Homebrew" | /usr/bin/tee -a "${LOG_PATH}"

# checking to see if brew was downloaded successfully
if [[ -f "$brew_prefix/Homebrew/bin/brew" ]]; then
    logging "info" "Homebrew binary found at $brew_prefix/Homebrew/bin/brew ..."
    logging "info" "Creating the brew environment ..."
    create_brew_environment "$brew_prefix" "$current_user"

else
    logging "info" "Homebrew binary not found ..."
    /bin/echo "Check $LOG_PATH for more details ..."
    exit 1

fi

logging "info" "Running brew update --force ..."
/usr/bin/su - "$current_user" -c "$brew_prefix/bin/brew update --force" 2>&1 | /usr/bin/tee -a "${LOG_PATH}"

logging "info" "Running brew cleanup ..."
/usr/bin/su - "$current_user" -c "$brew_prefix/bin/brew cleanup" 2>&1 | /usr/bin/tee -a "${LOG_PATH}"

# Check for missing PATH
get_path_cmd=$(/usr/bin/su - "$current_user" -c "$brew_prefix/bin/brew doctor 2>&1 | /usr/bin/grep 'export PATH=' | /usr/bin/tail -1")

# Add Homebrew's "bin" to target user PATH
if [[ -n ${get_path_cmd} ]]; then
    logging "info" "Adding brew to path"
    /usr/bin/su - "$current_user" -c "${get_path_cmd}"
fi

logging "info" "Resetting the user's shell source file so that brew doctor can find it..."
reset_source

logging "info" "Running brew doctor to validate the install ..."
brew_doctor "$brew_prefix" "$current_user"

logging "info" "--- End homebrew install log ---"

exit 0
