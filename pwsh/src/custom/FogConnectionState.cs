// Session connection state for fog-sdk.
//
// Holds the server and the bearer token for the life of the PowerShell
// session. Connect-FgServer writes it, the pipeline step in ModuleCustom.cs
// reads it, and Disconnect-FgServer clears it.
//
// The token is kept as a SecureString and revealed only for the moment a
// request is being built, then zeroed. That is not a strong guarantee -- a
// SecureString is not encrypted on non-Windows platforms and a determined
// local attacker can read process memory anywhere -- but it keeps the token
// out of variables that outlive the call, out of the pipeline, and out of
// crash dumps taken between requests.
//
// Deliberately NOT a PowerShell $script: variable: the pipeline step is C#
// running inside the private assembly and cannot see PowerShell module scope.

using System;
using System.Runtime.InteropServices;
using System.Security;

namespace FogSdk
{
    public static class FogConnection
    {
        private static readonly object _gate = new object();
        private static SecureString _token;
        private static Uri _server;
        private static string _user;
        private static string _tier;

        public static bool IsConnected
        {
            get { lock (_gate) { return _token != null && _server != null; } }
        }

        public static Uri Server
        {
            get { lock (_gate) { return _server; } }
        }

        public static string User
        {
            get { lock (_gate) { return _user; } }
        }

        /// <summary>Which credential store the token came from, for Get-FgConnection.</summary>
        public static string Tier
        {
            get { lock (_gate) { return _tier; } }
            set { lock (_gate) { _tier = value; } }
        }

        public static void Set(Uri server, SecureString token, string user)
        {
            if (server == null) throw new ArgumentNullException("server");
            if (token == null) throw new ArgumentNullException("token");
            lock (_gate)
            {
                if (_token != null) _token.Dispose();
                _token = token.Copy();
                _token.MakeReadOnly();
                _server = server;
                _user = user;
            }
        }

        public static void Clear()
        {
            lock (_gate)
            {
                if (_token != null) { _token.Dispose(); _token = null; }
                _server = null;
                _user = null;
                _tier = null;
            }
        }

        /// <summary>
        /// Reveal the token for the duration of one request. The plaintext is
        /// copied into unmanaged memory, handed to the callback, and zeroed
        /// immediately afterwards whether or not the callback threw.
        /// </summary>
        internal static void UseToken(Action<string> use)
        {
            SecureString copy;
            lock (_gate)
            {
                if (_token == null) throw new InvalidOperationException("Not connected.");
                copy = _token;
            }
            IntPtr p = IntPtr.Zero;
            try
            {
                p = Marshal.SecureStringToGlobalAllocUnicode(copy);
                use(Marshal.PtrToStringUni(p));
            }
            finally
            {
                if (p != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(p);
            }
        }
    }
}
