# Credential-store tests.
#
# These exist because the module they replace had none. FogApi ships
# Set-FogServerSettingsFileSecurity with chmod/ACL logic that nothing asserts,
# so its defects -- an unchecked chmod, a never-permissioned parent directory,
# tokens under the roaming %APPDATA% -- survived for years without a failing
# test. Every claim this SDK makes about credential handling gets an assertion.
#
# Nothing here contacts a FOG server.

BeforeAll {
    $script:CsPath = Join-Path $PSScriptRoot '..' 'src' 'custom' 'FogNativeStore.cs' |
        Resolve-Path | Select-Object -ExpandProperty Path

    if (-not ('FogSdk.FogCredentialManager' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -Raw $script:CsPath) -ErrorAction Stop
    }

    $script:Target  = 'fog-sdk:pester.invalid'
    $script:Token   = 'fog_PESTER0123456789abcdef'
    $script:Payload = "{`"v`":1,`"server`":`"https://pester.invalid`",`"authKind`":`"bearer`",`"token`":`"$script:Token`"}"
}

Describe 'FogNativeStore.cs' {
    It 'compiles standalone via Add-Type' {
        # Not a tautology: the file must be loadable without the generated
        # assembly, so the store can be tested without a 12-minute build.
        'FogSdk.FogCredentialManager' -as [type] | Should -Not -BeNullOrEmpty
        'FogSdk.FogDpapiNg'           -as [type] | Should -Not -BeNullOrEmpty
    }

    It 'does not CALL the LSA private data functions' {
        # Microsoft: "Do not use the LSA private data functions for generic
        # data encryption and decryption." A future edit reaching for the
        # obvious prior art should fail here.
        #
        # Comments are stripped first, deliberately: the source names these
        # functions on purpose to record why they were rejected, and asserting
        # on the raw text would fail on the explanation rather than on any use.
        $code = (Get-Content $script:CsPath) -replace '//.*$', '' -join "`n"
        $code | Should -Not -Match 'Lsa[A-Za-z]*PrivateData'
        $code | Should -Not -Match 'LsaOpenPolicy'
        $code | Should -Not -Match 'ntsecapi'
    }

    It 'pins LOCAL_MACHINE persistence and never ENTERPRISE' {
        $src = Get-Content -Raw $script:CsPath
        $src | Should -Match 'CRED_PERSIST_LOCAL_MACHINE\s*=\s*2'
        $src | Should -Not -Match 'CRED_PERSIST_ENTERPRISE'
    }
}

Describe 'Windows Credential Manager tier' -Skip:(-not $IsWindows) {

    AfterEach {
        [FogSdk.FogCredentialManager]::Clear($script:Target) | Out-Null
    }

    It 'round-trips a payload exactly' {
        [FogSdk.FogCredentialManager]::Save($script:Target, 'pester', $script:Payload)
        [FogSdk.FogCredentialManager]::Load($script:Target) | Should -BeExactly $script:Payload
    }

    It 'returns null for a target that was never stored, rather than throwing' {
        [FogSdk.FogCredentialManager]::Load('fog-sdk:never-stored.invalid') | Should -BeNullOrEmpty
    }

    It 'stores with local-machine persistence, not enterprise' {
        # Enterprise persistence roams the credential to the domain profile.
        # That is precisely the exposure this SDK exists to remove, and the
        # in-house estate shipped -Persist Enterprise before a migration
        # silently changed it with nothing recording the change. Assert it.
        [FogSdk.FogCredentialManager]::Save($script:Target, 'pester', $script:Payload)
        $listing = (& cmdkey /list:$script:Target 2>$null | Out-String)
        $listing | Should -Match 'Local machine persistence'
        $listing | Should -Not -Match 'Enterprise persistence'
    }

    It 'does not leave the token readable in the credential comment or alias' {
        [FogSdk.FogCredentialManager]::Save($script:Target, 'pester', $script:Payload)
        $listing = (& cmdkey /list:$script:Target 2>$null | Out-String)
        $listing | Should -Not -Match ([regex]::Escape($script:Token))
    }

    It 'clears, and reports False when there was nothing to clear' {
        [FogSdk.FogCredentialManager]::Save($script:Target, 'pester', $script:Payload)
        [FogSdk.FogCredentialManager]::Clear($script:Target) | Should -BeTrue
        [FogSdk.FogCredentialManager]::Load($script:Target)  | Should -BeNullOrEmpty
        [FogSdk.FogCredentialManager]::Clear($script:Target) | Should -BeFalse
    }

    It 'refuses a secret larger than the credential blob limit' {
        $tooBig = 'x' * 3000
        { [FogSdk.FogCredentialManager]::Save($script:Target, 'pester', $tooBig) } |
            Should -Throw -ExpectedMessage '*at most 2560*'
    }
}
