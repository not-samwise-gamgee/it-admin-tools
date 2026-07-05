#!/bin/zsh
# shellcheck disable=SC1071  # genuine zsh script (array syntax); validated with `zsh -n`


##########VARIABLES#########

onepw_seven_path="/Applications/1Password 7.app"


#####BODY####


#Populate array of users from DSCL with UID ≥500
dscl_users=($(/usr/bin/dscl /Local/Default -list /Users UniqueID | /usr/bin/awk '$2 >= 500 {print $1}'))

#Kill 1PW7 Processes
/bin/echo "Killing any active 1Password 7 processes..."
/bin/ps aux | /usr/bin/grep -i "1Password 7.app\|onepassword7" | /usr/bin/grep -v grep | /usr/bin/awk '{print $2}' | /usr/bin/xargs kill -9

if [[ -e "${onepw_seven_path}" ]]; then
    /bin/echo "Deleting application bundle for 1Password 7..."
    /bin/rm -f -R "${onepw_seven_path}"
fi

for du in "${dscl_users[@]}"; do
    #Derive home directory value from DSCL attribute
    user_dir=$(/usr/bin/dscl /Local/Default -read "/Users/${du}" NFSHomeDirectory | /usr/bin/cut -d ":" -f2 | /usr/bin/xargs)

    #Confirm User Library dir exists
    if [[ -d "${user_dir}/Library" ]]; then
        /bin/echo "Valid user directory for ${du} at ${user_dir}"

        onepw_dirs=(
        "${user_dir}/Library/Application Scripts/com.agilebits.onepassword7-launcher"
        "${user_dir}/Library/Application Scripts/com.agilebits.onepassword7"
        "${user_dir}/Library/Application Scripts/com.agilebits.onepassword7.1PasswordSafariAppExtension"
        "${user_dir}/Library/Group Containers/2BUA8C4S2C.com.agilebits"
        "${user_dir}/Library/Containers/com.agilebits.onepassword7"
        "${user_dir}/Library/Containers/com.agilebits.onepassword7-launcher"
        "${user_dir}/Library/Containers/com.agilebits.onepassword7.1PasswordSafariAppExtension"
        "${user_dir}/Library/Containers/2BUA8C4S2C.com.agilebits.onepassword7-helper"
        "${user_dir}/Library/Preferences/com.agilebits.onepassword7.plist"
        "${user_dir}/Library/Preferences/Application Support/com.agilebits.onepassword7"
        )

        #Iterate over array of the above user directories
        #If any paths are found, print match to stdout and delete them
        for dir in "${onepw_dirs[@]}"; do
            if [[ -e "${dir}" ]]; then
                /bin/echo "Removing ${dir}..."
                /bin/rm -f -R "${dir}" 2>/dev/null
            fi
        done
    fi
done

exit 0
