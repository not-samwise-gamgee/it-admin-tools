#Requires -Modules ExchangeOnlineManagement

<#
.SYNOPSIS
    Converts a user mailbox to a shared mailbox and verifies the change.
.DESCRIPTION
    Run against an authenticated Exchange Online session. Sets the specified
    mailbox to type Shared, then displays its resulting recipient type.
.PARAMETER Identity
    The primary SMTP address (or identity) of the mailbox to convert.
.EXAMPLE
    ./convert-shared-mailbox.ps1 -Identity "firstname.lastname@example.com"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Identity
)

Set-Mailbox -Identity $Identity -Type Shared

Get-Mailbox -Identity $Identity | Format-Table Name, RecipientTypeDetails
