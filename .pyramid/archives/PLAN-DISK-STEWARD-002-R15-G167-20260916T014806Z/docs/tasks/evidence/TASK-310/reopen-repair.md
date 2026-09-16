# TASK-310 reopen repair

RISK-320 found that the first verifier revision did not explicitly bind the
artifact to the product identifiers. TASK-310 was reopened rather than allowing
the earlier audit to stand.

The repaired verifier now requires:

- application Info.plist identifier `com.marudankiji.disksteward`;
- application code-signing identifier `com.marudankiji.disksteward`;
- nested helper code-signing identifier `com.marudankiji.disksteward.mcp`.

Matching uses an exact complete `codesign -dvvv` detail line, so identifiers
with valid-looking prefixes or suffixes cannot pass. The credential-free
archive rehearsal passed again after the repair and its unsigned archive was
still rejected.

A subsequent RISK-320 test also found that the app-group check initially bound
only the value. The second repair parses the decoded entitlement plist lines
and requires exactly one top-level key—the application-groups key—and exactly
one matching production group value. Missing keys, extra group values, the
restricted Endpoint Security key, or any other additional entitlement key all
fail closed.
