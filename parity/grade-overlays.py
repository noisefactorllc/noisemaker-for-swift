#!/usr/bin/env python3
"""Strict comparison of native top-down RGBA8 overlays to source Canvas bytes."""
import hashlib
import json
import pathlib
import sys


def grade(candidate_dir: pathlib.Path, oracle_dir: pathlib.Path) -> dict:
    ledger = json.loads((oracle_dir / "oracle.json").read_text())
    results = []
    for case in ledger["cases"]:
        expected = (oracle_dir / case["file"]).read_bytes()
        candidate_path = candidate_dir / case["file"]
        result = {"id": case["id"], "status": "fail", "expectedSha256": case["sha256"]}
        if hashlib.sha256(expected).hexdigest() != case["sha256"]:
            raise ValueError(f"oracle binary is stale: {case['id']}")
        if not candidate_path.is_file():
            result["error"] = "candidate missing"
        else:
            actual = candidate_path.read_bytes()
            result["candidateSha256"] = hashlib.sha256(actual).hexdigest()
            if len(actual) != len(expected):
                result["error"] = f"candidate size {len(actual)} differs from {len(expected)}"
            else:
                diffs = [abs(a - b) for a, b in zip(actual, expected)]
                maximum = max(diffs, default=0)
                result["maxChannelError"] = maximum
                result["meanChannelError"] = sum(diffs) / len(diffs) if diffs else 0
                result["differentChannels"] = sum(diff != 0 for diff in diffs)
                result["firstDifferentPixel"] = next(
                    ([index // 4 % case["width"], index // 4 // case["width"]]
                     for index, diff in enumerate(diffs) if diff), None)
                result["status"] = "ok" if maximum == 0 else "fail"
        results.append(result)
    return {"schemaVersion": 1, "expected": len(ledger["cases"]),
            "exact": sum(row["status"] == "ok" for row in results), "cases": results}


def main() -> None:
    if len(sys.argv) not in (2, 3):
        raise SystemExit("usage: python3 parity/grade-overlays.py <candidate-dir> [oracle-dir]")
    candidate = pathlib.Path(sys.argv[1]).resolve()
    oracle = (pathlib.Path(sys.argv[2]) if len(sys.argv) == 3 else
              pathlib.Path(__file__).resolve().parent / "overlays").resolve()
    result = grade(candidate, oracle)
    print(json.dumps(result, indent=2))
    if result["exact"] != result["expected"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
