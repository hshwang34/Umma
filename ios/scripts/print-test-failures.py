#!/usr/bin/env python3
"""Print failed tests from an .xcresult bundle. `xcodebuild -quiet` prints "** TEST FAILED **"
with no test name when a test fails or the runner crashes, so `make ios-check` calls this."""

import json
import subprocess
import sys


def main(bundle: str) -> int:
    try:
        raw = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        summary = json.loads(raw)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as exc:
        print(f"could not read {bundle}: {exc}", file=sys.stderr)
        return 0
    print(
        "Test result: {result} | passed {passedTests} | failed {failedTests} | skipped {skippedTests}".format(
            **{k: summary.get(k, "?") for k in ("result", "passedTests", "failedTests", "skippedTests")}
        )
    )
    for failure in summary.get("testFailures", []):
        name = failure.get("testIdentifierString") or failure.get("testName", "?")
        text = " ".join(str(failure.get("failureText", "")).split())
        print(f"FAILED {name}: {text[:600]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
