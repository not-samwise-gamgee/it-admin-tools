#!/bin/bash
# Reset the TCC for accessibility
tccutil reset Accessibility

# Grant Accessibility to 'SlackHelper'
osascript -e 'tell application "System Events" to set the frontmost of process "Slack" to true'

# Delay timer for permissions to update
sleep 5

# Reopen Slack to trigger 'SlackHelper' prompt
open -a "Slack"
