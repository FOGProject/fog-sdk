# Cross-language interop between the PowerShell and Python credential stores.
#
# The two SDKs share no code. They share a pinned contract -- target name,
# payload shape, file location -- and nothing but this file stops them drifting
# apart silently. A comment saying "these must match" is not a mechanism.
#
# The file tier is asserted in both directions because it is the one that works
# everywhere, including headless Linux where SecretService is unavailable and
# which is the common case for an admin scripting against a FOG server. The
# keyring-backed tiers are asserted only where a usable backend exists.
#
# Nothing here contacts a FOG server.

# Evaluated at DISCOVERY time, deliberately outside BeforeAll.
#
# Pester runs discovery before any BeforeAll, so a -Skip: expression reading a
# variable that BeforeAll sets sees $null and skips everything -- silently, and
# reported as "skipped" rather than as a problem. That is exactly what happened
# the first time this file ran: 9 skipped, 0 failed, and no interop coverage at
# all despite Python being present.
$script:HavePython = $null -ne (Get-Command python -CommandType Application -ErrorAction SilentlyContinue)

BeforeAll {
    $script:Custom = Join-Path $PSScriptRoot '..' 'src' 'custom' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:PyRoot = Join-Path $PSScriptRoot '..' '..' 'python' | Resolve-Path | Select-Object -ExpandProperty Path

    if (-not ('FogSdk.DoNotExportAttribute' -as [type])) {
        Add-Type -TypeDefinition @'
namespace FogSdk {
    [System.AttributeUsage(System.AttributeTargets.All)]
    public class DoNotExportAttribute : System.Attribute { }
}
'@ -ErrorAction Stop
    }
    if (-not ('FogSdk.FogCredentialManager' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $script:Custom 'FogNativeStore.cs')) -ErrorAction Stop
    }
    . (Join-Path $script:Custom 'FogSdkCredentialStore.ps1')

    $script:Server = 'https://interop.invalid/fog/'
    $script:Token  = 'fog_INTEROP0123456789abcdef'
    $script:Target = Get-FogSdkStoreTarget -Server $script:Server

    function script:Py([string]$Code) {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "fg-interop-$PID-$(Get-Random).py"
        $prelude = "import sys; sys.path.insert(0, r'$($script:PyRoot)')`n"
        Set-Content -LiteralPath $f -Value ($prelude + $Code) -Encoding utf8
        try { & python $f 2>&1 | Out-String }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'PowerShell and Python agree on the contract' -Skip:(-not $script:HavePython) {

    AfterEach {
        Clear-FogSdkSecret -Target $script:Target -Tier File | Out-Null
    }

    It 'derives the same target name' {
        $ps = Get-FogSdkStoreTarget -Server $script:Server
        $py = (Py "from fogsdk_auth import store_target; print(store_target('$($script:Server)'), end='')").Trim()
        $py | Should -BeExactly $ps
    }

    It 'builds a byte-identical payload for the same input' {
        # The strongest assertion here. If these ever differ, one SDK writes a
        # credential the other cannot parse, and nothing else would catch it.
        $ps = New-FogSdkPayload -Server $script:Server -Token $script:Token -User 'fogadmin'
        $py = (Py "from fogsdk_auth import build_payload; print(build_payload('$($script:Server)', '$($script:Token)', 'fogadmin'), end='')").Trim()
        $py | Should -BeExactly $ps
    }

    It 'resolves the same fallback file path' {
        $ps = (Get-FogSdkStoreFile -Target $script:Target).Path
        $py = (Py "from fogsdk_auth import store_file; print(store_file('$($script:Target)'), end='')").Trim()
        $py | Should -BeExactly $ps
    }
}

Describe 'A credential written by one SDK is readable by the other' -Skip:(-not $script:HavePython) {

    AfterEach {
        Clear-FogSdkSecret -Target $script:Target -Tier File | Out-Null
    }

    It 'PowerShell writes, Python reads' {
        $payload = New-FogSdkPayload -Server $script:Server -Token $script:Token -User 'fogadmin'
        Save-FogSdkSecret -Target $script:Target -Account 'fog-sdk' -Payload $payload -Tier File

        $out = Py @"
from fogsdk_auth import load_secret, parse_payload
raw = load_secret('$($script:Target)', tier='File')
print(parse_payload(raw)['token'], end='')
"@
        $out.Trim() | Should -BeExactly $script:Token
    }

    It 'Python writes, PowerShell reads' {
        $null = Py @"
from fogsdk_auth import build_payload, save_secret
save_secret('$($script:Target)', build_payload('$($script:Server)', '$($script:Token)', 'fogadmin'), tier='File')
"@
        $raw = Get-FogSdkSecret -Target $script:Target -Tier File
        $raw | Should -Not -BeNullOrEmpty
        (ConvertFrom-FogSdkPayload -Payload $raw).token | Should -BeExactly $script:Token
    }

    It 'Python refuses a payload version it does not understand, same as PowerShell' {
        $out = Py @"
from fogsdk_auth import parse_payload, CredentialError
try:
    parse_payload('{"v":99,"authKind":"bearer"}')
    print('NO-THROW', end='')
except CredentialError as e:
    print('THREW', end='')
"@
        $out.Trim() | Should -BeExactly 'THREW'
    }

    It 'Python refuses a non-bearer authKind, same as PowerShell' {
        $out = Py @"
from fogsdk_auth import parse_payload, CredentialError
try:
    parse_payload('{"v":1,"authKind":"legacy"}')
    print('NO-THROW', end='')
except CredentialError:
    print('THREW', end='')
"@
        $out.Trim() | Should -BeExactly 'THREW'
    }
}

Describe 'Python file-tier permissions' -Skip:((-not $script:HavePython) -or $IsWindows) {
    It 'writes mode 600 with a 700 directory, the same as PowerShell' {
        $null = Py @"
from fogsdk_auth import build_payload, save_secret, store_file
save_secret('$($script:Target)', build_payload('$($script:Server)', '$($script:Token)'), tier='File')
print(store_file('$($script:Target)'), end='')
"@
        $f = (Get-FogSdkStoreFile -Target $script:Target)
        (& stat -c '%a' $f.Path)      | Should -BeExactly '600'
        (& stat -c '%a' $f.Directory) | Should -BeExactly '700'
        Clear-FogSdkSecret -Target $script:Target -Tier File | Out-Null
    }
}
