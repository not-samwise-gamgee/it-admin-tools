#!/bin/bash
# shellcheck shell=bash

################################################################################################
# Software Information
################################################################################################
# This script removes any manually-installed USER-level configuration profiles.
#
# Notes for current macOS:
#   * `profiles -P` is deprecated (superseded by `profiles list` / `profiles show`) but is
#     still functional and remains the most reliable one-shot listing that emits both the
#     owning user and the profile identifier on a single line, e.g.:
#         someuser[1] attribute: profileIdentifier: com.example.foo
#         _computerlevel[2] attribute: profileIdentifier: com.apple.bar
#   * Only user-level profiles are targeted. Computer-level (_computerlevel) profiles are
#     skipped, and MDM-managed / non-removable profiles cannot be removed this way (they are
#     reported and skipped rather than causing a failure).
################################################################################################
# License Information
################################################################################################
# Provided as-is under the MIT License.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
# to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
################################################################################################

set -euo pipefail

# Collect installed profiles, keeping only the per-profile identifier lines. The trailing
# "There are N configuration profiles installed" summary line has no "profileIdentifier:"
# token and is therefore filtered out automatically.
profileDump=$(/usr/bin/sudo /usr/bin/profiles -P 2>/dev/null | /usr/bin/grep "profileIdentifier:" || true)

if [ -z "${profileDump}" ]; then
	echo "No user-level configuration profiles found..."
	exit 0
fi

removed=0

# Iterate line-by-line (newlines preserved) and act only on user-level entries.
while IFS= read -r line; do
	[ -z "${line}" ] && continue

	# The leading token is "<owner>[<index>]" — "_computerlevel" for machine-level profiles,
	# otherwise the username the profile is installed for.
	owner=$(printf '%s\n' "${line}" | /usr/bin/awk '{print $1}' | /usr/bin/cut -d'[' -f1)

	# Skip computer-level profiles; this script only targets user-level ones.
	[ "${owner}" = "_computerlevel" ] && continue

	# The profile identifier is the token immediately after "profileIdentifier:".
	identifier=$(printf '%s\n' "${line}" | /usr/bin/sed -E 's/.*profileIdentifier:[[:space:]]*//' | /usr/bin/awk '{print $1}')
	identifier="${identifier%;}"   # strip any trailing ';' if extra fields follow

	[ -z "${identifier}" ] && continue

	echo "Profile Identifier: ${identifier} installed for User: ${owner}... removing profile"

	# Prefer the modern verb form; fall back to the legacy flag form if it is unsupported.
	if /usr/bin/sudo /usr/bin/profiles remove -identifier "${identifier}" -user "${owner}" 2>/dev/null; then
		removed=$((removed + 1))
	elif /usr/bin/sudo /usr/bin/profiles -R -p "${identifier}" -U "${owner}" 2>/dev/null; then
		removed=$((removed + 1))
	else
		echo "  Could not remove ${identifier} for ${owner} (likely MDM-managed or non-removable)... skipping."
	fi
done <<EOF
${profileDump}
EOF

echo "Done removing User Level Profiles... removed ${removed} profile(s)."
exit 0
