function Get-FgConnection {
    <#
    .SYNOPSIS
    Report this session's FOG connection and which credential store it uses.

    .DESCRIPTION
    Shows whether the session is connected, to which server, and which
    credential store this platform selected along with that store's scope.

    The token is never returned, in any form. Neither is any part of it.

    Scope is reported rather than left implicit because it is the thing people
    get wrong. The OS credential stores are per-user by design: a token saved
    by an administrator is not readable by a scheduled task running as another
    account, and Windows offers no way to write into another user's store. That
    is least privilege working correctly, but it has to be visible.

    .EXAMPLE
    Get-FgConnection

    IsConnected : True
    Server      : https://fog.example.org/
    User        : fogadmin
    Tier        : CredentialManager
    Scope       : current user on this machine

    .EXAMPLE
    (Get-FgConnection).Tier

    Reports File when no OS credential store was available, in which case Note
    says why.

    .LINK
    https://github.com/FOGProject/fog-sdk
    #>
    [FogSdk.Description('Report this session FOG connection and which credential store it uses.')]
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSObject])]
    param()

    process {
        $tierRec = Get-FogSdkStoreTier
        $connected = [FogSdk.FogConnection]::IsConnected

        [pscustomobject]@{
            PSTypeName  = 'FogSdk.Connection'
            IsConnected = $connected
            Server      = if ($connected) { [FogSdk.FogConnection]::Server.AbsoluteUri } else { $null }
            User        = if ($connected) { [FogSdk.FogConnection]::User } else { $null }
            AuthKind    = if ($connected) { 'bearer' } else { $null }
            Tier        = $tierRec.Tier
            Scope       = $tierRec.Scope
            Note        = $tierRec.Note
        }
    }
}
