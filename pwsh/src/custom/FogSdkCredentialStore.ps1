# Credential storage for fog-sdk: tier selection, the POSIX keyring shell-outs,
# and the file fallback.
#
# The Windows native tiers (Credential Manager, DPAPI-NG) are P/Invoke and live
# in FogNativeStore.cs. Everything else is here, where it can be tested without
# a compile.
#
# None of these are exported. They are marked [FogSdk.DoNotExport()] so the
# build does not turn them into cmdlets -- the public surface is
# Connect-FgServer / Disconnect-FgServer / Get-FgConnection and nothing else.
#
# The cross-language contract, which the Python client must match exactly:
#
#   target  : fog-sdk:<server-host>
#   account : the FOG username, or 'fog-sdk' when unknown
#   payload : {"v":1,"server":...,"authKind":"bearer","token":...,"user":...}
#
# Bearer only. The SDK is generated from a 1.6 document and cannot describe a
# 1.5 server, so carrying the legacy fog-api-token + fog-user-token pair would
# add a second credential shape to this contract for servers this client cannot
# talk to anyway. FogApi continues to serve 1.5 users on its own path.
# authKind is still recorded so a later shape can be added without a version
# bump breaking readers.
#
# Changing any of that breaks interop with the Python SDK silently, so the
# interop test is the thing that keeps it honest, not this comment.

function Get-FogSdkStoreTarget {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Server)
    process {
        $h = $Server
        if ($h -match '^[a-z][a-z0-9+.-]*://') { $h = ([uri]$Server).Host }
        "fog-sdk:$($h.ToLowerInvariant())"
    }
}

function Test-FogSdkCommand {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    process { $null -ne (Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue) }
}

<#
    Which store this session will actually use, and why.

    Reported by Get-FgConnection rather than left implicit: the scope of the
    store is the thing people get wrong. A credential saved by an admin is not
    readable by a scheduled task running as another account, and Windows offers
    no way to write into another user's store. That is least privilege working
    correctly, but it has to be visible or it gets discovered in production.
#>
<#
    Is there a human here to answer a prompt?

    This exists because of a real outage, not a hypothetical. A scheduled task
    hit a Get-Credential with an empty vault and did NOT fail -- it blocked,
    until Task Scheduler killed it at its five-minute ExecutionTimeLimit. FOG
    imaging automation is exactly that shape, so Connect-FgServer must throw a
    clear error rather than prompt when nobody is there.

    [Environment]::UserInteractive alone is not enough: it reports true for a
    scheduled task configured to run whether or not a user is logged on. The
    redirected-stdin check is what actually catches non-interactive hosts.
#>
function Test-FogSdkInteractive {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param()
    process {
        if (-not [Environment]::UserInteractive) { return $false }
        if ([Console]::IsInputRedirected) { return $false }
        # A host with no RawUI cannot prompt either.
        if ($null -eq $Host -or $null -eq $Host.UI -or $null -eq $Host.UI.RawUI) { return $false }
        $true
    }
}

function Get-FogSdkStoreTier {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param()
    process {
        if ($IsWindows -or $null -eq $IsWindows) {
            # $IsWindows is $null on Windows PowerShell 5.1, where the only
            # possible platform is Windows.
            if ('FogSdk.FogCredentialManager' -as [type]) {
                return [pscustomobject]@{
                    Tier  = 'CredentialManager'
                    Scope = 'current user on this machine'
                    Note  = $null
                }
            }
            return [pscustomobject]@{
                Tier  = 'File'
                Scope = 'current user on this machine'
                Note  = 'Credential Manager interop unavailable (Add-Type may be blocked by Constrained Language Mode or WDAC)'
            }
        }
        if ($IsMacOS) {
            if (Test-FogSdkCommand 'security') {
                return [pscustomobject]@{ Tier = 'Keychain'; Scope = 'current user login keychain'; Note = $null }
            }
            return [pscustomobject]@{ Tier = 'File'; Scope = 'current user on this machine'; Note = 'security(1) not found' }
        }
        if ($IsLinux) {
            # SecretService needs a running D-Bus session AND an unlocked
            # collection. Over SSH to a FOG server -- the common case for this
            # module -- there is usually neither, so the file fallback carries
            # more weight on Linux than the tier order suggests.
            if ((Test-FogSdkCommand 'secret-tool') -and $env:DBUS_SESSION_BUS_ADDRESS) {
                return [pscustomobject]@{ Tier = 'SecretService'; Scope = 'current user login keyring'; Note = $null }
            }
            $why = if (-not (Test-FogSdkCommand 'secret-tool')) { 'secret-tool not found' } else { 'no D-Bus session' }
            return [pscustomobject]@{ Tier = 'File'; Scope = 'current user on this machine'; Note = $why }
        }
        [pscustomobject]@{ Tier = 'File'; Scope = 'current user on this machine'; Note = 'unrecognised platform' }
    }
}

<#
    The fallback file's path.

    LOCALAPPDATA, deliberately NOT APPDATA. FogApi stores its tokens under the
    roaming %APPDATA%, which replicates them to the domain profile share and to
    every machine the user signs into -- the file permissions are defeated
    before they are applied. Local only.
#>
function Get-FogSdkStoreFile {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)
    process {
        if ($IsWindows -or $null -eq $IsWindows) {
            $root = $env:LOCALAPPDATA
            if (-not $root) { $root = Join-Path $env:USERPROFILE 'AppData\Local' }
            $dir = Join-Path $root 'fog-sdk'
        } else {
            $base = $env:XDG_STATE_HOME
            if (-not $base) { $base = Join-Path $HOME '.local/state' }
            $dir = Join-Path $base 'fog-sdk'
        }
        $leaf = ($Target -replace '[^A-Za-z0-9._-]', '_') + '.json'
        [pscustomobject]@{ Directory = $dir; Path = (Join-Path $dir $leaf) }
    }
}

<#
    Lock down the fallback file AND its directory.

    FogApi permissions only the file, never the parent, and invokes chmod
    without checking that it worked. Both are fixed here, and the result is
    verified rather than assumed -- an unchecked chmod that silently failed is
    indistinguishable from one that succeeded.
#>
function Set-FogSdkStoreSecurity {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Path
    )
    process {
        if ($IsWindows -or $null -eq $IsWindows) {
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $Access = [System.Security.AccessControl.AccessControlSections]::Access

            foreach ($p in @($Directory, $Path)) {
                $isDir = ($p -eq $Directory)

                # Read and write the DACL SECTION ONLY.
                #
                # Get-Acl returns the whole security descriptor, so handing it
                # back to Set-Acl tries to write the SACL too and fails with
                # "does not possess the 'SeSecurityPrivilege' privilege" for a
                # normal user. FogApi hits exactly this and falls back to six
                # icacls invocations; naming the Access section avoids the
                # problem rather than working around it.
                #
                # Verified against the alternatives: Get-Acl + Set-Acl fails,
                # this succeeds.
                $info = if ($isDir) {
                    [System.IO.DirectoryInfo]::new($p)
                } else {
                    [System.IO.FileInfo]::new($p)
                }
                $acl = [System.IO.FileSystemAclExtensions]::GetAccessControl($info, $Access)

                # Protect and copy nothing: this already discards the
                # inherited ACEs, so .Access can come back empty. Filter, or
                # RemoveAccessRule is handed a null and throws.
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($rule in @($acl.Access | Where-Object { $null -ne $_ })) {
                    [void]$acl.RemoveAccessRule($rule)
                }

                $inherit = if ($isDir) { 'ContainerInherit, ObjectInherit' } else { 'None' }
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $me, 'FullControl', $inherit, 'None', 'Allow')))

                [System.IO.FileSystemAclExtensions]::SetAccessControl($info, $acl)
            }

            # Verify rather than trust, the same as the POSIX branch below.
            $check = Get-Acl -LiteralPath $Path
            if (-not $check.AreAccessRulesProtected) {
                throw "Inheritance is still enabled on $Path after setting its ACL"
            }
            $others = @($check.Access | Where-Object { $_.IdentityReference.Value -ne $me })
            if ($others.Count -gt 0) {
                throw "$Path is still readable by: $(($others.IdentityReference.Value) -join ', ')"
            }
            return
        }

        & chmod 700 $Directory
        if ($LASTEXITCODE -ne 0) { throw "chmod 700 failed on $Directory (exit $LASTEXITCODE)" }
        & chmod 600 $Path
        if ($LASTEXITCODE -ne 0) { throw "chmod 600 failed on $Path (exit $LASTEXITCODE)" }

        # Verify, do not trust. A chmod that silently did nothing looks exactly
        # like one that worked.
        $mode = (& stat -c '%a' $Path 2>$null)
        if ($LASTEXITCODE -eq 0 -and $mode -and $mode -ne '600') {
            throw "Expected mode 600 on $Path after chmod, got $mode"
        }
    }
}

function Save-FogSdkSecret {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$Payload,
        [string]$Tier
    )
    process {
        if (-not $Tier) { $Tier = (Get-FogSdkStoreTier).Tier }
        switch ($Tier) {
            'CredentialManager' { [FogSdk.FogCredentialManager]::Save($Target, $Account, $Payload); return }
            'Keychain' {
                & security add-generic-password -U -a $Account -s $Target -w $Payload 2>$null
                if ($LASTEXITCODE -ne 0) { throw "security add-generic-password failed (exit $LASTEXITCODE)" }
                return
            }
            'SecretService' {
                $Payload | & secret-tool store --label="fog-sdk" service $Target account $Account
                if ($LASTEXITCODE -ne 0) { throw "secret-tool store failed (exit $LASTEXITCODE)" }
                return
            }
            'File' {
                $f = Get-FogSdkStoreFile -Target $Target
                if (-not (Test-Path -LiteralPath $f.Directory)) {
                    [void](New-Item -ItemType Directory -Path $f.Directory -Force)
                }
                # UTF8 without BOM, not -Encoding oem as FogApi uses.
                [System.IO.File]::WriteAllText($f.Path, $Payload, (New-Object System.Text.UTF8Encoding($false)))
                Set-FogSdkStoreSecurity -Directory $f.Directory -Path $f.Path
                return
            }
        }
        throw "Unknown storage tier: $Tier"
    }
}

function Get-FogSdkSecret {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Account = 'fog-sdk',
        [string]$Tier
    )
    process {
        if (-not $Tier) { $Tier = (Get-FogSdkStoreTier).Tier }
        switch ($Tier) {
            'CredentialManager' { return [FogSdk.FogCredentialManager]::Load($Target) }
            'Keychain' {
                $v = & security find-generic-password -a $Account -s $Target -w 2>$null
                if ($LASTEXITCODE -ne 0) { return $null }
                return $v
            }
            'SecretService' {
                $v = & secret-tool lookup service $Target account $Account 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $v) { return $null }
                return $v
            }
            'File' {
                $f = Get-FogSdkStoreFile -Target $Target
                if (-not (Test-Path -LiteralPath $f.Path)) { return $null }
                return [System.IO.File]::ReadAllText($f.Path)
            }
        }
        throw "Unknown storage tier: $Tier"
    }
}

function Clear-FogSdkSecret {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$Account = 'fog-sdk',
        [string]$Tier
    )
    process {
        if (-not $Tier) { $Tier = (Get-FogSdkStoreTier).Tier }
        switch ($Tier) {
            'CredentialManager' { return [FogSdk.FogCredentialManager]::Clear($Target) }
            'Keychain' {
                & security delete-generic-password -a $Account -s $Target 2>$null | Out-Null
                return ($LASTEXITCODE -eq 0)
            }
            'SecretService' {
                & secret-tool clear service $Target account $Account 2>$null | Out-Null
                return ($LASTEXITCODE -eq 0)
            }
            'File' {
                $f = Get-FogSdkStoreFile -Target $Target
                if (-not (Test-Path -LiteralPath $f.Path)) { return $false }
                Remove-Item -LiteralPath $f.Path -Force
                return $true
            }
        }
        throw "Unknown storage tier: $Tier"
    }
}

<#
    Build and parse the versioned payload.

    Kept in one place because the Python client has to produce byte-compatible
    JSON. Field order is not significant; field names and the version are.
#>
function New-FogSdkPayload {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Token,
        [string]$User
    )
    process {
        $o = [ordered]@{ v = 1; server = $Server; authKind = 'bearer'; token = $Token }
        if ($User) { $o['user'] = $User }
        ($o | ConvertTo-Json -Compress -Depth 4)
    }
}

function ConvertFrom-FogSdkPayload {
    [FogSdk.DoNotExport()]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Payload)
    process {
        $o = $Payload | ConvertFrom-Json
        if ($o.v -ne 1) { throw "Unsupported credential payload version: $($o.v)" }
        if ($o.authKind -ne 'bearer') {
            throw "Unsupported authKind '$($o.authKind)'. This SDK is bearer-only."
        }
        $o
    }
}
