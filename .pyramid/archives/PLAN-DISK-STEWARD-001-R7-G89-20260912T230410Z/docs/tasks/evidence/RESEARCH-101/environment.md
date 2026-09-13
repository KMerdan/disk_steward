# RESEARCH-101 Environment Evidence

Captured: 2026-09-12, Asia/Tokyo  
Repository: `/Users/merdankiji/localGit/disk_steward`

## Swift

Command: `swift --version`

```text
swift-driver version: 1.127.15 Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)
Target: arm64-apple-macosx15.0
```

## Xcode

Command: `xcodebuild -version`

```text
Xcode 26.3
Build version 17C529
```

## macOS SDK path

Command: `xcrun --show-sdk-path`

```text
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

Command: `xcodebuild -showsdks`

Relevant result:

```text
macOS SDKs:
    macOS 26.2 -sdk macosx26.2
```

The command exited successfully but the automated shell emitted warnings about starting an FSEvents stream and resolving `DARWIN_USER_CACHE_DIR`. The project build task must determine whether these warnings recur or affect build behavior.

## Host

Commands: `sw_vers` and `uname -m`

```text
ProductName: macOS
ProductVersion: 15.6.1
BuildVersion: 24G90
Architecture: arm64
```

## Code-signing identities

Command: `security find-identity -v -p codesigning`

```text
0 valid identities found
```

Interpretation: local development can begin, but this is positive evidence that Developer ID distribution and production system-extension signing are not currently demonstrable on this machine. Later gates must preserve that limitation until external credentials are actually available.

## Authoritative capability references

- Apple `SMAppService`: <https://developer.apple.com/documentation/servicemanagement/smappservice>
- Apple Endpoint Security: <https://developer.apple.com/documentation/EndpointSecurity>
- Apple System Extensions entitlement boundary: <https://developer.apple.com/system-extensions/>
- Official MCP Swift SDK: <https://github.com/modelcontextprotocol/swift-sdk>

These sources establish API and packaging capability, not entitlement approval or a successful product build.
