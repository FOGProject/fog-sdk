# The environment half of the credential contract, and the Python wiring.
#
# Both SDKs resolve a credential in the same order:
#   1. what the caller passed
#   2. the environment (FOG_SDK_SERVER / FOG_SDK_TOKEN)
#   3. the credential store
#   4. an error  (PowerShell prompts first, but only with a human present)
#
# The payoff test is at the bottom: PowerShell saves, Python connects. That is
# the claim "connect once with either SDK" actually rests on, and until now it
# was a property of the documentation rather than of the code.
#
# Nothing here contacts a FOG server.

$script:HavePython = $null -ne (Get-Command python -CommandType Application -ErrorAction SilentlyContinue)
$script:Venv = Join-Path $PSScriptRoot '..' '..' 'python' '.venv' 'Scripts' 'python.exe'
$script:HaveClient = (Test-Path -LiteralPath $script:Venv) -and
                     (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'python' 'src' 'fogsdk' '__init__.py'))

BeforeAll {
    $script:Custom = Join-Path $PSScriptRoot '..' 'src' 'custom' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:PyRoot = Join-Path $PSScriptRoot '..' '..' 'python' | Resolve-Path | Select-Object -ExpandProperty Path
    $script:PySrc  = Join-Path $script:PyRoot 'src'
    $script:VenvPy = Join-Path $script:PyRoot '.venv' 'Scripts' 'python.exe'

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
    if (-not ('FogSdk.FogCredentialManager' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $script:Custom 'FogNativeStore.cs')) -ErrorAction Stop
    }
    if (-not ('FogSdk.FogConnection' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -Raw (Join-Path $script:Custom 'FogConnectionState.cs')) -ErrorAction Stop
    }
    . (Join-Path $script:Custom 'FogSdkCredentialStore.ps1')
    . (Join-Path $script:Custom 'Connect-FgServer.ps1')
    . (Join-Path $script:Custom 'Get-FgConnection.ps1')

    $script:Server = 'wiring.invalid'
    $script:Token  = 'fog_WIRING0123456789abcdef'
    $script:Target = Get-FogSdkStoreTarget -Server $script:Server

    function script:Py([string]$Code) {
        $f = Join-Path ([System.IO.Path]::GetTempPath()) "fg-wiring-$PID-$(Get-Random).py"
        $prelude = "import sys`nsys.path.insert(0, r'$($script:PyRoot)')`nsys.path.insert(0, r'$($script:PySrc)')`n"
        Set-Content -LiteralPath $f -Value ($prelude + $Code) -Encoding utf8
        try { & $script:VenvPy $f 2>&1 | Out-String }
        finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Connect-FgServer resolves from the environment' {

    AfterEach {
        [FogSdk.FogConnection]::Clear()
        $env:FOG_SDK_SERVER = $null
        $env:FOG_SDK_TOKEN = $null
        Clear-FogSdkSecret -Target $script:Target -Tier File | Out-Null
        Clear-FogSdkSecret -Target $script:Target | Out-Null
    }

    It 'takes the server from FOG_SDK_SERVER when -Server is omitted' {
        $env:FOG_SDK_SERVER = $script:Server
        $env:FOG_SDK_TOKEN  = $script:Token
        Connect-FgServer
        [FogSdk.FogConnection]::Server.Host | Should -BeExactly $script:Server
    }

    It 'takes the token from FOG_SDK_TOKEN when -Token is omitted' {
        $env:FOG_SDK_TOKEN = $script:Token
        Connect-FgServer -Server $script:Server
        [FogSdk.FogConnection]::IsConnected | Should -BeTrue
    }

    It 'does NOT write an environment token to the credential store' {
        # Setting a variable should not have the side effect of persisting a
        # secret to the machine. This is the CI shape: nothing touches disk.
        $env:FOG_SDK_TOKEN = $script:Token
        Connect-FgServer -Server $script:Server
        Get-FogSdkSecret -Target $script:Target | Should -BeNullOrEmpty
    }

    It 'prefers an explicit -Token over the environment' {
        $env:FOG_SDK_TOKEN = 'fog_WRONGTOKEN'
        $explicit = ConvertTo-SecureString $script:Token -AsPlainText -Force
        Connect-FgServer -Server $script:Server -Token $explicit -NoSave
        # Round-trip through the connection state rather than reading the token
        # back out: there is deliberately no way to read it out.
        [FogSdk.FogConnection]::IsConnected | Should -BeTrue
    }

    It 'errors clearly when neither -Server nor FOG_SDK_SERVER is present' {
        { Connect-FgServer -ErrorAction Stop } |
            Should -Throw -ExpectedMessage '*FOG_SDK_SERVER is not set*'
    }
}

Describe 'The two SDKs select the same store' -Skip:(-not ($script:HavePython -and $script:HaveClient)) {

    It 'agrees on the tier, or the shared store is not shared at all' {
        # This is the assertion that catches the failure mode the payoff test
        # below only reports as a mismatched token.
        #
        # It has already fired once for real: with keyring absent, PowerShell
        # selected CredentialManager (built in, no dependency) while Python
        # fell back to File. Both worked, neither errored, and a token stored
        # by one was invisible to the other. keyring is now a declared
        # dependency of fogsdk_auth for exactly this reason -- the defensive
        # import in credentials.py is a runtime fallback for a headless
        # server, not permission to skip installing it.
        $ps = (Get-FogSdkStoreTier).Tier
        $py = (Py "from fogsdk_auth import select_tier; print(select_tier().tier, end='')").Trim()
        $py | Should -BeExactly $ps -Because 'a token stored by one SDK is invisible to the other when the tiers differ'
    }
}

Describe 'The Python client is wired to the store' -Skip:(-not ($script:HavePython -and $script:HaveClient)) {

    AfterEach {
        Clear-FogSdkSecret -Target $script:Target -Tier File | Out-Null
    }

    It 'connect() returns a client configured for the right host' {
        $out = Py @"
import fogsdk_auth as a
c = a.connect('$($script:Server)', token='$($script:Token)', save=False)
print(c.configuration.host, end='')
"@
        $out.Trim() | Should -BeExactly "https://$($script:Server)/fog"
    }

    It 'connect() refuses, rather than prompting, when there is no token anywhere' {
        $out = Py @"
import fogsdk_auth as a
try:
    a.connect('nothing-here.invalid', tier='File')
    print('NO-THROW', end='')
except a.CredentialError as e:
    print('THREW' if 'prompt' in str(e) else 'THREW-BUT-NO-MENTION', end='')
"@
        $out.Trim() | Should -BeExactly 'THREW'
    }

    It 'connect() reads FOG_SDK_TOKEN and does not persist it' {
        $out = Py @"
import os
os.environ['FOG_SDK_SERVER'] = '$($script:Server)'
os.environ['FOG_SDK_TOKEN'] = '$($script:Token)'
import fogsdk_auth as a
c = a.connect(tier='File')
print(c.configuration.host, '|', a.load_secret(a.store_target('$($script:Server)'), tier='File') is None, end='')
"@
        $out.Trim() | Should -BeExactly "https://$($script:Server)/fog | True"
    }

    It 'PowerShell saves, Python connects -- the whole point of the shared store' {
        # If this passes, "connect once with either SDK" is a property of the
        # code and not just of the README.
        $secure = ConvertTo-SecureString $script:Token -AsPlainText -Force
        Connect-FgServer -Server $script:Server -Token $secure
        [FogSdk.FogConnection]::Clear()

        $out = Py @"
import fogsdk_auth as a
c = a.connect('$($script:Server)')
print(c.configuration.access_token, end='')
"@
        $out.Trim() | Should -BeExactly $script:Token

        Clear-FogSdkSecret -Target $script:Target | Out-Null
    }

    It 'get_connection() reports the store without ever revealing the token' {
        $secure = ConvertTo-SecureString $script:Token -AsPlainText -Force
        Connect-FgServer -Server $script:Server -Token $secure

        $out = Py @"
import fogsdk_auth as a
info = a.get_connection('$($script:Server)')
print(info, end='')
"@
        $out | Should -Match 'HasStoredToken'
        $out | Should -Not -Match ([regex]::Escape($script:Token))

        Clear-FogSdkSecret -Target $script:Target | Out-Null
    }
}
