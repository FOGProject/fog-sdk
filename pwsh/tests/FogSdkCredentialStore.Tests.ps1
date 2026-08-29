# Storage tier and payload tests.
#
# The file-fallback assertions here are the ones FogApi never had. Its
# Set-FogServerSettingsFileSecurity has chmod/ACL logic that nothing tests, so
# an unchecked chmod and a never-permissioned parent directory survived for
# years. Each of those defects has a test below that fails if reintroduced.
#
# Nothing here contacts a FOG server.

BeforeAll {
    $script:StorePs1 = Join-Path $PSScriptRoot '..' 'src' 'custom' 'FogSdkCredentialStore.ps1' |
        Resolve-Path | Select-Object -ExpandProperty Path
    $script:CsPath = Join-Path $PSScriptRoot '..' 'src' 'custom' 'FogNativeStore.cs' |
        Resolve-Path | Select-Object -ExpandProperty Path

    if (-not ('FogSdk.FogCredentialManager' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -Raw $script:CsPath) -ErrorAction Stop
    }

    # The DoNotExport attribute is supplied by the generated assembly at build
    # time. Standalone, define a stand-in so the file dot-sources under test.
    if (-not ('FogSdk.DoNotExportAttribute' -as [type])) {
        Add-Type -TypeDefinition @'
namespace FogSdk {
    [System.AttributeUsage(System.AttributeTargets.All)]
    public class DoNotExportAttribute : System.Attribute { }
}
'@ -ErrorAction Stop
    }

    . $script:StorePs1

    $script:Server = 'https://pester.invalid'
    $script:Token  = 'fog_PESTER0123456789abcdef'
    $script:Target = Get-FogSdkStoreTarget -Server $script:Server
}

Describe 'Target naming (the cross-language contract)' {
    It 'derives the target from a URL' {
        Get-FogSdkStoreTarget -Server 'https://fog.example.org/fog/' | Should -BeExactly 'fog-sdk:fog.example.org'
    }
    It 'accepts a bare hostname too' {
        Get-FogSdkStoreTarget -Server 'fog.example.org' | Should -BeExactly 'fog-sdk:fog.example.org'
    }
    It 'lower-cases the host so two spellings do not make two entries' {
        Get-FogSdkStoreTarget -Server 'https://FOG.Example.ORG' | Should -BeExactly 'fog-sdk:fog.example.org'
    }
}

Describe 'Payload' {
    It 'is version 1 and bearer' {
        $p = New-FogSdkPayload -Server $script:Server -Token $script:Token
        $o = $p | ConvertFrom-Json
        $o.v        | Should -Be 1
        $o.authKind | Should -BeExactly 'bearer'
        $o.token    | Should -BeExactly $script:Token
        $o.server   | Should -BeExactly $script:Server
    }

    It 'round-trips through ConvertFrom-FogSdkPayload' {
        $p = New-FogSdkPayload -Server $script:Server -Token $script:Token -User 'fogadmin'
        $o = ConvertFrom-FogSdkPayload -Payload $p
        $o.token | Should -BeExactly $script:Token
        $o.user  | Should -BeExactly 'fogadmin'
    }

    It 'refuses a payload version it does not understand' {
        { ConvertFrom-FogSdkPayload -Payload '{"v":99,"authKind":"bearer"}' } |
            Should -Throw -ExpectedMessage '*Unsupported credential payload version*'
    }

    It 'refuses a non-bearer authKind, since this SDK is bearer-only' {
        { ConvertFrom-FogSdkPayload -Payload '{"v":1,"authKind":"legacy"}' } |
            Should -Throw -ExpectedMessage '*bearer-only*'
    }

    It 'emits compact JSON, so the Windows blob limit is not wasted on whitespace' {
        (New-FogSdkPayload -Server $script:Server -Token $script:Token) | Should -Not -Match '\n'
    }
}

Describe 'Tier selection' {
    It 'reports a tier and a scope, never just a tier' {
        $t = Get-FogSdkStoreTier
        $t.Tier  | Should -Not -BeNullOrEmpty
        $t.Scope | Should -Not -BeNullOrEmpty
    }

    It 'selects Credential Manager on Windows when the interop is loaded' -Skip:(-not $IsWindows) {
        (Get-FogSdkStoreTier).Tier | Should -BeExactly 'CredentialManager'
    }

    It 'explains itself whenever it falls back to the file tier' {
        $t = Get-FogSdkStoreTier
        if ($t.Tier -eq 'File') { $t.Note | Should -Not -BeNullOrEmpty }
        else                    { $t.Tier | Should -Not -BeExactly 'File' }
    }
}

Describe 'File fallback tier' {

    AfterEach {
        Clear-FogSdkSecret -Target $script:Target -Tier File | Out-Null
    }

    It 'never places the store under the roaming profile' -Skip:(-not $IsWindows) {
        # FogApi uses $env:APPDATA, which replicates the plaintext token to the
        # domain profile share and to every machine the user signs into. That
        # is the single worst defect this SDK exists to fix.
        $f = Get-FogSdkStoreFile -Target $script:Target
        $f.Directory | Should -Not -Match '(?i)\\Roaming\\'
        $f.Directory | Should -Match '(?i)\\Local\\'
    }

    It 'round-trips a payload' {
        $payload = New-FogSdkPayload -Server $script:Server -Token $script:Token
        Save-FogSdkSecret -Target $script:Target -Account 'pester' -Payload $payload -Tier File
        Get-FogSdkSecret -Target $script:Target -Tier File | Should -BeExactly $payload
    }

    It 'returns null when nothing is stored' {
        Get-FogSdkSecret -Target 'fog-sdk:never-stored.invalid' -Tier File | Should -BeNullOrEmpty
    }

    It 'writes UTF-8 with no BOM' {
        # FogApi writes -Encoding oem, which is neither UTF-8 nor safe for
        # non-ASCII. A BOM would also break a byte-comparing Python reader.
        $payload = New-FogSdkPayload -Server $script:Server -Token $script:Token
        Save-FogSdkSecret -Target $script:Target -Account 'pester' -Payload $payload -Tier File
        $f = Get-FogSdkStoreFile -Target $script:Target
        $bytes = [System.IO.File]::ReadAllBytes($f.Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
    }

    It 'permissions the directory as well as the file' -Skip:$IsWindows {
        $payload = New-FogSdkPayload -Server $script:Server -Token $script:Token
        Save-FogSdkSecret -Target $script:Target -Account 'pester' -Payload $payload -Tier File
        $f = Get-FogSdkStoreFile -Target $script:Target
        (& stat -c '%a' $f.Path)      | Should -BeExactly '600'
        (& stat -c '%a' $f.Directory) | Should -BeExactly '700'
    }

    It 'grants only the current user on Windows, with inheritance broken' -Skip:(-not $IsWindows) {
        $payload = New-FogSdkPayload -Server $script:Server -Token $script:Token
        Save-FogSdkSecret -Target $script:Target -Account 'pester' -Payload $payload -Tier File
        $f = Get-FogSdkStoreFile -Target $script:Target
        $acl = Get-Acl -LiteralPath $f.Path
        $acl.AreAccessRulesProtected | Should -BeTrue
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        @($acl.Access).Count | Should -Be 1
        @($acl.Access)[0].IdentityReference.Value | Should -BeExactly $me
    }

    It 'clears, and reports False when there was nothing to clear' {
        $payload = New-FogSdkPayload -Server $script:Server -Token $script:Token
        Save-FogSdkSecret -Target $script:Target -Account 'pester' -Payload $payload -Tier File
        Clear-FogSdkSecret -Target $script:Target -Tier File | Should -BeTrue
        Get-FogSdkSecret   -Target $script:Target -Tier File | Should -BeNullOrEmpty
        Clear-FogSdkSecret -Target $script:Target -Tier File | Should -BeFalse
    }
}
