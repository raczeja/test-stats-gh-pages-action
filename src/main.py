#!/usr/bin/env python3
import datetime as dt
import glob
import html
import json
import os
from pathlib import Path
import sys
import tempfile
import urllib.error
import urllib.request
from urllib.parse import quote, urlsplit
import xml.etree.ElementTree as ET


RUNS_SCHEMA_VERSION = 1


def fail(message):
    print(f"test-stats-gh-pages-action: {message}", file=sys.stderr)
    raise SystemExit(1)


def env(name, default=""):
    return os.environ.get(name, default)


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as out:
        json.dump(value, out, indent=2)
        out.write("\n")
        temp_path = Path(out.name)
    temp_path.replace(path)


def input_paths():
    paths = []
    for line in env("INPUT_RESULT_FILES").splitlines():
        pattern = line.strip()
        if not pattern:
            continue
        matches = sorted(glob.glob(pattern, recursive=True))
        if not matches and not glob.has_magic(pattern):
            candidate = Path(pattern)
            if candidate.is_file():
                matches = [str(candidate)]
        if not matches:
            fail(f"no result files matched {pattern!r}")
        paths.extend(Path(item) for item in matches if Path(item).is_file())
    unique = list(dict.fromkeys(path.resolve() for path in paths))
    if not unique:
        fail("result-files must identify at least one regular file")
    return unique


def parse_junit(path):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        fail(f"cannot parse JUnit XML {path}: {exc}")
    if root.tag not in ("testsuite", "testsuites"):
        fail(f"JUnit XML {path} must have a testsuite or testsuites root element")

    counts = {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky": 0, "duration_ms": 0}
    failures = []
    for case in root.iter("testcase"):
        counts["total"] += 1
        try:
            counts["duration_ms"] += round(float(case.get("time", 0)) * 1000)
        except ValueError:
            fail(f"invalid testcase duration in {path}")
        if case.find("skipped") is not None:
            counts["skipped"] += 1
        elif case.find("failure") is not None or case.find("error") is not None:
            counts["failed"] += 1
            issue = case.find("failure")
            if issue is None:
                issue = case.find("error")
            failures.append({
                "title": f"{case.get('classname', '')} > {case.get('name', 'unnamed')}".strip(" >"),
                "file": case.get("classname", ""),
                "error": ((issue.get("message", "") or issue.text or "")[:300] if issue is not None else ""),
            })
        else:
            counts["passed"] += 1
    return counts, failures, []


def parse_trx(path):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        fail(f"cannot parse VSTest TRX {path}: {exc}")
    if root.tag.rsplit("}", 1)[-1] != "TestRun":
        fail(f"VSTest TRX {path} must have a TestRun root element")

    definitions = {}
    for unit_test in root.iter():
        if unit_test.tag.rsplit("}", 1)[-1] != "UnitTest":
            continue
        test_method = next(
            (element for element in unit_test.iter()
             if element.tag.rsplit("}", 1)[-1] == "TestMethod"),
            None,
        )
        if test_method is not None:
            definitions[unit_test.get("id", "")] = test_method.get("className", "")

    counts = {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky": 0, "duration_ms": 0}
    failures = []
    passed_outcomes = {"Passed", "PassedButRunAborted"}
    failed_outcomes = {"Failed", "Error", "Timeout", "Aborted", "NotRunnable", "Disconnected"}
    skipped_outcomes = {"NotExecuted", "Inconclusive", "Warning"}

    for result in root.iter():
        if result.tag.rsplit("}", 1)[-1] != "UnitTestResult":
            continue
        counts["total"] += 1
        duration = result.get("duration", "")
        try:
            hours, minutes, seconds = duration.split(":")
            counts["duration_ms"] += round(
                (int(hours) * 3600 + int(minutes) * 60 + float(seconds)) * 1000
            )
        except (ValueError, TypeError):
            if duration:
                fail(f"invalid VSTest duration in {path}: {duration!r}")

        outcome = result.get("outcome", "")
        if outcome in passed_outcomes:
            counts["passed"] += 1
        elif outcome in failed_outcomes:
            counts["failed"] += 1
            error = next(
                (
                    element.text or ""
                    for element in result.iter()
                    if element.tag.rsplit("}", 1)[-1] == "Message" and element.text
                ),
                "",
            )
            failures.append({
                "title": result.get("testName", "unnamed"),
                "file": definitions.get(result.get("testId", ""), ""),
                "error": error[:300],
            })
        elif outcome in skipped_outcomes:
            counts["skipped"] += 1
        else:
            fail(f"unsupported VSTest outcome in {path}: {outcome!r}")
    return counts, failures, []


def parse_nunit(path):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        fail(f"cannot parse NUnit XML {path}: {exc}")
    if root.tag.rsplit("}", 1)[-1] not in ("test-run", "test-results"):
        fail(f"NUnit XML {path} must have a test-run or test-results root element")

    counts = {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky": 0, "duration_ms": 0}
    failures = []
    for case in root.iter():
        if case.tag.rsplit("}", 1)[-1] != "test-case":
            continue
        counts["total"] += 1
        try:
            counts["duration_ms"] += round(float(case.get("duration", case.get("time", 0)) or 0) * 1000)
        except ValueError:
            fail(f"invalid NUnit testcase duration in {path}")

        outcome = (case.get("result") or "").lower()
        success = (case.get("success") or "").lower()
        executed = (case.get("executed") or "").lower()
        if outcome in ("passed", "pass", "success") or success == "true":
            counts["passed"] += 1
        elif outcome in ("failed", "failure", "error", "cancelled", "notrunnable", "invalid") or success == "false" and executed != "false":
            counts["failed"] += 1
            message = next(
                (
                    element.text or ""
                    for element in case.iter()
                    if element.tag.rsplit("}", 1)[-1] == "message" and element.text
                ),
                "",
            )
            failures.append({
                "title": case.get("fullname") or case.get("name", "unnamed"),
                "file": case.get("class") or case.get("classname", ""),
                "error": message[:300],
            })
        elif outcome in ("skipped", "ignored", "inconclusive", "warning", "notrun", "notexecuted") or executed == "false":
            counts["skipped"] += 1
        else:
            fail(f"unsupported NUnit result in {path}: {case.get('result')!r}")
    return counts, failures, []


def parse_xunit(path):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        fail(f"cannot parse xUnit XML {path}: {exc}")
    if root.tag.rsplit("}", 1)[-1] != "assemblies":
        fail(f"xUnit XML {path} must have an assemblies root element")

    counts = {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky": 0, "duration_ms": 0}
    failures = []
    for assembly in root.iter():
        if assembly.tag.rsplit("}", 1)[-1] == "assembly":
            for case in assembly.iter():
                if case.tag.rsplit("}", 1)[-1] != "test":
                    continue
                counts["total"] += 1
                try:
                    counts["duration_ms"] += round(float(case.get("time", 0) or 0) * 1000)
                except ValueError:
                    fail(f"invalid xUnit testcase duration in {path}")
                outcome = (case.get("result") or "").lower()
                if outcome in ("pass", "passed"):
                    counts["passed"] += 1
                elif outcome in ("fail", "failed", "error"):
                    counts["failed"] += 1
                    message = next(
                        (
                            element.text or ""
                            for element in case.iter()
                            if element.tag.rsplit("}", 1)[-1] == "message" and element.text
                        ),
                        "",
                    )
                    failures.append({
                        "title": case.get("name", "unnamed"),
                        "file": case.get("type", ""),
                        "error": message[:300],
                    })
                elif outcome in ("skip", "skipped", "notrun"):
                    counts["skipped"] += 1
                else:
                    fail(f"unsupported xUnit result in {path}: {case.get('result')!r}")
    return counts, failures, []


def parse_playwright(path):
    try:
        with path.open(encoding="utf-8") as source:
            data = json.load(source)
    except (json.JSONDecodeError, OSError) as exc:
        fail(f"cannot parse Playwright JSON {path}: {exc}")
    stats = data.get("stats")
    if not isinstance(stats, dict):
        fail(f"Playwright JSON {path} is missing the stats object")

    try:
        expected = int(stats.get("expected", 0))
        unexpected = int(stats.get("unexpected", 0))
        flaky_count = int(stats.get("flaky", 0))
        skipped = int(stats.get("skipped", 0))
        duration_ms = int(stats.get("duration", 0))
    except (TypeError, ValueError):
        fail(f"Playwright JSON {path} contains invalid stats values")
    if min(expected, unexpected, flaky_count, skipped, duration_ms) < 0:
        fail(f"Playwright JSON {path} contains negative stats values")
    counts = {
        "total": expected + unexpected + flaky_count + skipped,
        "passed": expected + flaky_count,
        "failed": unexpected,
        "skipped": skipped,
        "flaky": flaky_count,
        "duration_ms": duration_ms,
    }
    failures, flaky = [], []

    def walk(suites, parents=()):
        if not isinstance(suites, list):
            return
        for suite in suites:
            title = suite.get("title", "") if isinstance(suite, dict) else ""
            names = parents + ((title,) if title else ())
            for spec in suite.get("specs", []) if isinstance(suite, dict) else []:
                spec_title = spec.get("title", "")
                full_title = " > ".join(names + ((spec_title,) if spec_title else ()))
                for test in spec.get("tests", []):
                    status = test.get("status", "")
                    record = {
                        "title": full_title,
                        "file": spec.get("file", ""),
                    }
                    if status == "unexpected":
                        errors = [
                            item.get("message") or item.get("value", "")
                            for result in test.get("results", [])
                            for item in result.get("errors", [])
                        ]
                        record["error"] = (errors[0] if errors else "")[:300]
                        failures.append(record)
                    elif status == "flaky":
                        record["attempts"] = len(test.get("results", []))
                        flaky.append(record)
            walk(suite.get("suites", []) if isinstance(suite, dict) else [], names)

    walk(data.get("suites", []))
    return counts, failures, flaky


def parse_result(path, forced_format):
    file_format = forced_format
    if file_format == "auto":
        if path.suffix.lower() in (".xml", ".trx", ".nunit"):
            try:
                root = ET.parse(path).getroot()
            except (ET.ParseError, OSError) as exc:
                fail(f"cannot parse XML result {path}: {exc}")
            root_name = root.tag.rsplit("}", 1)[-1]
            file_format = {
                "TestRun": "trx",
                "test-run": "nunit",
                "test-results": "nunit",
                "assemblies": "xunit",
                "testsuite": "junit",
                "testsuites": "junit",
            }.get(root_name, "")
        elif path.suffix.lower() == ".json":
            file_format = "playwright-json"
    if file_format == "junit":
        return parse_junit(path)
    if file_format == "trx":
        return parse_trx(path)
    if file_format == "nunit":
        return parse_nunit(path)
    if file_format == "xunit":
        return parse_xunit(path)
    if file_format == "playwright-json":
        return parse_playwright(path)
    fail(f"cannot infer result format for {path}; set format to junit, trx, nunit, xunit, or playwright-json")


def configured_dashboard_url():
    token = env("GITHUB_TOKEN").strip()
    repository = env("GITHUB_REPOSITORY").strip()
    if not token or not repository:
        fail("cannot discover the GitHub Pages URL; ensure GITHUB_TOKEN and GITHUB_REPOSITORY are available")

    api_url = env("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    request = urllib.request.Request(
        f"{api_url}/repos/{quote(repository, safe='/')}/pages",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            pages = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            print(
                "test-stats-gh-pages-action: GitHub Pages is not configured; "
                "summary will omit the dashboard link.",
                file=sys.stderr,
            )
            return ""
        if exc.code == 403:
            fail("cannot read GitHub Pages configuration; grant the workflow token pages:read permission")
        fail(f"GitHub Pages API request failed with HTTP {exc.code}")
    except (urllib.error.URLError, TimeoutError) as exc:
        fail(f"could not look up GitHub Pages configuration: {exc}")
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"GitHub Pages API returned invalid JSON: {exc}")

    pages_url = pages.get("html_url") if isinstance(pages, dict) else None
    if not isinstance(pages_url, str):
        fail("GitHub Pages API response did not include an html_url")
    try:
        parsed_url = urlsplit(pages_url)
    except ValueError:
        fail("GitHub Pages API returned an invalid html_url")
    if parsed_url.scheme not in ("http", "https") or not parsed_url.netloc:
        fail("GitHub Pages API returned an invalid html_url")
    return f"{pages_url.rstrip('/')}/stats/"


def write_summary(name, run):
    summary = env("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    dashboard_url = env("INPUT_DASHBOARD_URL").strip()
    if not dashboard_url:
        dashboard_url = configured_dashboard_url()
    link = ""
    if dashboard_url:
        try:
            parsed_url = urlsplit(dashboard_url)
        except ValueError:
            fail("dashboard-url must be an absolute http(s) URL")
        if parsed_url.scheme not in ("http", "https") or not parsed_url.netloc:
            fail("dashboard-url must be an absolute http(s) URL")
        safe_url = quote(dashboard_url, safe=":/?#[]@!$&'*+,;=%")
        link = f"[View test statistics dashboard]({safe_url})\n\n"
    line = (
        f"## {name}\n\n"
        f"**{run['passed']} passed**, {run['failed']} failed, "
        f"{run['skipped']} skipped ({run['total']} total)\n\n"
        f"{link}"
    )
    with open(summary, "a", encoding="utf-8") as out:
        out.write(line)


def write_outputs(run, stats_file):
    output = env("GITHUB_OUTPUT")
    if not output:
        return
    with open(output, "a", encoding="utf-8") as out:
        for key in ("total", "passed", "failed", "skipped"):
            out.write(f"{key}={run[key]}\n")
        out.write(f"stats-file={stats_file}\n")


def make_dashboard(store_path, runs, name, window_days):
    rows = []
    for run in reversed(runs):
        run_link = run.get("run_url") or "#"
        rows.append(
            "<tr>"
            f"<td><a href=\"{html.escape(run_link, quote=True)}\">"
            f"Run #{html.escape(str(run.get('run_id', '')))}</a></td>"
            f"<td>{html.escape(run.get('timestamp', ''))}</td>"
            f"<td>{html.escape(str(run.get('branch') or '—'))}</td>"
            f"<td>{run.get('passed', 0)}</td>"
            f"<td>{run.get('failed', 0)}</td>"
            f"<td>{run.get('skipped', 0)}</td>"
            f"<td>{run.get('total', 0)}</td></tr>"
        )
    table_rows = "\n".join(rows) or '<tr><td colspan="7">No test runs in this window.</td></tr>'
    dashboard = store_path.parent / "index.html"
    dashboard.write_text(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        f"<title>{html.escape(name)} — Test statistics</title>"
        "<style>body{font:16px system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem}"
        "table{border-collapse:collapse;width:100%}td,th{text-align:left;padding:.6rem;border-bottom:1px solid #ddd}"
        "th{background:#f5f5f5}a{color:#2563eb}</style></head><body>"
        f"<h1>{html.escape(name)} — last {window_days} days</h1>"
        "<table><thead><tr><th>Run</th><th>Timestamp</th><th>Branch</th><th>Passed</th>"
        "<th>Failed</th><th>Skipped</th><th>Total</th></tr></thead>"
        f"<tbody>{table_rows}</tbody></table></body></html>\n",
        encoding="utf-8",
    )


def main():
    forced_format = env("INPUT_FORMAT", "auto")
    if forced_format not in ("auto", "junit", "trx", "nunit", "xunit", "playwright-json"):
        fail("format must be auto, junit, trx, nunit, xunit, or playwright-json")
    try:
        window_days = int(env("INPUT_HISTORY_DAYS", "30"))
    except ValueError:
        fail("history-days must be a positive integer")
    if window_days < 1:
        fail("history-days must be a positive integer")

    run = {
        "run_id": env("GITHUB_RUN_NUMBER", "0"),
        "run_url": (
            f"{env('GITHUB_SERVER_URL', 'https://github.com')}/"
            f"{env('GITHUB_REPOSITORY')}/actions/runs/{env('GITHUB_RUN_ID', '0')}"
        ),
        "branch": env("GITHUB_HEAD_REF") or env("GITHUB_REF_NAME"),
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "total": 0, "passed": 0, "failed": 0, "skipped": 0, "flaky_count": 0,
        "duration_ms": 0, "sources": [],
    }
    failures, flaky = [], []
    for path in input_paths():
        counts, source_failures, source_flaky = parse_result(path, forced_format)
        run["sources"].append({"path": str(path), **counts})
        for key in ("total", "passed", "failed", "skipped", "duration_ms"):
            run[key] += counts[key]
        run["flaky_count"] += counts["flaky"]
        failures.extend(source_failures)
        flaky.extend(source_flaky)
    run["failed_tests"] = failures
    run["flaky_tests"] = flaky

    site_dir = Path(env("INPUT_SITE_DIRECTORY", "site")).resolve()
    stats_subdirectory = Path(env("INPUT_STATS_SUBDIRECTORY", "stats"))
    if stats_subdirectory.is_absolute() or not stats_subdirectory.parts or any(
        part in ("", ".", "..") for part in stats_subdirectory.parts
    ):
        fail("stats-subdirectory must be a safe relative path")
    stats_dir = (site_dir / stats_subdirectory).resolve()
    if site_dir != stats_dir and site_dir not in stats_dir.parents:
        fail("stats-subdirectory resolves outside site-directory")
    runs_path = stats_dir / "runs.json"
    if runs_path.exists():
        try:
            store = json.loads(runs_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            fail(f"cannot read existing statistics {runs_path}: {exc}")
        if not isinstance(store, dict) or not isinstance(store.get("runs"), list):
            fail(f"existing statistics {runs_path} must contain a runs array")
        if "schemaVersion" in store:
            schema_version = store["schemaVersion"]
            if (
                not isinstance(schema_version, int)
                or isinstance(schema_version, bool)
                or schema_version != RUNS_SCHEMA_VERSION
            ):
                fail(
                    f"unsupported runs.json schemaVersion {schema_version!r}; "
                    f"expected {RUNS_SCHEMA_VERSION}"
                )
        store["schemaVersion"] = RUNS_SCHEMA_VERSION
    else:
        store = {"schemaVersion": RUNS_SCHEMA_VERSION, "runs": []}

    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=window_days)
    recent = []
    for old in store["runs"]:
        try:
            stamp = dt.datetime.fromisoformat(old["timestamp"].replace("Z", "+00:00"))
        except (KeyError, AttributeError, ValueError, TypeError):
            fail(f"existing statistics contain an invalid run timestamp: {old!r}")
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=dt.timezone.utc)
        if old.get("run_id") != run["run_id"] and stamp >= cutoff:
            recent.append(old)
    recent.append(run)
    recent.sort(key=lambda item: item["timestamp"])
    store["runs"] = recent

    atomic_json(runs_path, store)
    report_name = env("INPUT_REPORT_NAME").strip() or "Test results"
    make_dashboard(runs_path, recent, report_name, window_days)
    write_summary(report_name, run)
    write_outputs(run, runs_path)
    print(
        f"Test results: {run['passed']} passed, {run['failed']} failed, "
        f"{run['skipped']} skipped ({run['total']} total)"
    )


if __name__ == "__main__":
    main()
