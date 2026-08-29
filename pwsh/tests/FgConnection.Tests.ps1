# Connect-FgServer / Disconnect-FgServer / Get-FgConnection.
#
# Dot-sourced rather than imported from a built module, so the suite runs in
# seconds instead of after a 12-minute generate-and-compile. The generated
# attributes the cmdlets carry are stubbed below.
#
# Nothing here contacts a FOG server.

BeforeAll {
    $script:Custom = Join-Path $PSScriptRoot '..' 'src' 'custom' | Resolve-Path | Select-Object -ExpandProperty Path

    if (-not ('FogSdk.FogCredentialManager' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $script:Custom 'FogNativeStore.cs')) -ErrorAction Stop
    }
    if (-not ('FogSdk.FogConnection' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $script:Custom 'FogConnectionState.cs')) -ErrorAction Stop
    }
    # Attributes the generated assembly supplies at build time.
    if (-not ('FogSdk.DoNotExportAttribute' -as [type])) {
        Add-Type -TypeDefinition @'
namespace FogSdk {
    [System.AttributeUsage(System.AttributeTargets.All)]
    public class DoNotExportAttribute : System.Attribute { }
    [System.AttributeUsage(System.AttributeTargets.All)]
    public class DescriptionAttribute : System.Attribute {
        public DescriptionAttribute(string d) { Description = d; }
        public string Description { get; set; }
    }
}
'@ -ErrorAction Stop
    }

    . (Join-Path $script:Custom 'FogSdkCredentialStore.ps1')
    . (Join-Path $script:Custom 'Connect-FgServer.ps1')
    . (Join-Path $script:Custom 'Disconnect-FgServer.ps1')
    . (Join-Path $script:Custom 'Get-FgConnection.ps1')

    $script:Server = 'fgtest.invalid'
    $script:Token  = 'fog_FGTEST0123456789abcdef'
    $script:Secure = ConvertTo-SecureString $script:Token -AsPlainText -Force
}

AfterAll {
    [FogSdk.FogConnection]::Clear()
    $t = Get-FogSdkStoreTarget -Server $script:Server
    Clear-FogSdkSecret -Target $t -Account 'fog-sdk' | Out-Null
}

Describe 'Connect-FgServer' {

    AfterEach {
        [FogSdk.FogConnection]::Clear()
        Clear-FogSdkSecret -Target (Get-FogSdkStoreTarget -Server $script:Server) -Account 'fog-sdk' | Out-Null
    }

    It 'connects and returns nothing by default' {
        $out = Connect-FgServer -Server $script:Server -Token $script:Secure -NoSave
        $out | Should -BeNullOrEmpty
        [FogSdk.FogConnection]::IsConnected | Should -BeTrue
    }

    It 'assumes https for a bare hostname' {
        Connect-FgServer -Server $script:Server -Token $script:Secure -NoSave
        [FogSdk.FogConnection]::Server.Scheme | Should -BeExactly 'https'
        [FogSdk.FogConnection]::Server.Host   | Should -BeExactly $script:Server
    }

    It 'honours an explicit scheme and port' {
        Connect-FgServer -Server 'http://fgtest.invalid:8080/fog/' -Token $script:Secure -NoSave
        [FogSdk.FogConnection]::Server.Scheme | Should -BeExactly 'http'
        [FogSdk.FogConnection]::Server.Port   | Should -Be 8080
    }

    It 'writes nothing to the store with -NoSave' {
        Connect-FgServer -Server $script:Server -Token $script:Secure -NoSave
        Get-FogSdkSecret -Target (Get-FogSdkStoreTarget -Server $script:Server) | Should -BeNullOrEmpty
    }

    It 'saves without -NoSave, and reconnects from the store afterwards' {
        Connect-FgServer -Server $script:Server -Token $script:Secure
        [FogSdk.FogConnection]::Clear()
        [FogSdk.FogConnection]::IsConnected | Should -BeFalse

        Connect-FgServer -Server $script:Server          # no -Token
        [FogSdk.FogConnection]::IsConnected | Should -BeTrue
    }

    It 'rejects a server with no hostname' {
        { Connect-FgServer -Server '///' -Token $script:Secure -NoSave } | Should -Throw
    }

    It 'never emits the token, even with -PassThru' {
        $c = Connect-FgServer -Server $script:Server -Token $script:Secure -NoSave -PassThru
        ($c | Format-List * | Out-String) | Should -Not -Match ([regex]::Escape($script:Token))
    }
}

Describe 'The non-interactive no-prompt guarantee' {

    It 'throws instead of prompting when nothing is stored and nobody is there' {
        # Run in a child pwsh with stdin closed, which is what a scheduled task
        # looks like. The timeout is the point: a regression here does not fail,
        # it HANGS -- a real outage in the in-house estate had a scheduled task
        # block on Get-Credential until Task Scheduler killed it at five
        # minutes. A test that can hang must be bounded, or it reproduces the
        # outage in CI.
        $script = @"
`$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition (Get-Content -Raw '$($script:Custom)\FogNativeStore.cs')
Add-Type -TypeDefinition (Get-Content -Raw '$($script:Custom)\FogConnectionState.cs')
Add-Type -TypeDefinition @'
namespace FogSdk {
    [System.AttributeUsage(System.AttributeTargets.All)]
    public class DoNotExportAttribute : System.Attribute { }
    [System.AttributeUsage(System.AttributeTargets.All)]
    public class DescriptionAttribute : System.Attribute {
        public DescriptionAttribute(string d) { Description = d; }
        public string Description { get; set; }
    }
}
'@
. '$($script:Custom)\FogSdkCredentialStore.ps1'
. '$($script:Custom)\Connect-FgServer.ps1'
. '$($script:Custom)\Get-FgConnection.ps1'
try { Connect-FgServer -Server 'nothing-stored-here.invalid' ; 'NO-THROW' }
catch { 'THREW: ' + `$_.Exception.Message.Split([char]10)[0] }
"@
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "fg-noprompt-$PID.ps1"
        Set-Content -LiteralPath $f -Value $script -Encoding utf8

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.Arguments = "-NoProfile -NonInteractive -File `"$f`""
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()
        $exited = $p.WaitForExit(30000)
        if (-not $exited) { $p.Kill($true) }
        $out = if ($exited) { $p.StandardOutput.ReadToEnd() } else { '' }
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue

        $exited | Should -BeTrue -Because 'a prompt in a non-interactive session hangs rather than fails'
        $out    | Should -Match 'THREW'
        $out    | Should -Match 'not interactive'
    }
}

Describe 'Get-FgConnection' {

    AfterEach { [FogSdk.FogConnection]::Clear() }

    It 'reports disconnected before any connect' {
        (Get-FgConnection).IsConnected | Should -BeFalse
    }

    It 'always reports a tier and a scope, connected or not' {
        $c = Get-FgConnection
        $c.Tier  | Should -Not -BeNullOrEmpty
        $c.Scope | Should -Not -BeNullOrEmpty
    }

    It 'has no property that could carry the token' {
        Connect-FgServer -Server $script:Server -Token $script:Secure -NoSave
        $names = (Get-FgConnection | Get-Member -MemberType NoteProperty).Name
        $names | Should -Not -Contain 'Token'
        $names | Should -Not -Contain 'Password'
        $names | Should -Not -Contain 'Secret'
    }

    It 'does not leak the token through -Debug or -Verbose either' {
        Connect-FgServer -Server $script:Server -Token $script:Secure -NoSave
        $text = (Get-FgConnection -Debug -Verbose 4>&1 5>&1 | Out-String)
        $text | Should -Not -Match ([regex]::Escape($script:Token))
    }
}

Describe 'Disconnect-FgServer' {

    AfterEach {
        [FogSdk.FogConnection]::Clear()
        Clear-FogSdkSecret -Target (Get-FogSdkStoreTarget -Server $script:Server) -Account 'fog-sdk' | Out-Null
    }

    It 'clears the session but leaves the stored credential alone' {
        Connect-FgServer -Server $script:Server -Token $script:Secure
        Disconnect-FgServer
        [FogSdk.FogConnection]::IsConnected | Should -BeFalse
        Get-FogSdkSecret -Target (Get-FogSdkStoreTarget -Server $script:Server) | Should -Not -BeNullOrEmpty
    }

    It 'removes the stored credential with -Forget, and warns that nothing was revoked' {
        Connect-FgServer -Server $script:Server -Token $script:Secure
        Disconnect-FgServer -Forget -WarningVariable w -WarningAction SilentlyContinue
        [FogSdk.FogConnection]::IsConnected | Should -BeFalse
        Get-FogSdkSecret -Target (Get-FogSdkStoreTarget -Server $script:Server) | Should -BeNullOrEmpty
        ($w -join ' ') | Should -Match 'still valid'
    }

    It 'refuses -Forget when disconnected and given no server to forget' {
        { Disconnect-FgServer -Forget -ErrorAction Stop } | Should -Throw -ExpectedMessage '*nothing to forget*'
    }
}
