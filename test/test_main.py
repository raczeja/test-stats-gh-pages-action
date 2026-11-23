import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import datetime as dt


SOURCE = Path(__file__).parents[1] / "src" / "main.py"
SPEC = importlib.util.spec_from_file_location("main", SOURCE)
main = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(main)


class StatsActionTests(unittest.TestCase):
    def test_junit_counts_success_failure_and_skip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "results.xml"
            path.write_text(
                '<testsuites><testsuite><testcase name="pass" time="0.5"/>'
                '<testcase name="fail"><failure message="broken"/></testcase>'
                '<testcase name="skip"><skipped/></testcase></testsuite></testsuites>'
            )
            counts, failures, flaky = main.parse_junit(path)
        self.assertEqual((counts["total"], counts["passed"], counts["failed"], counts["skipped"]), (3, 1, 1, 1))
        self.assertEqual(failures[0]["error"], "broken")
        self.assertEqual(flaky, [])

    def test_auto_detects_vstest_trx_even_when_file_uses_xml_extension(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Ocaramba.Tests.Features.xml"
            path.write_text(
                '<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">'
                '<Results>'
                '<UnitTestResult testId="passed" testName="Tests.Pass" outcome="Passed" '
                'duration="00:00:00.1250000"/>'
                '<UnitTestResult testId="failed" testName="Tests.Fail" outcome="Failed" '
                'duration="00:00:01.2500000"><Output><ErrorInfo><Message>broken</Message>'
                '</ErrorInfo></Output></UnitTestResult>'
                '<UnitTestResult testId="skipped" testName="Tests.Skip" outcome="NotExecuted" '
                'duration="00:00:00"/></Results>'
                '<TestDefinitions><UnitTest id="failed"><TestMethod className="Tests" '
                'name="Fail"/></UnitTest></TestDefinitions></TestRun>'
            )
            counts, failures, flaky = main.parse_result(path, "auto")

        self.assertEqual(
            (counts["total"], counts["passed"], counts["failed"], counts["skipped"], counts["duration_ms"]),
            (3, 1, 1, 1, 1375),
        )
        self.assertEqual(failures, [{"title": "Tests.Fail", "file": "Tests", "error": "broken"}])
        self.assertEqual(flaky, [])

    def test_auto_detects_nunit_2_nunit_3_and_xunit_xml(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nunit3 = root / "nunit3.xml"
            nunit3.write_text(
                '<test-run><test-suite><test-case fullname="NUnit3.Pass" result="Passed" '
                'duration="0.125"/><test-case fullname="NUnit3.Fail" result="Failed">'
                '<failure><message>nunit failure</message></failure></test-case>'
                '<test-case fullname="NUnit3.Skip" result="Skipped"/></test-suite></test-run>'
            )
            nunit2 = root / "nunit2.xml"
            nunit2.write_text(
                '<test-results><test-suite><results><test-case name="NUnit2.Pass" '
                'success="True" executed="True" time="0.25"/><test-case name="NUnit2.Skip" '
                'success="False" executed="False" result="Ignored"/></results></test-suite></test-results>'
            )
            xunit = root / "xunit.xml"
            xunit.write_text(
                '<assemblies><assembly name="Tests"><collection><test name="Xunit.Pass" '
                'result="Pass" time="0.5"/><test name="Xunit.Fail" result="Fail">'
                '<failure><message>xunit failure</message></failure></test>'
                '<test name="Xunit.Skip" result="Skip"/></collection></assembly></assemblies>'
            )

            nunit3_counts, nunit3_failures, _ = main.parse_result(nunit3, "auto")
            nunit2_counts, _, _ = main.parse_result(nunit2, "auto")
            xunit_counts, xunit_failures, _ = main.parse_result(xunit, "auto")

        self.assertEqual(
            (nunit3_counts["total"], nunit3_counts["passed"], nunit3_counts["failed"], nunit3_counts["skipped"]),
            (3, 1, 1, 1),
        )
        self.assertEqual(nunit3_failures[0]["error"], "nunit failure")
        self.assertEqual(
            (nunit2_counts["total"], nunit2_counts["passed"], nunit2_counts["skipped"]),
            (2, 1, 1),
        )
        self.assertEqual(
            (xunit_counts["total"], xunit_counts["passed"], xunit_counts["failed"], xunit_counts["skipped"]),
            (3, 1, 1, 1),
        )
        self.assertEqual(xunit_failures[0]["error"], "xunit failure")

    def test_playwright_flaky_is_passed_and_counted_separately(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "results.json"
            path.write_text(json.dumps({
                "stats": {"expected": 2, "unexpected": 1, "flaky": 1, "skipped": 1, "duration": 900},
                "suites": [],
            }))
            counts, _, _ = main.parse_playwright(path)
        self.assertEqual(
            (counts["total"], counts["passed"], counts["failed"], counts["skipped"], counts["flaky"]),
            (5, 3, 1, 1, 1),
        )

    def test_missing_result_fails_explicitly(self):
        with patch.dict(os.environ, {"INPUT_RESULT_FILES": "/missing/results.xml"}):
            with self.assertRaises(SystemExit) as exc:
                main.input_paths()
        self.assertEqual(exc.exception.code, 1)

    def test_dashboard_url_must_be_an_absolute_http_url(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary"
            with patch.dict(os.environ, {
                "GITHUB_STEP_SUMMARY": str(summary),
                "INPUT_DASHBOARD_URL": "javascript:alert(1)",
            }, clear=True):
                with self.assertRaises(SystemExit) as exc:
                    main.write_summary("CI tests", {"passed": 1, "failed": 0, "skipped": 0, "total": 1})
        self.assertEqual(exc.exception.code, 1)

    def test_dashboard_url_is_discovered_from_github_pages_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary"
            with patch.dict(os.environ, {
                "GITHUB_STEP_SUMMARY": str(summary),
                "GITHUB_TOKEN": "token",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_API_URL": "https://api.github.test",
            }, clear=True), patch.object(main.urllib.request, "urlopen") as urlopen:
                urlopen.return_value.__enter__.return_value.read.return_value = json.dumps({
                    "html_url": "https://owner.github.io/repo/",
                }).encode()
                main.write_summary("CI tests", {"passed": 1, "failed": 0, "skipped": 0, "total": 1})

            self.assertIn(
                "[View test statistics dashboard](https://owner.github.io/repo/stats/)",
                summary.read_text(),
            )
            request = urlopen.call_args.args[0]
            self.assertEqual(
                request.full_url,
                "https://api.github.test/repos/owner/repo/pages",
            )

    def test_missing_github_pages_config_omits_dashboard_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary"
            with patch.dict(os.environ, {
                "GITHUB_STEP_SUMMARY": str(summary),
                "GITHUB_TOKEN": "token",
                "GITHUB_REPOSITORY": "owner/repo",
            }, clear=True), patch.object(
                main.urllib.request,
                "urlopen",
                side_effect=main.urllib.error.HTTPError(
                    "https://api.github.com/repos/owner/repo/pages",
                    404,
                    "Not Found",
                    {},
                    None,
                ),
            ):
                main.write_summary("CI tests", {"passed": 1, "failed": 0, "skipped": 0, "total": 1})

            contents = summary.read_text()
            self.assertIn("1 passed", contents)
            self.assertNotIn("View test statistics dashboard", contents)

    def test_junit_rejects_non_junit_xml(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "not-junit.xml"
            path.write_text("<root/>")
            with self.assertRaises(SystemExit) as exc:
                main.parse_junit(path)
        self.assertEqual(exc.exception.code, 1)

    def test_action_updates_history_and_writes_github_outputs(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "junit.xml"
            results.write_text('<testsuite><testcase name="ok"/></testsuite>')
            output = root / "output"
            summary = root / "summary"
            now = dt.datetime.now(dt.timezone.utc)
            old_timestamp = (now - dt.timedelta(days=45)).isoformat().replace("+00:00", "Z")
            recent_timestamp = (now - dt.timedelta(days=2)).isoformat().replace("+00:00", "Z")
            runs_path = root / "site" / "reusable-stats" / "runs.json"
            runs_path.parent.mkdir(parents=True)
            runs_path.write_text(json.dumps({"runs": [
                {"run_id": "old", "timestamp": old_timestamp},
                {"run_id": "recent", "timestamp": recent_timestamp},
            ]}))
            env = {
                "INPUT_RESULT_FILES": str(results),
                "INPUT_FORMAT": "auto",
                "INPUT_SITE_DIRECTORY": str(root / "site"),
                "INPUT_STATS_SUBDIRECTORY": "reusable-stats",
                "INPUT_HISTORY_DAYS": "30",
                "INPUT_REPORT_NAME": "CI tests",
                "INPUT_DASHBOARD_URL": "https://owner.github.io/repo/reusable-stats/",
                "GITHUB_RUN_NUMBER": "42",
                "GITHUB_RUN_ID": "42",
                "GITHUB_REF_NAME": "feature/test-stats",
                "GITHUB_HEAD_REF": "feature/head",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_OUTPUT": str(output),
                "GITHUB_STEP_SUMMARY": str(summary),
            }
            with patch.dict(os.environ, env, clear=True):
                main.main()
            stored = json.loads(runs_path.read_text())
            self.assertEqual(stored["schemaVersion"], 1)
            self.assertEqual([item["run_id"] for item in stored["runs"]], ["recent", "42"])
            self.assertEqual(stored["runs"][-1]["branch"], "feature/head")
            dashboard = (runs_path.parent / "index.html").read_text()
            self.assertIn("<th>Branch</th>", dashboard)
            self.assertIn("<td>feature/head</td>", dashboard)
            self.assertIn("passed**", summary.read_text())
            self.assertIn(
                "[View test statistics dashboard](https://owner.github.io/repo/reusable-stats/)",
                summary.read_text(),
            )
            self.assertIn("total=1", output.read_text())

    def test_action_aggregates_junit_and_playwright_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            junit = root / "shell-tests.xml"
            junit.write_text('<testsuite><testcase name="shell pass"/></testsuite>')
            playwright = root / "results.json"
            playwright.write_text(json.dumps({
                "stats": {"expected": 2, "unexpected": 1, "flaky": 1, "skipped": 1, "duration": 900},
                "suites": [],
            }))
            runs_path = root / "site" / "stats" / "runs.json"
            env = {
                "INPUT_RESULT_FILES": f"{junit}\n{playwright}",
                "INPUT_FORMAT": "auto",
                "INPUT_SITE_DIRECTORY": str(root / "site"),
                "INPUT_HISTORY_DAYS": "30",
                "INPUT_REPORT_NAME": "CI tests",
                "GITHUB_RUN_NUMBER": "17",
            }
            with patch.dict(os.environ, env, clear=True):
                main.main()
            stored = json.loads(runs_path.read_text())
            run = stored["runs"][0]
            self.assertEqual(stored["schemaVersion"], 1)
            self.assertEqual(
                (run["total"], run["passed"], run["failed"], run["skipped"], run["flaky_count"]),
                (6, 4, 1, 1, 1),
            )

    def test_action_rejects_unsupported_runs_schema_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "junit.xml"
            results.write_text('<testsuite><testcase name="ok"/></testsuite>')
            runs_path = root / "site" / "stats" / "runs.json"
            runs_path.parent.mkdir(parents=True)
            runs_path.write_text(json.dumps({"schemaVersion": 2, "runs": []}))
            env = {
                "INPUT_RESULT_FILES": str(results),
                "INPUT_FORMAT": "auto",
                "INPUT_SITE_DIRECTORY": str(root / "site"),
            }
            with patch.dict(os.environ, env, clear=True):
                with self.assertRaises(SystemExit) as exc:
                    main.main()
        self.assertEqual(exc.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
