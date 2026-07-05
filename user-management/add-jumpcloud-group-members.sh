#!/bin/bash
#
# Add one or more users to a JumpCloud user group.
#
# Configuration (all via environment / arguments — nothing hardcoded):
#   JUMPCLOUD_API_KEY          (required) JumpCloud API key
#   JUMPCLOUD_GROUP_ID         (required) target user group ID
#   JUMPCLOUD_MEMBER_IDS_FILE  (optional) path to a file with one user ID per line
#
# User IDs may also be passed as command-line arguments, e.g.:
#   JUMPCLOUD_GROUP_ID=<gid> ./add-jumpcloud-group-members.sh <userId1> <userId2> ...
#
set -euo pipefail

: "${JUMPCLOUD_API_KEY:?set JUMPCLOUD_API_KEY}"
: "${JUMPCLOUD_GROUP_ID:?set JUMPCLOUD_GROUP_ID}"

# Collect member IDs from command-line arguments and/or a file.
member_ids=("$@")

if [ -n "${JUMPCLOUD_MEMBER_IDS_FILE:-}" ]; then
	if [ ! -f "$JUMPCLOUD_MEMBER_IDS_FILE" ]; then
		echo "Member IDs file not found: $JUMPCLOUD_MEMBER_IDS_FILE" >&2
		exit 1
	fi
	while IFS= read -r line; do
		[ -n "$line" ] && member_ids+=("$line")
	done <"$JUMPCLOUD_MEMBER_IDS_FILE"
fi

if [ "${#member_ids[@]}" -eq 0 ]; then
	echo "No member IDs provided. Pass IDs as arguments or set JUMPCLOUD_MEMBER_IDS_FILE." >&2
	exit 1
fi

api_base="https://console.jumpcloud.com/api/v2"

# The JumpCloud group-membership endpoint takes ONE member per request.
for uid in "${member_ids[@]}"; do
	echo "Adding user ${uid} to group ${JUMPCLOUD_GROUP_ID} ..."
	curl --fail --silent --show-error --request POST \
		--url "${api_base}/usergroups/${JUMPCLOUD_GROUP_ID}/members" \
		--header 'content-type: application/json' \
		--header "x-api-key: ${JUMPCLOUD_API_KEY}" \
		--data "$(printf '{"op":"add","type":"user","id":"%s"}' "$uid")"
done

echo "Done."
