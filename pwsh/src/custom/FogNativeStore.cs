// Windows native credential interop for fog-sdk.
//
// P/Invoke declarations transcribed from Microsoft's published API
// documentation. These are factual restatements of a documented ABI, written
// from the docs rather than adapted from any third-party source:
//
//   CredReadW / CredWriteW / CredDeleteW / CredFree / CREDENTIALW
//     https://learn.microsoft.com/windows/win32/api/wincred/
//   NCryptProtectSecret / NCryptUnprotectSecret / NCryptCreateProtectionDescriptor
//     https://learn.microsoft.com/windows/win32/api/ncryptprotect/
//
// Two tiers live here and nothing else. Tier selection, the macOS/Linux
// keyring shell-outs and the file fallback are PowerShell, where they can be
// tested without a compile.
//
// Deliberately NOT here: LsaStorePrivateData. Microsoft's own documentation
// says "Do not use the LSA private data functions for generic data encryption
// and decryption", the stored data is "not absolutely protected" with a DACL
// admitting every local administrator, and reading it requires elevation.
// NCryptProtectSecret with a SID descriptor covers the service-account case
// properly. See spec/generators/README.md.

using System;
using System.Runtime.InteropServices;

namespace FogSdk
{
    /// <summary>Windows Credential Manager, generic credentials.</summary>
    public static class FogCredentialManager
    {
        private const uint CRED_TYPE_GENERIC = 1;

        // LOCAL_MACHINE (2), never ENTERPRISE (3). Enterprise roams the
        // credential to the domain profile, which is the exposure this SDK
        // exists to avoid -- FogApi already leaks tokens that way by storing
        // them under the roaming %APPDATA%.
        private const uint CRED_PERSIST_LOCAL_MACHINE = 2;

        // CRED_MAX_CREDENTIAL_BLOB_SIZE. A fog_ token is 132 chars, so the
        // versioned JSON payload has room, but a caller could still exceed it.
        private const int CRED_MAX_CREDENTIAL_BLOB_SIZE = 2560;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIALW
        {
            public uint Flags;
            public uint Type;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
            [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public uint CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint Persist;
            public uint AttributeCount;
            public IntPtr Attributes;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
            [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIALW credential, uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, uint type, uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        private static extern void CredFree(IntPtr buffer);

        public static void Save(string target, string userName, string secret)
        {
            if (string.IsNullOrEmpty(target)) throw new ArgumentNullException("target");
            if (secret == null) throw new ArgumentNullException("secret");

            byte[] blob = System.Text.Encoding.UTF8.GetBytes(secret);
            if (blob.Length > CRED_MAX_CREDENTIAL_BLOB_SIZE)
            {
                throw new ArgumentException(string.Format(
                    "Secret is {0} bytes; Windows Credential Manager accepts at most {1}.",
                    blob.Length, CRED_MAX_CREDENTIAL_BLOB_SIZE));
            }

            IntPtr blobPtr = Marshal.AllocHGlobal(blob.Length);
            try
            {
                Marshal.Copy(blob, 0, blobPtr, blob.Length);
                var cred = new CREDENTIALW
                {
                    Type = CRED_TYPE_GENERIC,
                    TargetName = target,
                    UserName = string.IsNullOrEmpty(userName) ? "fog-sdk" : userName,
                    CredentialBlob = blobPtr,
                    CredentialBlobSize = (uint)blob.Length,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                };
                if (!CredWrite(ref cred, 0))
                {
                    throw new InvalidOperationException("CredWrite failed: " +
                        new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message);
                }
            }
            finally
            {
                // Zero the unmanaged copy before releasing it.
                for (int i = 0; i < blob.Length; i++) Marshal.WriteByte(blobPtr, i, 0);
                Marshal.FreeHGlobal(blobPtr);
                Array.Clear(blob, 0, blob.Length);
            }
        }

        /// <summary>Returns null when no credential is stored, rather than throwing.</summary>
        public static string Load(string target)
        {
            IntPtr raw;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out raw)) return null;
            try
            {
                var cred = (CREDENTIALW)Marshal.PtrToStructure(raw, typeof(CREDENTIALW));
                if (cred.CredentialBlobSize == 0) return string.Empty;
                var blob = new byte[cred.CredentialBlobSize];
                Marshal.Copy(cred.CredentialBlob, blob, 0, (int)cred.CredentialBlobSize);
                try { return System.Text.Encoding.UTF8.GetString(blob); }
                finally { Array.Clear(blob, 0, blob.Length); }
            }
            finally { CredFree(raw); }
        }

        /// <summary>True if something was removed; false if there was nothing to remove.</summary>
        public static bool Clear(string target)
        {
            return CredDelete(target, CRED_TYPE_GENERIC, 0);
        }
    }

    /// <summary>
    /// DPAPI-NG. Encrypts to a protection descriptor such as "SID=S-1-5-21-...",
    /// so a named service account can decrypt and nobody else can. This is for
    /// the case where you cannot run Connect-FgServer as the task account
    /// itself; ordinary scheduled tasks should use Credential Manager, which
    /// already binds the secret to the account that saved it.
    /// </summary>
    public static class FogDpapiNg
    {
        private const uint NCRYPT_SILENT_FLAG = 0x00000040;

        [DllImport("ncrypt.dll", CharSet = CharSet.Unicode)]
        private static extern int NCryptCreateProtectionDescriptor(
            string descriptorString, uint flags, out IntPtr descriptor);

        [DllImport("ncrypt.dll")]
        private static extern int NCryptCloseProtectionDescriptor(IntPtr descriptor);

        [DllImport("ncrypt.dll")]
        private static extern int NCryptProtectSecret(
            IntPtr descriptor, uint flags, byte[] data, uint dataLen,
            IntPtr memPara, IntPtr wnd, out IntPtr protectedBlob, out uint protectedLen);

        [DllImport("ncrypt.dll")]
        private static extern int NCryptUnprotectSecret(
            IntPtr descriptor, uint flags, byte[] protectedBlob, uint protectedLen,
            IntPtr memPara, IntPtr wnd, out IntPtr data, out uint dataLen);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr mem);

        public static byte[] Protect(string descriptorString, string secret)
        {
            IntPtr descriptor;
            int hr = NCryptCreateProtectionDescriptor(descriptorString, 0, out descriptor);
            if (hr != 0)
            {
                throw new InvalidOperationException("NCryptCreateProtectionDescriptor failed (0x" +
                    hr.ToString("x8") + ") for descriptor: " + descriptorString);
            }
            IntPtr blob = IntPtr.Zero;
            byte[] data = System.Text.Encoding.UTF8.GetBytes(secret);
            try
            {
                uint len;
                hr = NCryptProtectSecret(descriptor, NCRYPT_SILENT_FLAG, data, (uint)data.Length,
                                         IntPtr.Zero, IntPtr.Zero, out blob, out len);
                if (hr != 0)
                {
                    throw new InvalidOperationException("NCryptProtectSecret failed (0x" + hr.ToString("x8") + ")");
                }
                var result = new byte[len];
                Marshal.Copy(blob, result, 0, (int)len);
                return result;
            }
            finally
            {
                Array.Clear(data, 0, data.Length);
                if (blob != IntPtr.Zero) LocalFree(blob);
                NCryptCloseProtectionDescriptor(descriptor);
            }
        }

        public static string Unprotect(byte[] protectedBlob)
        {
            IntPtr data = IntPtr.Zero;
            try
            {
                uint len;
                int hr = NCryptUnprotectSecret(IntPtr.Zero, NCRYPT_SILENT_FLAG,
                                               protectedBlob, (uint)protectedBlob.Length,
                                               IntPtr.Zero, IntPtr.Zero, out data, out len);
                if (hr != 0)
                {
                    throw new InvalidOperationException("NCryptUnprotectSecret failed (0x" + hr.ToString("x8") + ")");
                }
                var buf = new byte[len];
                Marshal.Copy(data, buf, 0, (int)len);
                try { return System.Text.Encoding.UTF8.GetString(buf); }
                finally { Array.Clear(buf, 0, buf.Length); }
            }
            finally { if (data != IntPtr.Zero) LocalFree(data); }
        }
    }
}
