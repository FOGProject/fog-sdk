function Connect-FgServer {
    <#
    .SYNOPSIS
    Connect this session to a FOG server using a bearer API token.

    .DESCRIPTION
    Stores the server and token for the life of the session, so every Fg*
    cmdlet authenticates without further arguments. The token is held as a
    SecureString and revealed only while a request is being built.

    Unless -NoSave is given, the token is also written to the best credential
    store this platform offers: Windows Credential Manager, the macOS Keychain,
    or libsecret, falling back to a permissioned file where none is available.
    Get-FgConnection reports which was used and what its scope is.

    Called with no -Token, this reconnects from the stored credential. If
    nothing is stored it prompts, but only when a human is present: in a
    non-interactive session it throws instead, because a prompt there does not
    fail, it hangs until something kills it.

    Tokens are issued from the API tab of a FOG user with API access enabled.
    They are fog_ prefixed, shown once, and hashed at rest, so a lost token
    cannot be recovered and must be reissued.

    This SDK is bearer-only. The older fog-api-token and fog-user-token header
    pair still works against a FOG server and is not deprecated, but the SDK is
    generated from a 1.6 document and cannot describe a 1.5 server; FogApi
    serves those users.

    .PARAMETER Server
    The FOG server, as a hostname or a URL. A bare hostname is assumed https.
    May be omitted when FOG_SDK_SERVER is set.

    .PARAMETER Token
    The bearer API token, as a SecureString. May be omitted when FOG_SDK_TOKEN
    is set, or when a credential is already stored for this server.

    .PARAMETER User
    The FOG username the token belongs to. Recorded alongside the credential so
    several tokens for one server can be told apart; it is not sent anywhere.

    .PARAMETER NoSave
    Hold the token in memory for this session only and write nothing to disk.
    Use in CI, or anywhere the machine should not retain the credential.

    .PARAMETER PassThru
    Emit the resulting connection, exactly as Get-FgConnection would. The token
    is never included.

    .EXAMPLE
    Connect-FgServer -Server fog.example.org -Token (Read-Host -AsSecureString)

    Connects and saves the token to this account's credential store.

    .EXAMPLE
    Connect-FgServer -Server fog.example.org

    Reconnects from the stored credential, prompting only if nothing is stored
    and a human is present.

    .EXAMPLE
    $env:FOG_SDK_SERVER = 'fog.example.org'
    $env:FOG_SDK_TOKEN  = '<token>'
    Connect-FgServer

    The CI shape: nothing touches disk. An environment token is never written
    to the credential store, so no -NoSave is needed. The Python client reads
    the same two variables.

    .EXAMPLE
    Connect-FgServer -Server fog.example.org -Token (Read-Host -AsSecureString)

    Run this as the account a scheduled task runs as, not as yourself. The
    credential stores are per-user by design, so a token saved by an
    administrator is not readable by the task's account and cannot be copied
    across.

    .LINK
    https://github.com/FOGProject/fog-sdk
    #>
    [FogSdk.Description('Connect this session to a FOG server using a bearer API token.')]
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([System.Management.Automation.PSObject])]
    param(
        [Parameter(Position = 0)]
        [string]${Server},

        [Parameter()]
        [securestring]${Token},

        [Parameter()]
        [string]${User},

        [Parameter()]
        [switch]${NoSave},

        [Parameter()]
        [switch]${PassThru}
    )

    process {
        # Resolution order, identical to the Python client's connect():
        #   1. what the caller passed
        #   2. the environment
        #   3. the credential store
        #   4. a prompt, but ONLY when a human is there
        #   5. an error
        #
        # The environment half exists for CI, where -NoSave keeps the token out
        # of the store but something still has to supply it.
        if (-not $Server) { $Server = $env:FOG_SDK_SERVER }
        if (-not $Server) {
            throw 'No -Server given and FOG_SDK_SERVER is not set.'
        }

        $uri = if ($Server -match '^[a-z][a-z0-9+.-]*://') { [uri]$Server } else { [uri]"https://$Server" }
        if (-not $uri.Host) { throw "Could not read a hostname from -Server '$Server'." }

        $target  = Get-FogSdkStoreTarget -Server $uri.AbsoluteUri
        $tierRec = Get-FogSdkStoreTier
        $account = if ($User) { $User } else { 'fog-sdk' }

        $supplied = $PSBoundParameters.ContainsKey('Token')

        if (-not $supplied -and $env:FOG_SDK_TOKEN) {
            $Token = ConvertTo-SecureString $env:FOG_SDK_TOKEN -AsPlainText -Force
            # Treated as supplied-but-not-saved: an environment token is a CI
            # affordance, and writing it to the machine's credential store
            # would be a surprising side effect of setting a variable.
            $fromEnv = $true
        }
        elseif (-not $supplied) {
            # Reconnect from the store before considering a prompt.
            $stored = Get-FogSdkSecret -Target $target -Account $account -Tier $tierRec.Tier
            if ($stored) {
                $payload = ConvertFrom-FogSdkPayload -Payload $stored
                $Token = ConvertTo-SecureString $payload.token -AsPlainText -Force
                if (-not $User -and $payload.user) { $User = $payload.user }
            }
            elseif (Test-FogSdkInteractive) {
                $Token = Read-Host -Prompt "FOG API token for $($uri.Host)" -AsSecureString
            }
            else {
                # Never prompt with nobody there. A prompt in a scheduled task
                # blocks until the task is killed, which reads as a hang rather
                # than a failure.
                throw @"
No stored credential for $($uri.Host), and this session is not interactive so there is nothing to prompt.

Pass -Token, or run Connect-FgServer interactively AS THIS ACCOUNT first:
the $($tierRec.Tier) store is scoped to $($tierRec.Scope), so a credential
saved by another account is not readable here and cannot be copied across.
"@
            }
        }

        if ($null -eq $Token -or $Token.Length -eq 0) {
            throw 'No token supplied.'
        }

        if ($PSCmdlet.ShouldProcess($uri.Host, 'Connect')) {
            [FogSdk.FogConnection]::Set($uri, $Token, $User)
            [FogSdk.FogConnection]::Tier = $tierRec.Tier

            if ($supplied -and -not $NoSave -and -not $fromEnv) {
                $plain = [System.Net.NetworkCredential]::new('', $Token).Password
                try {
                    $payload = New-FogSdkPayload -Server $uri.AbsoluteUri -Token $plain -User $User
                    Save-FogSdkSecret -Target $target -Account $account -Payload $payload -Tier $tierRec.Tier
                }
                finally {
                    # Not a strong guarantee, but it keeps the plaintext out of
                    # a variable that outlives this block.
                    $plain = $null
                    [System.GC]::Collect()
                }
            }
        }

        # Nothing is returned unless asked for, and never the token. FogApi's
        # Set-FogServerSettings returns both of its tokens to the pipeline,
        # which puts them in console scrollback and PSReadLine history.
        if ($PassThru) { Get-FgConnection }
    }
}
