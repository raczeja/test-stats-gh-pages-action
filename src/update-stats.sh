#!/usr/bin/env bash

set -euo pipefail

# Reads Playwright-format JSON and optional JUnit, NUnit, xUnit, or VSTest XML results,
# updates site/stats/runs.json with a rolling 30-day window, and regenerates
# site/stats/index.html with a failure/flakiness dashboard.
#
# Required env vars:
#   GITHUB_RUN_NUMBER   - GitHub Actions run number
#   GITHUB_RUN_ID       - GitHub Actions run ID
#   GITHUB_SERVER_URL   - e.g. "https://github.com"
#   GITHUB_REPOSITORY   - e.g. "org/repo"
# Optional env vars:
#   SHELL_TESTS_XML     - optional path to JUnit, NUnit, xUnit, or VSTest XML results

RESULTS_DIR="${RESULTS_DIR:-downloaded-results}"
SITE_DIR="${SITE_DIR:-site}"

mkdir -p "${SITE_DIR}/stats"

python3 - <<PYEOF
import json, os, glob, sys, re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta
from zoneinfo import ZoneInfo

def strip_ansi(s):
    return re.sub(r'\x1b\[[0-9;]*[mGKHFJABCDsu]|\x1b\(B', '', s)

results_dir     = os.environ.get("RESULTS_DIR", "downloaded-results")
site_dir        = os.environ.get("SITE_DIR", "site")
shell_tests_xml = os.environ.get("SHELL_TESTS_XML", "")
report_name     = os.environ.get("REPORT_NAME", "").strip()
repository_name = os.environ.get("GITHUB_REPOSITORY", "").rsplit("/", 1)[-1].strip()
dashboard_name  = " · ".join(name for name in (repository_name, report_name) if name)
dashboard_name  = dashboard_name or "Test results"
run_number      = os.environ.get("GITHUB_RUN_NUMBER", "0")
branch_name     = os.environ.get("GITHUB_HEAD_REF") or os.environ.get("GITHUB_REF_NAME", "")
run_url         = "{}/{}/actions/runs/{}".format(
    os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
    os.environ.get("GITHUB_REPOSITORY", ""),
    os.environ.get("GITHUB_RUN_ID", "0"),
)
cutoff = datetime.now(timezone.utc) - timedelta(days=30)
RUNS_SCHEMA_VERSION = 1


def walk_suites(suite, parents, failed_tests, flaky_tests, slow_tests, all_tests, source_file):
    suite_title = suite.get("title", "")
    cur = parents + ([suite_title] if suite_title else [])
    for spec in suite.get("specs", []):
        spec_title = spec.get("title", "")
        full_title = " > ".join(cur + [spec_title]) if spec_title else " > ".join(cur)
        file_path  = spec.get("file", "")
        for test in spec.get("tests", []):
            status = test.get("status", "")
            test_results = test.get("results", [])
            retries = max(0, len(test_results) - 1)
            final_status = {
                "expected": "passed",
                "unexpected": "failed",
                "flaky": "passed",
                "skipped": "skipped",
            }.get(status, status or "unknown")
            duration_ms = sum(result.get("duration", 0) for result in test_results)
            all_tests.append({
                "source": "Playwright",
                "source_file": os.path.basename(json_file),
                "title": full_title,
                "file": file_path,
                "duration_ms": duration_ms,
                "final_status": final_status,
                "passed_after_retry": status == "flaky",
                "retries": retries,
                "status": {
                    "expected": "passed",
                    "unexpected": "failed",
                    "flaky": "flaky",
                    "skipped": "skipped",
                }.get(status, status or "unknown"),
            })
            if duration_ms > 0:
                slow_tests.append({"title": full_title, "duration_ms": duration_ms})
            if status == "unexpected":
                errors = []
                for result in test.get("results", []):
                    for err in result.get("errors", []):
                        msg = err.get("message", "") or err.get("value", "")
                        if msg:
                            errors.append(strip_ansi(msg)[:300])
                failed_tests.append({
                    "title": full_title,
                    "file": file_path,
                    "source_file": source_file,
                    "error": errors[0] if errors else "",
                })
            elif status == "flaky":
                flaky_tests.append({
                    "title": full_title,
                    "file": file_path,
                    "attempts": len(test.get("results", [])),
                    "retries": retries,
                })
    for sub in suite.get("suites", []):
        walk_suites(sub, cur, failed_tests, flaky_tests, slow_tests, all_tests, source_file)


all_json_files = sorted(glob.glob(os.path.join(results_dir, "*.json")))
print(f"[stats] Found {len(all_json_files)} result file(s) in {results_dir!r}")

agg = {"expected": 0, "unexpected": 0, "flaky": 0, "skipped": 0, "duration_ms": 0}
failed_tests = []
flaky_tests  = []
slow_tests   = []
all_tests    = []

for json_file in all_json_files:
    try:
        with open(json_file) as f:
            data = json.load(f)
    except Exception as e:
        print(f"[stats] Skipping {json_file}: {e}", file=sys.stderr)
        continue
    raw = data.get("stats", {})
    for k in ("expected", "unexpected", "flaky", "skipped"):
        agg[k] += raw.get(k, 0)
    agg["duration_ms"] += raw.get("duration", 0)
    for suite in data.get("suites", []):
        walk_suites(
            suite, [], failed_tests, flaky_tests, slow_tests, all_tests,
            os.path.basename(json_file),
        )

# ── Supplemental XML results ─────────────────────────────────────────────────

shell_passed = 0
shell_failed = 0
shell_skipped = 0
shell_failed_tests = []

shell_xml_files = sorted(glob.glob(shell_tests_xml, recursive=True)) if shell_tests_xml else []
if shell_tests_xml and not shell_xml_files and os.path.isfile(shell_tests_xml):
    shell_xml_files = [shell_tests_xml]
if shell_tests_xml and not shell_xml_files:
    print(f"[stats] No XML test-result files matched {shell_tests_xml!r}", file=sys.stderr)
    raise SystemExit(1)

if shell_xml_files:
    for shell_xml_file in shell_xml_files:
        try:
            root = ET.parse(shell_xml_file).getroot()
        except (ET.ParseError, OSError) as e:
            print(f"[stats] Could not parse XML test results {shell_xml_file}: {e}", file=sys.stderr)
            raise SystemExit(1)

        def local_name(element):
            return element.tag.rsplit("}", 1)[-1]

        root_name = local_name(root)
        if root_name == "TestRun":
            source_name = "VSTest"
            definitions = {}
            for unit_test in root.iter():
                if local_name(unit_test) != "UnitTest":
                    continue
                test_method = next(
                    (element for element in unit_test.iter() if local_name(element) == "TestMethod"),
                    None,
                )
                if test_method is not None:
                    definitions[unit_test.get("id", "")] = test_method.get("className", "")

            outcomes = {
                "Passed": "passed",
                "PassedButRunAborted": "passed",
                "Failed": "failed",
                "Error": "failed",
                "Timeout": "failed",
                "Aborted": "failed",
                "NotRunnable": "failed",
                "Disconnected": "failed",
                "NotExecuted": "skipped",
                "Inconclusive": "skipped",
                "Warning": "skipped",
            }
            for result in root.iter():
                if local_name(result) != "UnitTestResult":
                    continue
                outcome = result.get("outcome", "")
                if outcome not in outcomes:
                    print(f"[stats] Unsupported VSTest outcome {outcome!r} in {shell_xml_file}", file=sys.stderr)
                    raise SystemExit(1)
                shell_status = outcomes[outcome]
                if shell_status == "passed":
                    shell_passed += 1
                elif shell_status == "failed":
                    shell_failed += 1
                else:
                    shell_skipped += 1

                duration = result.get("duration", "")
                try:
                    hours, minutes, seconds = duration.split(":")
                    duration_ms = round(
                        (int(hours) * 3600 + int(minutes) * 60 + float(seconds)) * 1000
                    ) if duration else 0
                except ValueError:
                    print(f"[stats] Invalid VSTest duration {duration!r} in {shell_xml_file}", file=sys.stderr)
                    raise SystemExit(1)

                test_title = result.get("testName", "unnamed")
                test_file = definitions.get(result.get("testId", ""), "")
                if shell_status == "failed":
                    message = next(
                        (
                            element.text or ""
                            for element in result.iter()
                            if local_name(element) == "Message" and element.text
                        ),
                        "",
                    )
                    shell_failed_tests.append({
                        "title": test_title,
                        "file": test_file,
                        "source_file": os.path.basename(shell_xml_file),
                        "error": strip_ansi(message)[:300],
                    })
                all_tests.append({
                    "source": source_name,
                    "source_file": os.path.basename(shell_xml_file),
                    "title": test_title,
                    "file": test_file,
                    "duration_ms": duration_ms,
                    "status": shell_status,
                })
                if duration_ms > 0:
                    slow_tests.append({"title": test_title, "duration_ms": duration_ms})
        elif root_name in ("testsuite", "testsuites"):
            source_name = "JUnit"
            suites = [element for element in root.iter() if local_name(element) == "testsuite"]
            for suite in suites:
                suite_name = suite.get("name", "")
                for tc in (element for element in suite if local_name(element) == "testcase"):
                    duration_ms = round(float(tc.get("time", 0) or 0) * 1000)
                    child_names = {local_name(element) for element in tc}
                    if "skipped" in child_names:
                        shell_skipped += 1
                        shell_status = "skipped"
                    elif "failure" in child_names or "error" in child_names:
                        shell_failed += 1
                        shell_status = "failed"
                        elem = next(
                            element for element in tc
                            if local_name(element) in ("failure", "error")
                        )
                        msg = strip_ansi(elem.get("message", "") or elem.text or "")[:300]
                        shell_failed_tests.append({
                            "title": f"{suite_name} > {tc.get('name', '?')}",
                            "file": tc.get("classname", ""),
                            "source_file": os.path.basename(shell_xml_file),
                            "error": msg,
                        })
                    else:
                        shell_passed += 1
                        shell_status = "passed"
                    shell_title = f"{suite_name} > {tc.get('name', '?')}"
                    all_tests.append({
                        "source": source_name,
                        "source_file": os.path.basename(shell_xml_file),
                        "title": shell_title,
                        "file": tc.get("classname", ""),
                        "duration_ms": duration_ms,
                        "status": shell_status,
                    })
                    if duration_ms > 0:
                        slow_tests.append({"title": shell_title, "duration_ms": duration_ms})
        elif root_name in ("test-run", "test-results"):
            source_name = "NUnit"
            for case in root.iter():
                if local_name(case) != "test-case":
                    continue
                outcome = (case.get("result") or "").lower()
                success = (case.get("success") or "").lower()
                executed = (case.get("executed") or "").lower()
                if outcome in ("passed", "pass", "success") or success == "true":
                    shell_status = "passed"
                elif outcome in ("failed", "failure", "error", "cancelled", "notrunnable", "invalid") or (
                    success == "false" and executed != "false"
                ):
                    shell_status = "failed"
                elif outcome in (
                    "skipped", "ignored", "inconclusive", "warning", "notrun", "notexecuted"
                ) or executed == "false":
                    shell_status = "skipped"
                else:
                    print(f"[stats] Unsupported NUnit result {case.get('result')!r} in {shell_xml_file}", file=sys.stderr)
                    raise SystemExit(1)
                if shell_status == "passed":
                    shell_passed += 1
                elif shell_status == "failed":
                    shell_failed += 1
                else:
                    shell_skipped += 1
                try:
                    duration_ms = round(
                        float(case.get("duration", case.get("time", 0)) or 0) * 1000
                    )
                except ValueError:
                    print(f"[stats] Invalid NUnit duration in {shell_xml_file}", file=sys.stderr)
                    raise SystemExit(1)
                test_title = case.get("fullname") or case.get("name", "unnamed")
                test_file = case.get("class") or case.get("classname", "")
                if shell_status == "failed":
                    message = next(
                        (
                            element.text or ""
                            for element in case.iter()
                            if local_name(element) == "message" and element.text
                        ),
                        "",
                    )
                    shell_failed_tests.append({
                        "title": test_title,
                        "file": test_file,
                        "source_file": os.path.basename(shell_xml_file),
                        "error": strip_ansi(message)[:300],
                    })
                all_tests.append({
                    "source": source_name,
                    "source_file": os.path.basename(shell_xml_file),
                    "title": test_title,
                    "file": test_file,
                    "duration_ms": duration_ms,
                    "status": shell_status,
                })
                if duration_ms > 0:
                    slow_tests.append({"title": test_title, "duration_ms": duration_ms})
        elif root_name == "assemblies":
            source_name = "xUnit"
            for assembly in root.iter():
                if local_name(assembly) != "assembly":
                    continue
                for case in assembly.iter():
                    if local_name(case) != "test":
                        continue
                    outcome = (case.get("result") or "").lower()
                    if outcome in ("pass", "passed"):
                        shell_status = "passed"
                    elif outcome in ("fail", "failed", "error"):
                        shell_status = "failed"
                    elif outcome in ("skip", "skipped", "notrun"):
                        shell_status = "skipped"
                    else:
                        print(f"[stats] Unsupported xUnit result {case.get('result')!r} in {shell_xml_file}", file=sys.stderr)
                        raise SystemExit(1)
                    if shell_status == "passed":
                        shell_passed += 1
                    elif shell_status == "failed":
                        shell_failed += 1
                    else:
                        shell_skipped += 1
                    try:
                        duration_ms = round(float(case.get("time", 0) or 0) * 1000)
                    except ValueError:
                        print(f"[stats] Invalid xUnit duration in {shell_xml_file}", file=sys.stderr)
                        raise SystemExit(1)
                    test_title = case.get("name", "unnamed")
                    test_file = case.get("type", "")
                    if shell_status == "failed":
                        message = next(
                            (
                                element.text or ""
                                for element in case.iter()
                                if local_name(element) == "message" and element.text
                            ),
                            "",
                        )
                        shell_failed_tests.append({
                            "title": test_title,
                            "file": test_file,
                            "source_file": os.path.basename(shell_xml_file),
                            "error": strip_ansi(message)[:300],
                        })
                    all_tests.append({
                        "source": source_name,
                        "source_file": os.path.basename(shell_xml_file),
                        "title": test_title,
                        "file": test_file,
                        "duration_ms": duration_ms,
                        "status": shell_status,
                    })
                    if duration_ms > 0:
                        slow_tests.append({"title": test_title, "duration_ms": duration_ms})
        else:
            print(f"[stats] Unsupported XML test-result root {root_name!r} in {shell_xml_file}", file=sys.stderr)
            raise SystemExit(1)

    print(f"[stats] Additional tests: passed={shell_passed} failed={shell_failed} skipped={shell_skipped}")
    if shell_failed_tests:
        print(f"[stats] Additional test failures ({len(shell_failed_tests)}):")
        for t in shell_failed_tests:
            print(f"    - {t['title']}")
else:
    print(f"[stats] No supplemental XML test results provided — skipping")

run_entry = {
    "run_id":              run_number,
    "run_url":             run_url,
    "branch":              branch_name,
    "timestamp":           datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "total":               agg["expected"] + agg["unexpected"] + agg["flaky"] + agg["skipped"],
    "passed":              agg["expected"],
    "failed":              agg["unexpected"],
    "skipped":             agg["skipped"],
    "flaky_count":         agg["flaky"],
    "passed_after_retry_count": agg["flaky"],
    "retry_count":         sum(test.get("retries", 0) for test in all_tests),
    "duration_ms":         agg["duration_ms"],
    "slowest_tests":       sorted(slow_tests, key=lambda x: -x["duration_ms"])[:10],
    "failed_tests":        failed_tests,
    "flaky_tests":         flaky_tests,
    "tests":               all_tests,
    "shell_passed":        shell_passed,
    "shell_failed":        shell_failed,
    "shell_skipped":       shell_skipped,
    "shell_failed_tests":  shell_failed_tests,
}
print(f"[stats] Run #{run_number}: playwright total={run_entry['total']} passed={run_entry['passed']} "
      f"failed={run_entry['failed']} passed_after_retry={run_entry['passed_after_retry_count']} "
      f"retries={run_entry['retry_count']} skipped={run_entry['skipped']}")
if failed_tests:
    print(f"[stats] Failed tests ({len(failed_tests)}):")
    for t in failed_tests:
        print(f"    - {t['title']}")
if flaky_tests:
    print(f"[stats] Flaky tests ({len(flaky_tests)}):")
    for t in flaky_tests:
        print(f"    ~ {t['title']}")

stats_dir = os.path.join(site_dir, "stats")
os.makedirs(stats_dir, exist_ok=True)
runs_file = os.path.join(stats_dir, "runs.json")

if os.path.exists(runs_file):
    with open(runs_file) as f:
        store = json.load(f)
    if not isinstance(store, dict) or not isinstance(store.get("runs"), list):
        print(f"[stats] Existing {runs_file} must contain a runs array", file=sys.stderr)
        raise SystemExit(1)
    if "schemaVersion" in store:
        schema_version = store["schemaVersion"]
        if isinstance(schema_version, bool) or not isinstance(schema_version, int) or schema_version != RUNS_SCHEMA_VERSION:
            print(
                f"[stats] Unsupported runs.json schemaVersion {schema_version!r}; "
                f"expected {RUNS_SCHEMA_VERSION}",
                file=sys.stderr,
            )
            raise SystemExit(1)
    store["schemaVersion"] = RUNS_SCHEMA_VERSION
    prev_count = len(store.get("runs", []))
    print(f"[stats] Loaded existing runs.json: {prev_count} run(s) on record")
else:
    store = {"schemaVersion": RUNS_SCHEMA_VERSION, "runs": []}
    prev_count = 0
    print(f"[stats] No existing runs.json — starting fresh")

store["runs"] = [
    r for r in store["runs"]
    if r.get("run_id") != run_number
    and datetime.fromisoformat(r["timestamp"].replace("Z", "+00:00")) >= cutoff
]
pruned = prev_count - len(store["runs"])
if pruned > 0:
    print(f"[stats] Pruned {pruned} run(s) (duplicate run_id or older than 30 days)")

previous_run = max(
    (r for r in store["runs"] if r.get("branch", "") == branch_name),
    key=lambda r: r["timestamp"],
    default=None,
)
previous_tests = None
if previous_run is not None and isinstance(previous_run.get("tests"), list):
    previous_tests = {
        (t.get("source", ""), t.get("file", ""), t.get("title", "")): t.get("status", "")
        for t in previous_run["tests"]
    }
    for test in all_tests:
        key = (test["source"], test["file"], test["title"])
        if key not in previous_tests:
            test["change"] = "new"
        elif previous_tests[key] != test["status"]:
            test["change"] = "changed"
            test["previous_status"] = previous_tests[key]

run_entry["test_comparison_available"] = previous_tests is not None
if previous_run is not None:
    run_entry["compared_with_run_id"] = previous_run.get("run_id", "")

store["runs"].append(run_entry)
store["runs"].sort(key=lambda r: r["timestamp"])

with open(runs_file, "w") as f:
    json.dump(store, f, indent=2)
print(f"[stats] runs.json updated: {len(store['runs'])} run(s) → {runs_file}")


# ── Dashboard helpers ───────────────────────────────────────────────────────

def is_all_failed_run(run):
    total = run.get("total", 0) + run.get("shell_passed", 0) + run.get("shell_failed", 0) + run.get("shell_skipped", 0)
    skipped = run.get("skipped", 0) + run.get("shell_skipped", 0)
    executed = max(0, total - skipped)
    failed = run.get("failed", 0) + run.get("shell_failed", 0)
    return executed > 0 and failed >= executed

def total_tests(run):
    return (
        run.get("total", 0)
        + run.get("shell_passed", 0)
        + run.get("shell_failed", 0)
        + run.get("shell_skipped", 0)
    )

def retry_count(run):
    if isinstance(run.get("retry_count"), int):
        return run["retry_count"]
    tests = run.get("tests", [])
    if any("retries" in test for test in tests):
        return sum(test.get("retries", 0) for test in tests)
    return sum(
        test.get("retries", max(0, test.get("attempts", 1) - 1))
        for test in run.get("flaky_tests", [])
    )

def top_failing(runs, n=10):
    counts = {}
    for run in runs:
        if is_all_failed_run(run):
            continue
        for key in ("failed_tests", "shell_failed_tests"):
            for test in run.get(key, []):
                title = test["title"]
                counts[title] = counts.get(title, 0) + 1
    return sorted(counts.items(), key=lambda x: -x[1])[:n]

def flaky_counts(runs):
    eligible = [r for r in runs if not is_all_failed_run(r)]
    counts = {}
    for run in eligible:
        seen = set()
        for t in run.get("flaky_tests", []):
            k = t["title"]
            if k not in seen:
                counts[k] = counts.get(k, 0) + 1
                seen.add(k)
    # Cross-run intermittent failures
    fail_counts = {}
    for run in eligible:
        seen = set()
        for key in ("failed_tests", "shell_failed_tests"):
            for test in run.get(key, []):
                title = test["title"]
                if title not in seen:
                    fail_counts[title] = fail_counts.get(title, 0) + 1
                    seen.add(title)
    total = len(eligible)
    for k, c in fail_counts.items():
        if 0 < c < total:
            counts[k] = max(counts.get(k, 0), c)
    return sorted(counts.items(), key=lambda x: (-x[1], x[0]))

def dashboard_stats(selected_runs):
    eligible_runs = [run for run in selected_runs if not is_all_failed_run(run)]
    total_executed = sum(
        max(0, total_tests(run) - run.get("skipped", 0) - run.get("shell_skipped", 0))
        for run in eligible_runs
    )
    total_passed = sum(
        run.get("passed", 0) + run.get("shell_passed", 0) + run.get("flaky_count", 0)
        for run in eligible_runs
    )
    total_failed = sum(
        run.get("failed", 0) + run.get("shell_failed", 0) for run in eligible_runs
    )
    total_flaky = sum(run.get("flaky_count", 0) for run in eligible_runs)
    durations = [
        run.get("duration_ms", 0)
        for run in eligible_runs
        if run.get("duration_ms", 0) > 0
    ]

    slow_by_test = {}
    retry_by_test = {}
    for run in eligible_runs:
        for test in run.get("slowest_tests", []):
            slow_by_test[test["title"]] = max(
                slow_by_test.get(test["title"], 0), test["duration_ms"]
            )
        for test in run.get("tests", []):
            retries = test.get("retries", 0)
            if retries > 0:
                retry_by_test[test["title"]] = retry_by_test.get(test["title"], 0) + retries
        if not any("retries" in test for test in run.get("tests", [])):
            for test in run.get("flaky_tests", []):
                retries = test.get("retries", max(0, test.get("attempts", 1) - 1))
                if retries > 0:
                    retry_by_test[test["title"]] = retry_by_test.get(test["title"], 0) + retries

    return {
        "run_count": len(selected_runs),
        "pass_rate": round(
            100 * (1 - total_failed / max(1, sum(total_tests(run) for run in eligible_runs))),
            1,
        ),
        "avg_total": int(round(total_executed / max(1, len(eligible_runs)))),
        "avg_passed": int(round(total_passed / max(1, len(eligible_runs)))),
        "avg_failed": round(total_failed / max(1, len(eligible_runs)), 1),
        "avg_flaky": round(total_flaky / max(1, len(eligible_runs)), 1),
        "avg_retries": round(
            sum(retry_count(run) for run in eligible_runs) / max(1, len(eligible_runs)), 1
        ),
        "avg_duration_ms": (
            int(round(sum(durations) / len(durations))) if durations else 0
        ),
        "min_duration_ms": min(durations, default=0),
        "max_duration_ms": max(durations, default=0),
        "agg": {
            "top": [[title, count] for title, count in top_failing(selected_runs, 5)],
            "flaky": [[title, count] for title, count in flaky_counts(selected_runs)[:5]],
            "slow": [
                [title, duration]
                for title, duration in sorted(
                    slow_by_test.items(), key=lambda item: -item[1]
                )[:5]
            ],
            "retried": [
                [title, count]
                for title, count in sorted(
                    retry_by_test.items(), key=lambda item: -item[1]
                )[:5]
            ],
        },
    }

def short_name(title):
    parts = [p.strip() for p in title.split(">") if p.strip()]
    if len(parts) >= 2:
        return " › ".join(parts[-2:])
    return parts[-1] if parts else title

def esc(s):
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")

# ── Build dashboard ─────────────────────────────────────────────────────────

runs      = store["runs"]
eligible  = [r for r in runs if not is_all_failed_run(r)]
branch_names = sorted({
    run.get("branch")
    for run in runs
    if isinstance(run.get("branch"), str) and run.get("branch")
})
filter_stats = {"all": dashboard_stats(runs)}
for branch_name in branch_names:
    filter_stats["branch:" + branch_name] = dashboard_stats([
        run for run in runs if run.get("branch") == branch_name
    ])
if any(not isinstance(run.get("branch"), str) or not run.get("branch") for run in runs):
    filter_stats["unknown"] = dashboard_stats([
        run for run in runs if not isinstance(run.get("branch"), str) or not run.get("branch")
    ])

total_executed = sum(max(0, total_tests(r) - r.get("skipped", 0) - r.get("shell_skipped", 0)) for r in eligible)
total_passed   = sum(r.get("passed", 0) + r.get("shell_passed", 0) + r.get("flaky_count", 0) for r in eligible)
total_failed   = sum(r.get("failed", 0) + r.get("shell_failed", 0) for r in eligible)
total_flaky    = sum(r.get("flaky_count", 0) for r in eligible)
avg_passed     = int(round(total_passed / max(1, len(eligible))))
avg_total      = int(round(total_executed / max(1, len(eligible))))
avg_failed     = round(total_failed / max(1, len(eligible)), 1)
avg_flaky      = round(total_flaky / max(1, len(eligible)), 1)
pass_rate      = round(100 * (1 - total_failed / max(1, sum(total_tests(r) for r in eligible))), 1)

durations      = [r.get("duration_ms", 0) for r in eligible if r.get("duration_ms", 0) > 0]
avg_dur_ms     = int(round(sum(durations) / max(1, len(durations)))) if durations else 0
max_dur_ms     = max(durations) if durations else 0
min_dur_ms     = min(durations) if durations else 0

def fmt_dur(ms):
    if not ms: return "—"
    if ms < 1000: return f"{ms:.0f} ms"
    s = ms / 1000
    if s < 60: return f"{s:.0f}s"
    return f"{int(s // 60)}m {int(s % 60)}s"

total_retries = sum(retry_count(r) for r in eligible)
avg_retries = round(total_retries / max(1, len(eligible)), 1)
rate_cls = "rate-ok" if pass_rate >= 90 else ("rate-warn" if pass_rate >= 70 else "rate-bad")

now_utc = datetime.now(timezone.utc)
now_de  = now_utc.astimezone(ZoneInfo("Europe/Berlin"))
updated_label = f"{now_de.strftime('%Y-%m-%d %H:%M %Z')} ({now_utc.strftime('%H:%M UTC')})"

dashboard = os.path.join(site_dir, "stats", "index.html")
with open(dashboard, "w") as fh:
    fh.write(f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(dashboard_name)} &middot; Test Statistics</title>
<style>
*{{box-sizing:border-box}}
body{{font-family:system-ui,-apple-system,Arial,sans-serif;margin:0;background:#f0f2f5;color:#1a1a2e;min-height:100vh}}
.topbar{{background:#1a1a2e;color:#fff;padding:.75rem 2rem;display:flex;align-items:center;gap:1rem}}
.topbar a{{color:#93c5fd;text-decoration:none;font-size:.875rem}}
.topbar a:hover{{text-decoration:underline}}
.topbar-title{{font-weight:700;font-size:1rem;flex:1}}
.topbar-meta{{font-size:.78rem;color:#94a3b8}}
.page{{max-width:60rem;margin:0 auto;padding:1.5rem 2rem 3rem}}
.legend{{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem 1.25rem;margin-bottom:1.25rem;padding:.75rem 1rem;background:#fff;border:1px solid #e2e8f0;border-radius:.625rem;font-size:.8rem;color:#475569}}
.legend-item{{display:inline-flex;align-items:center;gap:.375rem}}
.legend-note{{width:100%;color:#94a3b8;font-size:.75rem;margin-top:.2rem}}
.legend-swatch{{width:.75rem;height:.75rem;border-radius:2px;display:inline-block;flex-shrink:0;border:1px solid rgba(0,0,0,.1)}}
.sw-green{{background:#22c55e}}.sw-red{{background:#ef4444}}.sw-yellow{{background:#eab308}}
.sw-mixed{{background:linear-gradient(to top,#eab308 0%,#eab308 50%,#ef4444 50%)}}
.sw-black{{background:#1e293b}}
.card{{background:#fff;border:1px solid #e2e8f0;border-radius:.75rem;padding:1.25rem;margin-bottom:1.25rem;box-shadow:0 1px 3px rgba(0,0,0,.06)}}
.card-header{{display:flex;align-items:center;justify-content:space-between;margin-bottom:.875rem}}
.card-title{{font-size:1rem;font-weight:700;color:#1a1a2e;margin:0}}
.rate-pill{{font-size:.875rem;font-weight:700;padding:.2rem .65rem;border-radius:999px}}
.rate-ok{{background:#dcfce7;color:#15803d}}
.rate-warn{{background:#fef9c3;color:#854d0e}}
.rate-bad{{background:#fee2e2;color:#b91c1c}}
.stats-row{{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:.625rem;margin-bottom:.875rem}}
.selected-run-stats{{grid-template-columns:repeat(6,minmax(0,1fr))}}
.duration-stats{{grid-template-columns:repeat(3,minmax(0,1fr))}}
.stat-box{{background:#f8fafc;border:1px solid #e2e8f0;border-radius:.5rem;padding:.6rem .5rem;text-align:center}}
.stat-val{{font-size:1.15rem;font-weight:700;color:#1a1a2e;line-height:1.2}}
.stat-lbl{{font-size:.68rem;color:#94a3b8;text-transform:uppercase;letter-spacing:.05em;margin-top:.15rem}}
.stat-fail .stat-val{{color:#dc2626}}
.stat-flaky .stat-val{{color:#d97706}}
.spark-label{{font-size:.7rem;font-weight:700;text-transform:uppercase;letter-spacing:.06em;color:#94a3b8;margin-bottom:.3rem}}
.sparkline{{height:72px;display:flex;align-items:flex-end;gap:3px;padding:.25rem 0;border-bottom:1px solid #f1f5f9;overflow:hidden;margin-bottom:.875rem}}
.sparkline a{{flex:0 0 auto;display:flex;align-items:flex-end}}
.bar{{width:7px;border-radius:2px 2px 0 0}}
.bar:hover{{opacity:.7}}
.section-lbl{{font-size:.7rem;font-weight:700;color:#64748b;text-transform:uppercase;letter-spacing:.06em;margin:.75rem 0 .35rem}}
.table-scroll{{max-width:100%;overflow-x:auto}}
table{{width:100%;border-collapse:collapse;font-size:.8rem}}
th{{text-align:left;padding:.3rem .4rem;color:#94a3b8;font-weight:600;border-bottom:2px solid #e2e8f0;font-size:.72rem;text-transform:uppercase;letter-spacing:.05em}}
td{{padding:.3rem .4rem;border-bottom:1px solid #f8fafc;word-break:break-word;color:#374151}}
td:last-child{{text-align:right;font-weight:700;color:#dc2626;white-space:nowrap}}
.flaky-list{{margin:.35rem 0 0;padding-left:1rem;font-size:.8rem;color:#374151}}
.flaky-list li{{margin:.2rem 0}}
.flaky-list strong{{color:#d97706}}
.all-tests td:last-child{{text-align:left;font-weight:400;color:#374151;white-space:normal}}
.all-tests th button{{border:0;background:transparent;color:inherit;font:inherit;letter-spacing:inherit;text-transform:inherit;padding:0;cursor:pointer}}
.all-tests th button:hover{{color:#475569}}
.test-detail-trigger{{border:0;background:transparent;padding:0;color:#2563eb;font:inherit;text-align:left;cursor:pointer}}
.test-detail-trigger:hover{{text-decoration:underline}}
.test-detail{{margin-top:.75rem;border:1px solid #cbd5e1;border-radius:.625rem;background:#fff;padding:1rem}}
.test-detail-header{{display:flex;align-items:flex-start;justify-content:space-between;gap:1rem}}
.test-detail-close{{border:1px solid #cbd5e1;border-radius:.375rem;background:#fff;color:#334155;padding:.25rem .55rem;cursor:pointer}}
.test-detail-title{{font-weight:700;overflow-wrap:anywhere}}
.test-detail-summary{{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.625rem;margin:.875rem 0}}
.test-detail-summary-item{{background:#f8fafc;border:1px solid #e2e8f0;border-radius:.5rem;padding:.6rem}}
.test-detail-summary-item strong{{display:block;font-size:.85rem}}
.test-detail-summary-item span{{display:block;font-size:.68rem;color:#64748b;text-transform:uppercase;letter-spacing:.05em;margin-top:.15rem}}
.test-timeline{{display:flex;align-items:center;gap:.25rem;margin:.5rem 0 1rem;min-height:1.75rem}}
.test-timeline a{{width:1.25rem;height:1.25rem;border-radius:.25rem;border:1px solid rgba(0,0,0,.12);display:block}}
.test-timeline-passed{{background:#22c55e}}
.test-timeline-failed{{background:#ef4444}}
.test-timeline-skipped{{background:#94a3b8}}
.test-timeline-flaky{{background:#eab308}}
.test-detail-table td:last-child{{text-align:left;font-weight:400;color:#374151}}
.comparison-note{{font-size:.78rem;color:#64748b;margin:.25rem 0 .5rem}}
.status-badge,.change-badge{{display:inline-block;border-radius:999px;padding:.1rem .45rem;font-size:.7rem;font-weight:700;white-space:nowrap}}
.status-passed{{background:#dcfce7;color:#15803d}}
.status-failed{{background:#fee2e2;color:#b91c1c}}
.status-flaky{{background:#fef3c7;color:#b45309}}
.status-skipped{{background:#f1f5f9;color:#64748b}}
.change-new{{background:#dbeafe;color:#1d4ed8}}
.change-updated{{background:#ffedd5;color:#c2410c}}
#all-tests-body tr.test-trend-match td{{background:#fef3c7}}
.test-pagination,.run-pagination{{display:flex;align-items:center;justify-content:flex-end;flex-wrap:wrap;gap:.6rem;margin:.75rem 0;font-size:.78rem;color:#64748b}}
.test-pagination button,.run-pagination button{{border:1px solid #cbd5e1;border-radius:.375rem;background:#fff;color:#334155;padding:.3rem .6rem;cursor:pointer}}
.test-pagination button:disabled,.run-pagination button:disabled{{color:#94a3b8;background:#f8fafc;cursor:not-allowed}}
.test-pagination select{{border:1px solid #cbd5e1;border-radius:.375rem;background:#fff;color:#334155;padding:.3rem}}
.all-tests th{{vertical-align:top;min-width:5rem}}
.column-filter{{margin-top:.3rem;text-transform:none;letter-spacing:normal;font-size:.72rem;font-weight:400}}
.column-filter summary{{cursor:pointer;color:#64748b;text-transform:none;white-space:nowrap}}
.column-filter-options{{display:flex;flex-direction:column;gap:.2rem;max-height:5rem;overflow:auto;margin-top:.25rem;text-transform:none}}
.column-filter-options label{{display:inline-flex;align-items:center;gap:.25rem;font-size:.72rem;font-weight:400;color:#475569;text-transform:none;white-space:normal}}
.column-filter-name{{box-sizing:border-box;width:100%;min-width:4rem;margin-top:.3rem;border:1px solid #cbd5e1;border-radius:.3rem;padding:.3rem;color:#334155;text-transform:none;letter-spacing:normal;font-size:.75rem;font-weight:400}}
.column-filter-time{{box-sizing:border-box;width:100%;min-width:5rem;margin-top:.3rem;border:1px solid #cbd5e1;border-radius:.3rem;padding:.3rem;color:#334155;text-transform:none;letter-spacing:normal;font-size:.72rem;font-weight:400}}
.test-filter-reset{{align-self:start;border:1px solid #cbd5e1;border-radius:.375rem;background:#fff;color:#334155;padding:.4rem .65rem;cursor:pointer}}
.test-filter-reset:hover{{background:#f8fafc}}
.test-filter-empty{{text-align:center;color:#64748b;padding:.75rem}}
a{{color:#2563eb;text-decoration:none}}a:hover{{text-decoration:underline}}
.empty{{text-align:center;padding:4rem;color:#94a3b8}}
@media(max-width:640px){{
  .topbar{{padding:.75rem 1rem;flex-wrap:wrap;gap:.5rem .75rem}}
  .topbar-title{{flex-basis:calc(100% - 8rem)}}
  .topbar-meta{{flex-basis:100%}}
  .page{{padding:1rem .75rem 2rem}}
  .card{{padding:.875rem}}
  .card-header{{align-items:flex-start;flex-wrap:wrap;gap:.5rem}}
  .stats-row,.selected-run-stats,.duration-stats{{grid-template-columns:repeat(2,minmax(0,1fr))}}
  .test-pagination{{justify-content:flex-start}}
}}
</style>
</head><body>
<div class="topbar">
  <span class="topbar-title">{esc(dashboard_name)} &middot; Test Statistics</span>
  <a href="../">&larr; All reports</a>
  <span class="topbar-meta">Last 30 days &middot; Updated {esc(updated_label)}</span>
</div>
<div class="page">
<div class="legend" aria-label="Sparkline legend">
  <span class="legend-item"><span class="legend-swatch sw-green"></span>All passed</span>
  <span class="legend-item"><span class="legend-swatch sw-red"></span>Failures</span>
  <span class="legend-item"><span class="legend-swatch sw-yellow"></span>Flaky only</span>
  <span class="legend-item"><span class="legend-swatch sw-mixed"></span>Failures + flaky</span>
  <span class="legend-item"><span class="legend-swatch sw-black"></span>All failed (excluded from stats)</span>
  <span class="legend-note">Bars: newest &larr; oldest. Bar height = total tests across configured result sources; color = pass/fail status. Cards sorted newest execution first.</span>
</div>
""")

    if not runs:
        fh.write('<div class="empty"><p>No statistics available yet.</p></div>\n')
    else:
        fh.write('<div class="card">\n')
        # Select a run before showing its test list; newest run is selected by default.
        fh.write('<div class="section-lbl">Tests in selected run</div>\n')
        fh.write('<label for="branch-picker" class="section-lbl">Branch</label>\n')
        fh.write('<select id="branch-picker" aria-label="Filter by branch" '
                 'style="font-size:.8rem;padding:.35rem .6rem;border:1px solid #e2e8f0;'
                 'border-radius:.4rem;background:#fff;color:#374151;width:100%;'
                 'max-width:42rem;cursor:pointer">\n')
        fh.write('<option value="all">All branches</option>\n')
        for _branch in branch_names:
            fh.write(f'<option value="{esc("branch:" + _branch)}">{esc(_branch)}</option>\n')
        if "unknown" in filter_stats:
            fh.write('<option value="unknown">Unknown branch</option>\n')
        fh.write('</select>\n')
        fh.write('<select id="run-picker" style="font-size:.8rem;padding:.35rem .6rem;border:1px solid #e2e8f0;border-radius:.4rem;background:#fff;color:#374151;width:100%;max-width:42rem;cursor:pointer">\n')
        for _i, _run in enumerate(reversed(runs[-20:])):
            _orig_idx = len(runs) - 1 - _i
            _ts = _run["timestamp"][:16].replace("T", " ")
            _fail = _run.get("failed", 0) + _run.get("shell_failed", 0)
            _status = "✓" if _fail == 0 else "✗"
            _label = (
                f"{_status} Run #{_run['run_id']} — {_ts}Z"
                f" — {_run.get('passed', 0) + _run.get('flaky_count', 0) + _run.get('shell_passed', 0)}p / {_fail}f"
                f" / {_run.get('passed_after_retry_count', _run.get('flaky_count', 0))} passed after retry"
                f" / {retry_count(_run)} retries"
                f" / {_run.get('skipped', 0) + _run.get('shell_skipped', 0)} skipped"
            )
            _selected = " selected" if _orig_idx == len(runs) - 1 else ""
            fh.write(f'<option value="{_orig_idx}"{_selected}>{esc(_label)}</option>\n')
        fh.write('</select>\n')
        fh.write('<div class="run-pagination" aria-label="Run selector pagination">'
                 '<button type="button" id="run-page-prev" aria-label="Newer runs" disabled>Newer</button>'
                 '<span id="run-page-range"></span>'
                 '<button type="button" id="run-page-next" aria-label="Older runs">Older</button></div>\n')
        fh.write('<button type="button" class="test-filter-reset" id="export-runs-json">Export JSON</button>\n')
        fh.write('<button type="button" class="test-filter-reset" id="reset-dashboard-preferences">Reset filters and selections</button>\n')
        fh.write('<div id="selected-run-tests"></div>\n')
        fh.write('<div id="test-detail" aria-live="polite"></div>\n')
        fh.write('<div id="run-detail" style="margin-top:.875rem"></div>\n')
        _runs_store_json = json.dumps(store).replace('</', '<\\/')
        _filter_stats_json = json.dumps(filter_stats).replace('</', '<\\/')
        fh.write(
            f'<script>var RUNS_STORE={_runs_store_json};var RUNS=RUNS_STORE.runs;'
            f'var FILTER_STATS={_filter_stats_json};</script>\n'
        )
        fh.write('''\
<script>
(function(){
  var picker=document.getElementById('run-picker');
  var branchPicker=document.getElementById('branch-picker');
  var runPagePrev=document.getElementById('run-page-prev');
  var runPageNext=document.getElementById('run-page-next');
  var runPageRange=document.getElementById('run-page-range');
  var testsBox=document.getElementById('selected-run-tests');
  var detail=document.getElementById('run-detail');
  var runPageSize=20;
  var runPage=0;
  var visibleRunIndices=[];
  var cookiePath=location.pathname.slice(0,location.pathname.lastIndexOf('/')+1)||'/';
  var cookieName='testStatsPrefs_'+cookiePath.replace(/[^a-zA-Z0-9]/g,'_');
  function readPrefs(){
    var prefix=cookieName+'=',cookies=document.cookie.split(';');
    for(var i=0;i<cookies.length;i++){
      var item=cookies[i].trim();
      if(item.indexOf(prefix)===0){
        try{return JSON.parse(decodeURIComponent(item.slice(prefix.length)))||{};}catch(error){return {};}
      }
    }
    return {};
  }
  var savedPrefs=readPrefs();
  var allowedPageSizes=[30,50,100];
  var allowedSortColumns=['priority','title','source','status','duration','change'];
  var testsPerPage=allowedPageSizes.indexOf(Number(savedPrefs.testsPerPage))!==-1?Number(savedPrefs.testsPerPage):30;
  var currentPage=Number.isInteger(savedPrefs.currentPage)&&savedPrefs.currentPage>=0?savedPrefs.currentPage:0;
  var allTests=[];
  var currentTests=[];
  var timeThresholds={};
  var sortColumn=allowedSortColumns.indexOf(savedPrefs.sortColumn)!==-1?savedPrefs.sortColumn:'priority';
  var sortDirection=savedPrefs.sortDirection===-1?-1:1;
  function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
  function savePrefs(){
    var name=document.getElementById('test-name-filter');
    var latestPrefs=readPrefs();
    var prefs={
      testsPerPage:testsPerPage,
      currentPage:currentPage,
      sortColumn:sortColumn,
      sortDirection:sortDirection,
      testName:name?name.value:'',
      timeFilter:document.getElementById('test-time-filter')?document.getElementById('test-time-filter').value:'all',
      'test-filter-source':checkedValues('test-filter-source'),
      'test-filter-status':checkedValues('test-filter-status'),
      'test-filter-change':checkedValues('test-filter-change'),
      aggPicker:latestPrefs.aggPicker||savedPrefs.aggPicker||'top',
      branch:branchPicker.value
    };
    var aggPicker=document.getElementById('agg-picker');
    if(aggPicker&&['top','flaky','longest','retried'].indexOf(aggPicker.value)!==-1){prefs.aggPicker=aggPicker.value;}
    document.cookie=cookieName+'='+encodeURIComponent(JSON.stringify(prefs))+'; Path='+cookiePath+'; Max-Age=31536000; SameSite=Lax';
    savedPrefs=prefs;
  }
  function fmtDur(ms){if(!ms)return '&mdash;';if(ms<1000)return Math.round(ms)+' ms';var s=ms/1000;if(s<60)return s.toFixed(0)+'s';return Math.floor(s/60)+'m '+Math.floor(s%60)+'s';}
  function fmtTestDur(ms){if(typeof ms!=='number'||ms<=0)return '&mdash;';if(ms<1000)return Math.round(ms)+' ms';if(ms<60000)return (ms/1000).toFixed(2)+' s';var s=ms/1000;return Math.floor(s/60)+'m '+(s%60).toFixed(1)+'s';}
  function shortName(t){var p=t.split('>').map(function(x){return x.trim();}).filter(Boolean);return p.length>=2?p.slice(-2).join(' › '):(p[p.length-1]||t);}
  function clip(s,n){return s.length>n?s.slice(-n):s;}
  function statusRank(status){
    var ranks={failed:0,flaky:1,passed:2,skipped:3};
    return Object.prototype.hasOwnProperty.call(ranks,status)?ranks[status]:4;
  }
  function finalStatus(test){
    return test.final_status||(test.status==='flaky'?'passed':(test.status||'unknown'));
  }
  function passedAfterRetry(test){
    return test.passed_after_retry===true||(!Object.prototype.hasOwnProperty.call(test,'passed_after_retry')&&test.status==='flaky');
  }
  function retryCount(test){
    return Number(test.retries)||0;
  }
  function testIdentity(test){
    return (test.source||'')+'\\u0000'+(test.file||'')+'\\u0000'+(test.title||'');
  }
  function getTestExecutions(test){
    var identity=testIdentity(test);
    var executions=[];
    for(var r=visibleRunIndices.length-1;r>=0&&executions.length<20;r--){
      var run=RUNS[visibleRunIndices[r]];
      var match=null;
      var tests=run.tests||[];
      for(var i=0;i<tests.length;i++){
        if(testIdentity(tests[i])===identity){
          match=tests[i];
          break;
        }
      }
      if(!match){
        var failureLists=(run.failed_tests||[]).concat(run.shell_failed_tests||[]);
        var failure=null;
        for(var f=0;f<failureLists.length;f++){
          if(failureLists[f].title===test.title){
            failure=failureLists[f];
            break;
          }
        }
        var flakyMatch=null;
        for(var k=0;k<(run.flaky_tests||[]).length;k++){
          if(run.flaky_tests[k].title===test.title){flakyMatch=run.flaky_tests[k];break;}
        }
        if(failure){
          match={status:'failed',duration_ms:0,retries:0,error:failure.error||''};
        }else if(flakyMatch){
          match={status:'flaky',duration_ms:test.duration_ms||0,retries:Number(flakyMatch.retries!==undefined?flakyMatch.retries:Math.max(0,(flakyMatch.attempts||1)-1))||0};
        }else{
          continue;
        }
      }
      var status=finalStatus(match);
      var error='';
      var failureLists=(run.failed_tests||[]).concat(run.shell_failed_tests||[]);
      for(var m=0;m<failureLists.length;m++){
        if(failureLists[m].title===test.title){
          error=failureLists[m].error||'';
          break;
        }
      }
      executions.push({
        run_id:run.run_id,
        run_url:run.run_url||'',
        timestamp:run.timestamp||'',
        status:status,
        duration_ms:Number(match.duration_ms)||0,
        retries:retryCount(match),
        error:error
      });
    }
    return executions;
  }
  function openTestDetail(test){
    var detail=document.getElementById('test-detail');
    if(!detail){return;}
    var executions=getTestExecutions(test);
    var firstFailure=null,lastSuccess=null,totalRetries=0;
    for(var i=0;i<executions.length;i++){
      var execution=executions[i];
      totalRetries+=execution.retries;
      if(execution.status==='failed'){
        if(!firstFailure||execution.timestamp<firstFailure){firstFailure=execution.timestamp;}
      }
      if(execution.status==='passed'||execution.status==='flaky'){
        if(!lastSuccess){lastSuccess=execution.timestamp;}
      }
    }
    var latest=executions[0]||null;
    var timeline='';
    for(var i=executions.length-1;i>=0;i--){
      var execution=executions[i];
      var statusClass=execution.status==='passed'?'test-timeline-passed'
        :(execution.status==='failed'?'test-timeline-failed'
        :(execution.status==='flaky'?'test-timeline-flaky':'test-timeline-skipped'));
      var label=esc((execution.timestamp||'').replace('T',' ').slice(0,16)+' — '+execution.status+' — Run #'+execution.run_id);
      timeline+=execution.run_url
        ?'<a class="'+statusClass+'" href="'+esc(execution.run_url)+'" target="_blank" rel="noopener" title="'+label+'"></a>'
        :'<span class="'+statusClass+'" title="'+label+'"></span>';
    }
    var failureRows='';
    for(var i=0;i<executions.length;i++){
      var execution=executions[i];
      if(execution.status==='failed'){
        failureRows+='<tr><td>'+esc(execution.timestamp.replace('T',' ').slice(0,16))+'</td>'
          +'<td>'+esc(execution.run_id)+'</td>'
          +'<td>'+esc(execution.error||'No failure message provided.')+'</td>'
          +(execution.run_url?'<td><a href="'+esc(execution.run_url)+'" target="_blank" rel="noopener">Open run ↗</a></td>':'<td>&mdash;</td>')+'</tr>';
      }
    }
    if(!failureRows){failureRows='<tr><td colspan="4">No failure messages in the last 20 executions.</td></tr>';}
    var executionRows='';
    for(var i=0;i<executions.length;i++){
      var execution=executions[i];
      executionRows+='<tr><td>'+esc(execution.timestamp.replace('T',' ').slice(0,16))+'</td>'
        +(execution.run_url?'<td><a href="'+esc(execution.run_url)+'" target="_blank" rel="noopener">#'+esc(execution.run_id)+' ↗</a></td>':'<td>#'+esc(execution.run_id)+'</td>')
        +'<td>'+esc(execution.status)+'</td><td>'+fmtTestDur(execution.duration_ms)+'</td><td>'+execution.retries+'</td></tr>';
    }
    if(!executionRows){executionRows='<tr><td colspan="5">No individual executions were saved.</td></tr>';}
    detail.innerHTML='<div class="test-detail">'
      +'<div class="test-detail-header"><div><div class="section-lbl">Test detail</div><div class="test-detail-title">'+esc(test.title||'unnamed')+'</div></div>'
      +'<button type="button" class="test-detail-close" aria-label="Close test detail">Close</button></div>'
      +'<div class="test-detail-summary">'
      +'<div class="test-detail-summary-item"><strong>'+esc(firstFailure?(firstFailure.replace('T',' ').slice(0,16)+' UTC'):'&mdash;')+'</strong><span>First failure date</span></div>'
      +'<div class="test-detail-summary-item"><strong>'+esc(lastSuccess?(lastSuccess.replace('T',' ').slice(0,16)+' UTC'):'&mdash;')+'</strong><span>Last successful execution</span></div>'
      +'<div class="test-detail-summary-item"><strong>'+totalRetries+'</strong><span>Retry count (last 20)</span></div>'
      +'</div>'
      +'<div class="section-lbl">Pass/fail timeline</div><div class="test-timeline" aria-label="Pass/fail timeline">'+timeline+'</div>'
      +'<div class="section-lbl">Last 20 executions</div><div class="table-scroll"><table class="test-detail-table"><thead><tr><th>Timestamp</th><th>GitHub Actions run</th><th>Status</th><th>Execution duration</th><th>Retry count</th></tr></thead><tbody>'+executionRows+'</tbody></table></div>'
      +'<div class="section-lbl">Failure messages</div><div class="table-scroll"><table class="test-detail-table"><thead><tr><th>Timestamp</th><th>Run</th><th>Failure message</th><th>Link</th></tr></thead><tbody>'+failureRows+'</tbody></table></div>'
      +'</div>';
    detail.querySelector('.test-detail-close').addEventListener('click',function(){detail.innerHTML='';});
    detail.scrollIntoView({behavior:'smooth',block:'nearest'});
  }
  function runRetryCount(run){
    if(typeof run.retry_count==='number'){return run.retry_count;}
    var tests=run.tests||[];
    if(tests.some(function(test){return Object.prototype.hasOwnProperty.call(test,'retries');})){
      return tests.reduce(function(total,test){return total+retryCount(test);},0);
    }
    return (run.flaky_tests||[]).reduce(function(total,test){
      return total+Number(test.retries!==undefined?test.retries:Math.max(0,(test.attempts||1)-1));
    },0);
  }
  function sourceLabel(test){
    return test.source_file||(['JUnit','NUnit','xUnit','VSTest'].includes(test.source)?'Additional':test.source||'');
  }
  function changeValue(test){
    return test.change==='new'?'new':(test.change==='changed'?'changed':'unchanged');
  }
  function changeLabel(value){
    return value==='new'?'New':(value==='changed'?'Changed':'Unchanged');
  }
  function checkboxFilter(className,values){
    var title=className==='test-filter-source'?'Filter sources':(className==='test-filter-status'?'Filter statuses':'Filter changes');
    return '<details class="column-filter"><summary>'+title+'</summary>'
      +'<div class="column-filter-options">'+values.map(function(value){
        var saved=savedPrefs[className];
        var checked=Array.isArray(saved)?saved.indexOf(value)!==-1:true;
        return '<label><input type="checkbox" class="'+className+'" value="'+esc(value)+'"'+(checked?' checked':'')+'>'+esc(className==='test-filter-change'?changeLabel(value):value)+'</label>';
      }).join('')+'</div></details>';
  }
  function durationAtPercentile(durations,percentile){
    return durations[Math.max(0,Math.ceil(durations.length*percentile)-1)];
  }
  function timeFilter(tests){
    var durations=tests.map(function(test){return Number(test.duration_ms)||0;})
      .filter(function(duration){return duration>0;}).sort(function(a,b){return a-b;});
    var hasUntimed=tests.some(function(test){return !(Number(test.duration_ms)>0);});
    var options=[{value:'all',label:'Any time'}];
    timeThresholds={};
    if(durations.length){
      options.push({value:'timed',label:'Has timing data'});
      timeThresholds.fastest25=durationAtPercentile(durations,.25);
      timeThresholds.median=durationAtPercentile(durations,.5);
      timeThresholds.slowest25=durationAtPercentile(durations,.75);
      timeThresholds.slowest10=durationAtPercentile(durations,.9);
      options.push({value:'fastest25',label:'Fastest 25% (≤ '+fmtTestDur(timeThresholds.fastest25)+')'});
      options.push({value:'median',label:'At least median (≥ '+fmtTestDur(timeThresholds.median)+')'});
      options.push({value:'slowest25',label:'Slowest 25% (≥ '+fmtTestDur(timeThresholds.slowest25)+')'});
      options.push({value:'slowest10',label:'Slowest 10% (≥ '+fmtTestDur(timeThresholds.slowest10)+')'});
    }
    if(hasUntimed){options.push({value:'untimed',label:'No timing data'});}
    var selected=savedPrefs.timeFilter||'all';
    return '<select class="column-filter-time" id="test-time-filter" aria-label="Filter by execution time">'
      +options.map(function(option){
        return '<option value="'+option.value+'"'+(option.value===selected?' selected':'')+'>'+esc(option.label)+'</option>';
      }).join('')+'</select>';
  }
  function checkedValues(className){
    var inputs=testsBox.querySelectorAll('.'+className),values=[];
    for(var i=0;i<inputs.length;i++){if(inputs[i].checked){values.push(inputs[i].value);}}
    return values;
  }
  function applyTestFilters(resetPage){
    var name=(document.getElementById('test-name-filter').value||'').trim().toLowerCase();
    var sources=checkedValues('test-filter-source');
    var statuses=checkedValues('test-filter-status');
    var changes=checkedValues('test-filter-change');
    var timeFilterValue=document.getElementById('test-time-filter').value||'all';
    currentTests=allTests.filter(function(test){
      var duration=Number(test.duration_ms)||0;
      var matchesTime=timeFilterValue==='all'
        ||(timeFilterValue==='timed'&&duration>0)
        ||(timeFilterValue==='untimed'&&duration<=0)
        ||(timeFilterValue==='fastest25'&&duration>0&&duration<=timeThresholds.fastest25)
        ||(timeFilterValue==='median'&&duration>=timeThresholds.median)
        ||(timeFilterValue==='slowest25'&&duration>=timeThresholds.slowest25)
        ||(timeFilterValue==='slowest10'&&duration>=timeThresholds.slowest10);
      return (!name||(test.title||'').toLowerCase().indexOf(name)!==-1)
        &&sources.indexOf(sourceLabel(test))!==-1
        &&statuses.indexOf(finalStatus(test))!==-1
        &&changes.indexOf(changeValue(test))!==-1
        &&matchesTime;
    }).sort(function(a,b){return compareTestValues(a,b,sortColumn);});
    if(resetPage!==false){currentPage=0;}
    renderTestPage();
  }
  function changeRank(test){
    return test.change==='new'?0:(test.change==='changed'?1:2);
  }
  function compareTestValues(a,b,column){
    var left,right;
    if(column==='priority'){
      left=statusRank(a.status||'unknown');
      right=statusRank(b.status||'unknown');
      if(left!==right){return left-right;}
      left=changeRank(a);
      right=changeRank(b);
      if(left!==right){return left-right;}
      return (a.title||'').localeCompare(b.title||'');
    }
    if(column==='title'){
      left=a.title||'';
      right=b.title||'';
    }else if(column==='source'){
      left=sourceLabel(a);
      right=sourceLabel(b);
    }else if(column==='status'){
      left=statusRank(finalStatus(a));
      right=statusRank(finalStatus(b));
    }else if(column==='duration'){
      left=Number(a.duration_ms)||0;
      right=Number(b.duration_ms)||0;
    }else{
      left=changeRank(a);
      right=changeRank(b);
    }
    if(left<right){return -sortDirection;}
    if(left>right){return sortDirection;}
    return (a.title||'').localeCompare(b.title||'');
  }
  function updateSortHeaders(){
    var headers=document.querySelectorAll('.all-tests th');
    for(var i=0;i<headers.length;i++){
      var button=headers[i].querySelector('button');
      if(!button){continue;}
      var column=button.getAttribute('data-sort');
      var label=button.getAttribute('data-label');
      var active=column===sortColumn;
      button.textContent=label+(active?(sortDirection===1?' ↑':' ↓'):'');
      button.setAttribute('aria-label','Sort by '+label+(active?(sortDirection===1?' ascending':' descending'):''));
      headers[i].setAttribute('aria-sort',active?(sortDirection===1?'ascending':'descending'):'none');
    }
  }
  function renderTestPage(){
    var pageCount=Math.max(1,Math.ceil(currentTests.length/testsPerPage));
    currentPage=Math.min(Math.max(0,currentPage),pageCount-1);
    var start=currentPage*testsPerPage,end=Math.min(start+testsPerPage,currentTests.length),rows='';
    for(var i=start;i<end;i++){
      var test=currentTests[i],title=test.title||'',status=finalStatus(test);
      var statusClass={passed:'status-passed',failed:'status-failed',flaky:'status-flaky',skipped:'status-skipped'}[status]||'';
      var change='—';
      if(test.change==='new'){
        change='<span class="change-badge change-new">New</span>';
      }else if(test.change==='changed'){
        change='<span class="change-badge change-updated">'+esc(test.previous_status||'unknown')+' &rarr; '+esc(status)+'</span>';
      }
      var passedAfterRetryLabel=test.source==='Playwright'?(passedAfterRetry(test)?'Yes':'No'):'—';
      rows+='<tr data-test-title="'+esc(title)+'" data-test-status="'+esc(status)+'"><td title="'+esc(title)+'">'
        +'<button type="button" class="test-detail-trigger" data-test-index="'+i+'" aria-label="Open details for '+esc(title)+'">'+esc(clip(shortName(title),90))+'</button></td>'
        +'<td>'+esc(sourceLabel(test))+'</td><td><span class="status-badge '+statusClass+'">'+esc(status)+'</span></td>'
        +'<td>'+passedAfterRetryLabel+'</td><td>'+retryCount(test)+'</td>'
        +'<td>'+fmtTestDur(test.duration_ms)+'</td><td>'+change+'</td></tr>';
    }
    if(!currentTests.length){rows='<tr><td class="test-filter-empty" colspan="7">No tests match these filters.</td></tr>';}
    document.getElementById('all-tests-body').innerHTML=rows;
    var detailTriggers=document.querySelectorAll('.test-detail-trigger');
    for(var t=0;t<detailTriggers.length;t++){
      detailTriggers[t].addEventListener('click',function(){
        var testIndex=Number(this.getAttribute('data-test-index'));
        if(currentTests[testIndex]){openTestDetail(currentTests[testIndex]);}
      });
    }
    document.getElementById('test-page-range').textContent='Showing '+(currentTests.length?start+1:0)+'-'+end+' of '+currentTests.length+' tests';
    document.getElementById('test-page-count').textContent='Page '+(currentPage+1)+' of '+pageCount;
    document.getElementById('test-page-prev').disabled=currentPage===0;
    document.getElementById('test-page-next').disabled=currentPage>=pageCount-1;
    var aggPicker=document.getElementById('agg-picker');
    if(aggPicker){aggPicker.dispatchEvent(new Event('change'));}
    savePrefs();
  }
  function renderTests(run){
    var tests=run.tests||[];
    allTests=tests.slice();
    currentTests=allTests.slice().sort(function(a,b){return compareTestValues(a,b,sortColumn);});
    var counts={total:0,passed:0,failed:0,flaky:0,retries:0,skipped:0};
    if(tests.length){
      counts.total=tests.length;
      for(var i=0;i<tests.length;i++){
        var status=finalStatus(tests[i]);
        if(Object.prototype.hasOwnProperty.call(counts,status)){counts[status]++;}
        if(passedAfterRetry(tests[i])){counts.flaky++;}
        counts.retries+=retryCount(tests[i]);
      }
    }else{
      counts.total=(run.total||0)+(run.shell_passed||0)+(run.shell_failed||0)+(run.shell_skipped||0);
      counts.passed=(run.passed||0)+(run.flaky_count||0)+(run.shell_passed||0);
      counts.failed=(run.failed||0)+(run.shell_failed||0);
      counts.flaky=run.flaky_count||0;
      counts.retries=runRetryCount(run);
      counts.skipped=(run.skipped||0)+(run.shell_skipped||0);
    }
    var html='<div class="stats-row selected-run-stats" style="margin:.6rem 0">'
      +'<div class="stat-box"><div class="stat-val">'+counts.total+'</div><div class="stat-lbl">Tests</div></div>'
      +'<div class="stat-box"><div class="stat-val">'+counts.passed+'</div><div class="stat-lbl">Passed</div></div>'
      +'<div class="stat-box stat-fail"><div class="stat-val">'+counts.failed+'</div><div class="stat-lbl">Failed</div></div>'
      +'<div class="stat-box stat-flaky"><div class="stat-val">'+counts.flaky+'</div><div class="stat-lbl">Passed after retry</div></div>'
      +'<div class="stat-box"><div class="stat-val">'+counts.retries+'</div><div class="stat-lbl">Retries</div></div>'
      +'<div class="stat-box"><div class="stat-val">'+counts.skipped+'</div><div class="stat-lbl">Skipped</div></div>'
      +'</div>';
    if(run.test_comparison_available){
      html+='<p class="comparison-note">Compared with run #'+esc(run.compared_with_run_id)+'. '
        +'<span class="change-badge change-new">New</span> test, '
        +'<span class="change-badge change-updated">previous status &rarr; current status</span>.</p>';
    }else{
      html+='<p class="comparison-note">No previous test-level data is available for comparison.</p>';
    }
    if(!tests.length){
      html+='<p class="comparison-note">Individual test results were not saved for this run; showing available aggregate counts.</p>';
      testsBox.innerHTML=html;
      return;
    }
    var sources=Array.from(new Set(tests.map(sourceLabel))).sort(function(a,b){return a.localeCompare(b);});
    var statuses=Array.from(new Set(tests.map(finalStatus))).sort();
    var changes=Array.from(new Set(tests.map(changeValue))).sort(function(a,b){return ['new','changed','unchanged'].indexOf(a)-['new','changed','unchanged'].indexOf(b);});
    html+='<div class="test-pagination" aria-label="Test table pagination">'
      +'<button type="button" id="test-page-prev" aria-label="Previous test page">Prev</button>'
      +'<span id="test-page-range"></span><span id="test-page-count"></span>'
      +'<button type="button" id="test-page-next" aria-label="Next test page">Next</button>'
      +'<label for="test-page-size">Tests per page</label><select id="test-page-size" aria-label="Tests per page">'
      +'<option value="30" selected>30</option><option value="50">50</option><option value="100">100</option></select></div>'
      +'<div class="table-scroll"><table class="all-tests"><thead><tr>'
      +'<th aria-sort="none"><button type="button" data-sort="title" data-label="Test" aria-label="Sort by Test">Test</button>'
      +'<input type="search" class="column-filter-name" id="test-name-filter" value="'+esc(savedPrefs.testName||'')+'" placeholder="Search"></th>'
      +'<th aria-sort="none"><button type="button" data-sort="source" data-label="Source" aria-label="Sort by Source">Source</button>'
      +checkboxFilter('test-filter-source',sources)+'</th>'
      +'<th aria-sort="none"><button type="button" data-sort="status" data-label="Final status" aria-label="Sort by Final status">Final status</button>'
      +checkboxFilter('test-filter-status',statuses)+'</th>'
      +'<th>Passed after retry</th><th>Retries</th>'
      +'<th aria-sort="none"><button type="button" data-sort="duration" data-label="Execution time" aria-label="Sort by Execution time">Execution time</button>'
      +timeFilter(tests)+'</th>'
      +'<th aria-sort="none"><button type="button" data-sort="change" data-label="Change" aria-label="Sort by Change">Change</button>'
      +checkboxFilter('test-filter-change',changes)+'</th>'
      +'</tr></thead><tbody id="all-tests-body"></tbody></table></div>';
    testsBox.innerHTML=html;
    document.getElementById('test-page-size').value=String(testsPerPage);
    var filterInputs=testsBox.querySelectorAll('.test-filter-source, .test-filter-status, .test-filter-change');
    for(var i=0;i<filterInputs.length;i++){filterInputs[i].addEventListener('change',applyTestFilters);}
    document.getElementById('test-name-filter').addEventListener('input',applyTestFilters);
    document.getElementById('test-time-filter').addEventListener('change',applyTestFilters);
    var sortButtons=testsBox.querySelectorAll('.all-tests th button');
    for(var i=0;i<sortButtons.length;i++){
      sortButtons[i].addEventListener('click',function(){
        var column=this.getAttribute('data-sort');
        sortDirection=column===sortColumn?-sortDirection:1;
        sortColumn=column;
        updateSortHeaders();
        applyTestFilters();
      });
    }
    updateSortHeaders();
    document.getElementById('test-page-prev').addEventListener('click',function(){currentPage--;renderTestPage();});
    document.getElementById('test-page-next').addEventListener('click',function(){currentPage++;renderTestPage();});
    document.getElementById('test-page-size').addEventListener('change',function(){
      testsPerPage=parseInt(this.value,10);
      currentPage=0;
      renderTestPage();
    });
    applyTestFilters(false);
  }
  function renderRun(run){
    if(!run){testsBox.innerHTML='';detail.innerHTML='';return;}
    renderTests(run);
    var ts=(run.timestamp||'').replace('T',' ').slice(0,16)+' UTC';
    var html='<div style="display:flex;align-items:center;gap:.75rem;flex-wrap:wrap;padding:.5rem 0 .75rem;border-top:1px solid #e2e8f0">'
      +'<strong style="font-size:.875rem">Run #'+esc(run.run_id)+'</strong>'
      +'<span style="font-size:.78rem;color:#64748b">'+esc(ts)+'</span>'
      +'<a href="'+esc(run.run_url)+'" target="_blank" style="font-size:.78rem">View on GitHub ↗</a>'
      +'</div>';
    var failures=(run.failed_tests||[]).concat(run.shell_failed_tests||[]);
    if(failures.length){
      html+='<div class="section-lbl">Failure details ('+failures.length+')</div>'
        +'<div class="table-scroll"><table><tr><th>Source</th><th>Test</th><th>Failure</th></tr>';
      for(var i=0;i<failures.length;i++){
        var failure=failures[i],failureTitle=failure.title||'unnamed';
        html+='<tr><td>'+esc(failure.source_file||failure.source||'Test results')+'</td>'
          +'<td title="'+esc(failureTitle)+'">'+esc(clip(shortName(failureTitle),70))+'</td>'
          +'<td>'+esc(failure.error||'No failure message provided.')+'</td></tr>';
      }
      html+='</table></div>';
    }else if((run.failed||0)+(run.shell_failed||0)>0){
      html+='<p class="comparison-note">'+((run.failed||0)+(run.shell_failed||0))+' failure(s); individual test details were not saved for this run.</p>';
    }
    // Flaky tests
    var flaky=run.flaky_tests||[];
    html+='<div class="section-lbl">Flaky tests ('+flaky.length+')</div>';
    if(!flaky.length && run.flaky_count>0){
      html+='<p class="comparison-note">'+run.flaky_count+' flaky test(s); individual test details were not saved for this run.</p>';
    }else if(!flaky.length){html+='<p style="font-size:.8rem;color:#15803d;margin:.2rem 0">None ✓</p>';}
    else{html+='<ul class="flaky-list">';
      for(var i=0;i<flaky.length;i++){var t=flaky[i],s=clip(shortName(t.title),70);
        html+='<li title="'+esc(t.title)+'">'+esc(s)+' <strong>('+Number(t.retries!==undefined?t.retries:Math.max(0,(t.attempts||1)-1))+' retries)</strong></li>';}
      html+='</ul>';}
    detail.innerHTML=html;
  }
  function runLabel(run){
    var ts=(run.timestamp||'').slice(0,16).replace('T',' ');
    var failed=(run.failed||0)+(run.shell_failed||0);
    var status=failed===0?'✓':'✗';
    var label=status+' Run #'+run.run_id+' — '+ts+'Z'
      +' — '+((run.passed||0)+(run.flaky_count||0)+(run.shell_passed||0))+'p / '+failed+'f'
      +' / '+(run.passed_after_retry_count||run.flaky_count||0)+' passed after retry'
      +' / '+runRetryCount(run)+' retries'
      +' / '+((run.skipped||0)+(run.shell_skipped||0))+' skipped';
    if(branchPicker.value==='all'){label+=' — '+(run.branch||'Unknown branch');}
    return label;
  }
  function updateOverview(){
    var stats=FILTER_STATS[branchPicker.value]||FILTER_STATS.all;
    var heading=document.getElementById('overview-title');
    var rate=document.getElementById('overview-pass-rate');
    heading.textContent='Last 30 days — '+stats.run_count+' run(s)';
    rate.textContent=stats.pass_rate+'% pass rate';
    rate.className='rate-pill '+(stats.pass_rate>=90?'rate-ok':(stats.pass_rate>=70?'rate-warn':'rate-bad'));
    document.getElementById('overview-avg-total').textContent=stats.avg_total;
    document.getElementById('overview-avg-passed').textContent=stats.avg_passed;
    document.getElementById('overview-avg-failed').textContent=stats.avg_failed;
    document.getElementById('overview-avg-flaky').textContent=stats.avg_flaky;
    document.getElementById('overview-avg-retries').textContent=stats.avg_retries;
    var durationStats=document.getElementById('overview-duration-stats');
    durationStats.style.display=stats.max_duration_ms?'grid':'none';
    var durationLabel=document.getElementById('overview-duration-label');
    if(durationLabel){durationLabel.style.display=stats.max_duration_ms?'':'none';}
    document.getElementById('overview-avg-duration').textContent=fmtDur(stats.avg_duration_ms);
    document.getElementById('overview-min-duration').textContent=fmtDur(stats.min_duration_ms);
    document.getElementById('overview-max-duration').textContent=fmtDur(stats.max_duration_ms);
    var selectedRuns=visibleRunIndices.map(function(index){return RUNS[index];});
    var maxTotal=Math.max.apply(null,selectedRuns.map(function(run){
      return (run.total||0)+(run.shell_passed||0)+(run.shell_failed||0)+(run.shell_skipped||0);
    }).concat([1]));
    var bars=[];
    for(var i=selectedRuns.length-1;i>=0;i--){
      var run=selectedRuns[i];
      var pwFailed=run.failed||0,pwFlaky=run.flaky_count||0,shFailed=run.shell_failed||0;
      var issues=pwFailed+pwFlaky+shFailed;
      var runTotal=(run.total||0)+(run.shell_passed||0)+(run.shell_failed||0)+(run.shell_skipped||0);
      var height=Math.max(8,Math.round(60*runTotal/maxTotal));
      var color;
      if(isAllFailedRun(run)){color='#1e293b';}
      else if(issues===0){color='#22c55e';}
      else if(pwFailed>0&&pwFlaky>0){
        var redPct=Math.round(100*pwFailed/issues*10)/10;
        color='linear-gradient(to top,#eab308 0%,#eab308 '+(100-redPct)+'%,#ef4444 '+(100-redPct)+'%)';
      }else if(pwFailed>0||shFailed>0){color='#ef4444';}
      else{color='#eab308';}
      var duration=run.duration_ms>0?' — ⏱ '+fmtDur(run.duration_ms):'';
      var label='Run #'+run.run_id+duration+' — '
        +((run.passed||0)+(run.shell_passed||0))+' passed / '+(pwFailed+shFailed)+' failed / '
        +(run.passed_after_retry_count||pwFlaky)+' passed after retry / '
        +runRetryCount(run)+' retries / '+((run.skipped||0)+(run.shell_skipped||0))+' skipped'
        +' — '+(run.branch||'Unknown branch');
      bars.push('<a href="'+esc(run.run_url||'#')+'" target="_blank" title="'+esc(label)+'">'
        +'<div class="bar" style="height:'+height+'px;background:'+color+'"></div></a>');
    }
    document.getElementById('run-sparkline').innerHTML=bars.join('');
  }
  function isAllFailedRun(run){
    var total=(run.total||0)+(run.shell_passed||0)+(run.shell_failed||0)+(run.shell_skipped||0);
    var skipped=(run.skipped||0)+(run.shell_skipped||0);
    var executed=Math.max(0,total-skipped);
    var failed=(run.failed||0)+(run.shell_failed||0);
    return executed>0&&failed>=executed;
  }
  function setBranch(value,persist){
    if(!FILTER_STATS[value]){value='all';}
    branchPicker.value=value;
    visibleRunIndices=[];
    for(var i=0;i<RUNS.length;i++){
      var runBranch=typeof RUNS[i].branch==='string'?RUNS[i].branch:'';
      if(value==='all'
        ||(value==='unknown'&&!runBranch)
        ||(value.indexOf('branch:')===0&&runBranch===value.slice(7))){
        visibleRunIndices.push(i);
      }
    }
    updateOverview();
    runPage=0;
    renderRunPage(0,visibleRunIndices.length?visibleRunIndices[visibleRunIndices.length-1]:-1);
    if(window.refreshBranchTrends){window.refreshBranchTrends(FILTER_STATS[value].agg);}
    if(persist){savePrefs();}
  }
  function renderRunPage(page,selectedIndex){
    var pageCount=Math.max(1,Math.ceil(visibleRunIndices.length/runPageSize));
    runPage=Math.max(0,Math.min(page,pageCount-1));
    var newestPosition=visibleRunIndices.length-1-runPage*runPageSize;
    var oldestPosition=Math.max(0,newestPosition-runPageSize+1);
    var options=[];
    for(var i=newestPosition;i>=oldestPosition;i--){
      var runIndex=visibleRunIndices[i];
      options.push('<option value="'+runIndex+'">'+esc(runLabel(RUNS[runIndex]))+'</option>');
    }
    picker.innerHTML=options.join('');
    if(oldestPosition<0){selectedIndex=-1;}
    else if(visibleRunIndices.indexOf(selectedIndex)<oldestPosition
      ||visibleRunIndices.indexOf(selectedIndex)>newestPosition){
      selectedIndex=visibleRunIndices[newestPosition];
    }
    picker.value=String(selectedIndex);
    var firstRun=runPage*runPageSize+1;
    var lastRun=firstRun+Math.max(0,newestPosition-oldestPosition);
    runPageRange.textContent='Runs '+firstRun+'-'+lastRun+' of '+visibleRunIndices.length+' (newest first)';
    runPagePrev.disabled=runPage===0;
    runPageNext.disabled=runPage>=pageCount-1;
    renderRun(selectedIndex>=0?RUNS[selectedIndex]:null);
  }
  document.getElementById('reset-dashboard-preferences').addEventListener('click',function(){
    document.cookie=cookieName+'=; Path='+cookiePath+'; Max-Age=0; SameSite=Lax';
    location.reload();
  });
  document.getElementById('export-runs-json').addEventListener('click',function(){
    var blob=new Blob([JSON.stringify(RUNS_STORE,null,2)],{type:'application/json;charset=utf-8'});
    var url=URL.createObjectURL(blob);
    var link=document.createElement('a');
    link.href=url;
    link.download='runs.json';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
    URL.revokeObjectURL(url);
  });
  picker.addEventListener('change',function(){renderRun(RUNS[parseInt(this.value,10)]);});
  branchPicker.addEventListener('change',function(){setBranch(this.value,true);});
  runPagePrev.addEventListener('click',function(){renderRunPage(runPage-1,-1);});
  runPageNext.addEventListener('click',function(){renderRunPage(runPage+1,-1);});
  window.initializeBranchDashboard=function(){
    setBranch(FILTER_STATS[savedPrefs.branch]?savedPrefs.branch:'all',false);
  };
})();
</script>
''')
        fh.write(f'<div class="card-header"><h2 class="card-title" id="overview-title">Last 30 days &mdash; {len(runs)} run(s)</h2>')
        fh.write(f'<span class="rate-pill {rate_cls}" id="overview-pass-rate">{pass_rate}% pass rate</span></div>\n')
        fh.write('<div class="section-lbl">Test results (all configured sources)</div>\n')
        fh.write('<div class="stats-row">\n')
        fh.write(f'<div class="stat-box"><div class="stat-val" id="overview-avg-total">{avg_total}</div><div class="stat-lbl">Avg tests/run</div></div>\n')
        fh.write(f'<div class="stat-box"><div class="stat-val" id="overview-avg-passed">{avg_passed}</div><div class="stat-lbl">Avg passed/run</div></div>\n')
        fh.write(f'<div class="stat-box stat-fail"><div class="stat-val" id="overview-avg-failed">{avg_failed:g}</div><div class="stat-lbl">Avg failures/run</div></div>\n')
        fh.write(f'<div class="stat-box stat-flaky"><div class="stat-val" id="overview-avg-flaky">{avg_flaky:g}</div><div class="stat-lbl">Avg passed after retry/run</div></div>\n')
        fh.write(f'<div class="stat-box"><div class="stat-val" id="overview-avg-retries">{avg_retries:g}</div><div class="stat-lbl">Avg retries/run</div></div>\n')
        fh.write('</div>\n')
        if any(durations):
            fh.write('<div class="section-lbl" id="overview-duration-label">Execution time</div>\n')
            fh.write('<div class="stats-row duration-stats" id="overview-duration-stats">\n')
            fh.write(f'<div class="stat-box"><div class="stat-val" id="overview-avg-duration">{fmt_dur(avg_dur_ms)}</div><div class="stat-lbl">Avg run time</div></div>\n')
            fh.write(f'<div class="stat-box"><div class="stat-val" id="overview-min-duration">{fmt_dur(min_dur_ms)}</div><div class="stat-lbl">Fastest run</div></div>\n')
            fh.write(f'<div class="stat-box"><div class="stat-val" id="overview-max-duration">{fmt_dur(max_dur_ms)}</div><div class="stat-lbl">Slowest run</div></div>\n')
            fh.write('</div>\n')
        else:
            fh.write('<div class="stats-row duration-stats" id="overview-duration-stats" style="display:none">\n')
            fh.write('<div class="stat-box"><div class="stat-val" id="overview-avg-duration">—</div><div class="stat-lbl">Avg run time</div></div>\n')
            fh.write('<div class="stat-box"><div class="stat-val" id="overview-min-duration">—</div><div class="stat-lbl">Fastest run</div></div>\n')
            fh.write('<div class="stat-box"><div class="stat-val" id="overview-max-duration">—</div><div class="stat-lbl">Slowest run</div></div>\n')
            fh.write('</div>\n')
        fh.write('<div class="spark-label">Tests per run (all configured sources) — color shows pass/fail</div>\n')
        fh.write('<div class="sparkline" id="run-sparkline" title="Total tests per run (newest → oldest)"></div>\n')

        # Aggregate test trends picker
        fh.write('<div class="section-lbl">Test trends (last 30 days)</div>\n')
        fh.write('<select id="agg-picker" style="font-size:.8rem;padding:.35rem .6rem;border:1px solid #e2e8f0;border-radius:.4rem;background:#fff;color:#374151;width:100%;max-width:42rem;cursor:pointer">\n')
        fh.write('<option value="top">Top failing tests</option>\n')
        fh.write('<option value="flaky">Flaky tests</option>\n')
        fh.write('<option value="longest">Longest tests</option>\n')
        fh.write('<option value="retried">Most retried</option>\n')
        fh.write('</select>\n')
        fh.write('<div id="agg-detail" style="margin-top:.5rem"></div>\n')
        _agg_json = json.dumps(filter_stats["all"]["agg"]).replace('</', '<\\/')
        fh.write(f'<script>var AGG={_agg_json};</script>\n')
        fh.write('''\
<script>
(function(){
  var sel=document.getElementById('agg-picker');
  var box=document.getElementById('agg-detail');
  var cookiePath=location.pathname.slice(0,location.pathname.lastIndexOf('/')+1)||'/';
  var cookieName='testStatsPrefs_'+cookiePath.replace(/[^a-zA-Z0-9]/g,'_');
  var prefs={};
  var prefix=cookieName+'=',cookies=document.cookie.split(';');
  for(var i=0;i<cookies.length;i++){
    var item=cookies[i].trim();
    if(item.indexOf(prefix)===0){
      try{prefs=JSON.parse(decodeURIComponent(item.slice(prefix.length)))||{};}catch(error){prefs={};}
      break;
    }
  }
  if(['top','flaky','longest','retried'].indexOf(prefs.aggPicker)!==-1){sel.value=prefs.aggPicker;}
  function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
  function fmtDur(ms){if(!ms)return '&mdash;';if(ms<1000)return Math.round(ms)+' ms';var s=ms/1000;if(s<60)return s.toFixed(0)+'s';return Math.floor(s/60)+'m '+Math.floor(s%60)+'s';}
  function shortName(t){var p=t.split('>').map(function(x){return x.trim();}).filter(Boolean);return p.length>=2?p.slice(-2).join(' › '):(p[p.length-1]||t);}
  function clip(s,n){return s.length>n?s.slice(-n):s;}
  function highlightTests(v){
    var key=v==='longest'?'slow':v, selected={};
    var data=AGG[key]||[];
    for(var i=0;i<data.length;i++){selected[data[i][0]]=true;}
    var rows=document.querySelectorAll('#all-tests-body tr');
    for(var i=0;i<rows.length;i++){
      rows[i].classList.toggle('test-trend-match',!!selected[rows[i].getAttribute('data-test-title')]);
    }
  }
  function render(v){
    var html='',d;
    if(v==='top'){
      d=AGG.top;
      if(!d.length){html='<p style="font-size:.8rem;color:#94a3b8;margin:.25rem 0">No failures recorded.</p>';}
      else{html='<div class="table-scroll"><table><tr><th>Test</th><th style="width:4rem">Fails</th></tr>';
        for(var i=0;i<d.length;i++){var t=d[i],s=clip(shortName(t[0]),70);
          html+='<tr><td title="'+esc(t[0])+'">'+esc(s)+'</td><td>'+t[1]+'</td></tr>';}
        html+='</table></div>';}
    }else if(v==='flaky'){
      d=AGG.flaky;
      if(!d.length){html='<p style="font-size:.8rem;color:#15803d;margin:.25rem 0">No flaky tests ✓</p>';}
      else{html='<ul class="flaky-list">';
        for(var i=0;i<d.length;i++){var t=d[i],s=clip(shortName(t[0]),70);
          html+='<li title="'+esc(t[0])+'">'+esc(s)+' <strong>('+t[1]+')</strong></li>';}
        html+='</ul>';}
    }else if(v==='longest'){
      d=AGG.slow;
      if(!d.length){html='<p style="font-size:.8rem;color:#94a3b8;margin:.25rem 0">No duration data.</p>';}
      else{html='<div class="table-scroll"><table><tr><th>Test</th><th style="width:5rem;color:#6b7280">Max time</th></tr>';
        for(var i=0;i<d.length;i++){var t=d[i],s=clip(shortName(t[0]),65);
          html+='<tr><td title="'+esc(t[0])+'">'+esc(s)+'</td><td style="color:#6b7280">'+fmtDur(t[1])+'</td></tr>';}
        html+='</table></div>';}
    }else if(v==='retried'){
      d=AGG.retried;
      if(!d.length){html='<p style="font-size:.8rem;color:#15803d;margin:.25rem 0">No retries recorded ✓</p>';}
      else{html='<div class="table-scroll"><table><tr><th>Test</th><th style="width:5.5rem">Retries</th></tr>';
        for(var i=0;i<d.length;i++){var t=d[i],s=clip(shortName(t[0]),65);
          html+='<tr><td title="'+esc(t[0])+'">'+esc(s)+'</td><td style="color:#d97706">'+t[1]+'</td></tr>';}
        html+='</table></div>';}
    }
    box.innerHTML=html;
    highlightTests(v);
  }
  window.refreshBranchTrends=function(agg){
    AGG=agg;
    render(sel.value);
  };
  sel.addEventListener('change',function(){
    render(this.value);
    var latestPrefs={},latestCookies=document.cookie.split(';');
    for(var i=0;i<latestCookies.length;i++){
      var item=latestCookies[i].trim();
      if(item.indexOf(prefix)===0){
        try{latestPrefs=JSON.parse(decodeURIComponent(item.slice(prefix.length)))||{};}catch(error){latestPrefs={};}
        break;
      }
    }
    latestPrefs.aggPicker=this.value;
    document.cookie=cookieName+'='+encodeURIComponent(JSON.stringify(latestPrefs))+'; Path='+cookiePath+'; Max-Age=31536000; SameSite=Lax';
  });
  render(sel.value);
})();
</script>
''')
        fh.write('<script>window.initializeBranchDashboard();</script>\n')

        fh.write('</div>\n')

    fh.write('</div></body></html>\n')

print(f"[dashboard] Written to {dashboard}")
PYEOF
