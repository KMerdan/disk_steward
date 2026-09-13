# RESEARCH-401 Local Observations

Captured 2026-09-12 on the development host.

```text
$ security find-identity -v -p codesigning
     0 valid identities found

$ systemextensionsctl list
systemextensionsctl: list command failed: The operation couldn’t be completed. (OSSystemExtensionErrorDomain error 1.)

$ xcrun --sdk macosx --show-sdk-path
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.2.sdk
```

SDK inspection found:

```text
usr/include/EndpointSecurity/EndpointSecurity.h
usr/lib/libEndpointSecurity.tbd
usr/lib/libEndpointSecuritySystem.tbd
```

Interpretation: API compilation inputs are installed. Signing, entitlement approval, installed extension state, activation, Full Disk Access, live event delivery, notarization, and distribution are not demonstrated by these observations.
