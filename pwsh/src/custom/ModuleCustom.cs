// The one place fog-sdk authenticates.
//
// AutoRest cannot emit a credential step for FOG: it knows three security
// schemes, all Azure's, and does not support AND-ed requirements. So Module.cs
// builds a pipeline with no auth and a freshly generated module 401s on every
// call.
//
// Module.cs declares AfterCreatePipeline as a partial method for exactly this.
// It receives the pipeline by reference on EVERY cmdlet invocation, so one
// SendAsyncStep prepended here carries auth for the whole module without
// appearing in any cmdlet's parameters.
//
// Chosen over $PSDefaultParameterValues['*:HttpPipelinePrepend'], which works
// but is session-global state a user can clear, leaks the mechanism into the
// public surface, and misses the exported cmdlets that have no pipeline
// parameter at all.
//
// Verified on a probe against the pinned generator before being written here:
// the hook fires on an ordinary cmdlet call with no -HttpPipelinePrepend
// argument, and the step can rewrite the request host. See
// spec/generators/README.md.

using System;

namespace FogSdk
{
    public partial class Module
    {
        partial void AfterCreatePipeline(
            System.Management.Automation.InvocationInfo invocationInfo,
            ref FogSdk.Runtime.HttpPipeline pipeline)
        {
            pipeline.Prepend(new FogSdk.Runtime.SendAsyncStep(
                (request, callback, next) =>
                {
                    if (!FogConnection.IsConnected)
                    {
                        // Fail here rather than let the request go to the host
                        // baked in from servers[0].url, which belongs to
                        // whichever server the document was generated from and
                        // is never the caller's. A 401 or a DNS failure
                        // against a stranger's hostname is a far worse error
                        // message than this one.
                        throw new InvalidOperationException(
                            "Not connected to a FOG server. Run Connect-FgServer first.");
                    }

                    // The base URL is compiled in at 989 call sites and there
                    // is no -BaseUri to override it. Rewriting the host here is
                    // what makes the package server-agnostic, and why
                    // generating from a live server is an inspection tool
                    // rather than a release path.
                    var server = FogConnection.Server;
                    var b = new UriBuilder(request.RequestUri)
                    {
                        Scheme = server.Scheme,
                        Host = server.Host,
                        Port = server.IsDefaultPort ? -1 : server.Port,
                    };
                    request.RequestUri = b.Uri;

                    // Bearer goes on the wire RAW. The legacy fog-api-token and
                    // fog-user-token headers are base64; bearer is not, and a
                    // server-side test pins that distinction because hex is
                    // itself valid base64 and the two would otherwise be
                    // indistinguishable.
                    //
                    // Bearer also short-circuits server-side: once presented it
                    // decides the request and the legacy headers are never
                    // consulted. So nothing else is added here -- sending both
                    // would be dead weight that only widens exposure.
                    FogConnection.UseToken(token =>
                        request.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token));

                    return next.SendAsync(request, callback);
                }));
        }
    }
}
