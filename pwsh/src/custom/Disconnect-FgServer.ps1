function Disconnect-FgServer {
    <#
    .SYNOPSIS
    Clear this session's FOG connection, and optionally forget the stored token.

    .DESCRIPTION
    Drops the server and token held for this session. Subsequent Fg* cmdlets
    fail until Connect-FgServer is run again.

    This does NOT revoke anything on the server. FOG deliberately exposes no
    token-management REST surface, so that one API credential cannot mint or
    destroy another: issuing and revoking tokens are UI actions behind a
    session and CSRF. A token forgotten here remains valid until someone
    disables or deletes it in the FOG UI, under the owning user's API tab.

    If a token may have leaked, revoke it there. Disconnecting is not a
    security action.

    .PARAMETER Forget
    Also remove the token from this account's credential store, so a later
    Connect-FgServer will not silently reconnect with it.

    .PARAMETER Server
    Which server to forget. Only needed with -Forget when the session is
    already disconnected; otherwise the current connection is used.

    .EXAMPLE
    Disconnect-FgServer

    Clears the session. The stored token remains, so Connect-FgServer will
    reconnect without a prompt.

    .EXAMPLE
    Disconnect-FgServer -Forget

    Clears the session and removes the stored token from this machine. The
    token is still valid on the FOG server until revoked in the UI.

    .LINK
    https://github.com/FOGProject/fog-sdk
    #>
    [FogSdk.Description('Clear this session FOG connection, and optionally forget the stored token.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([void])]
    param(
        [Parameter()]
        [switch]${Forget},

        [Parameter()]
        [string]${Server}
    )

    process {
        $host_ = $Server
        if (-not $host_ -and [FogSdk.FogConnection]::IsConnected) {
            $host_ = [FogSdk.FogConnection]::Server.Host
        }

        if ($Forget) {
            if (-not $host_) {
                throw 'Nothing is connected and no -Server was given, so there is nothing to forget.'
            }
            $target  = Get-FogSdkStoreTarget -Server $host_
            $tierRec = Get-FogSdkStoreTier
            $account = if ([FogSdk.FogConnection]::User) { [FogSdk.FogConnection]::User } else { 'fog-sdk' }

            if ($PSCmdlet.ShouldProcess($host_, 'Remove the stored credential')) {
                $removed = Clear-FogSdkSecret -Target $target -Account $account -Tier $tierRec.Tier
                if ($removed) {
                    Write-Verbose "Removed the stored credential for $host_ from the $($tierRec.Tier) store."
                } else {
                    Write-Verbose "No stored credential for $host_ in the $($tierRec.Tier) store."
                }
                Write-Warning "The token is still valid on $host_. Revoke it in the FOG UI, under the owning user's API tab -- there is no REST route that can."
            }
        }

        # No ternary: this module supports Windows PowerShell 5.1, where
        # `a ? b : c` is a parse error.
        $what = if ($host_) { $host_ } else { 'this session' }
        if ($PSCmdlet.ShouldProcess($what, 'Disconnect')) {
            [FogSdk.FogConnection]::Clear()
        }
    }
}
