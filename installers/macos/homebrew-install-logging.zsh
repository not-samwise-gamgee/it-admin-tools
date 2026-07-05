#!/usr/bin/env zsh

# Logging config
LOG_NAME="homebrew_install.log"
LOG_DIR="/Library/Logs"
LOG_PATH="$LOG_DIR/$LOG_NAME"
MAX_LOG_SIZE_MB=10
MAX_LOG_FILES=5

logging() {
    # Enhanced logging function with rotation and error handling
    #
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
    /bin/echo "$prefix ${log_statement//\"/\\\"}"
    
    # Write to log file (properly escaped)
    printf "%s %s\n" "$prefix" "${log_statement//\"/\\\"}" >>"$LOG_PATH" 2>/dev/null || {
        /bin/echo "ERROR: Failed to write to log file $LOG_PATH" >&2
        return 1
    }
}

# Test the logging function
logging "info" "Testing log rotation and error handling"
logging "warning" "Test message with \"quotes\""
logging "error" "Test error message"
