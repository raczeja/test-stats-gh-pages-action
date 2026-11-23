import datetime as dt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "src" / "update-stats.sh"


class DetailedStatsTests(unittest.TestCase):
    def test_test_rows_open_detail_with_execution_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            stats = root / "site" / "stats"
            stats.mkdir(parents=True)
            now = dt.datetime.now(dt.timezone.utc)
            prior = []
            for number in range(1, 22):
                prior.append({
                    "run_id": str(number),
                    "run_url": f"https://github.com/owner/repo/actions/runs/{number}",
                    "timestamp": (now - dt.timedelta(hours=22-number)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "total": 1,
                    "passed": 0 if number in (3, 8) else 1,
                    "failed": 1 if number in (3, 8) else 0,
                    "skipped": 0,
                    "flaky_count": 0,
                    "tests": [{
                        "source": "JUnit",
                        "source_file": "shell.xml",
                        "title": "suite > flaky-test",
                        "file": "suite",
                        "duration_ms": 100 + number,
                        "status": "failed" if number in (3, 8) else "passed",
                    }],
                    "failed_tests": [],
                    "shell_failed_tests": (
                        [{"title": "suite > flaky-test", "error": "historical failure"}]
                        if number in (3, 8) else []
                    ),
                })
            (stats / "runs.json").write_text(json.dumps({"runs": prior}))
            (root / "shell.xml").write_text(
                '<testsuite name="suite"><testcase classname="suite" name="flaky-test"/></testsuite>'
            )
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(root / "site"),
                "SHELL_TESTS_XML": str(root / "shell.xml"),
                "GITHUB_RUN_NUMBER": "22",
                "GITHUB_RUN_ID": "run-22",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)

            dashboard = (stats / "index.html").read_text()
            self.assertIn("test-detail-trigger", dashboard)
            self.assertIn("openTestDetail(currentTests[testIndex])", dashboard)
            self.assertIn("function getTestExecutions(test)", dashboard)
            self.assertIn("var button=headers[i].querySelector('button');\n      if(!button){continue;}", dashboard)
            self.assertIn("Last 20 executions", dashboard)
            self.assertIn("Pass/fail timeline", dashboard)
            self.assertIn("Failure messages", dashboard)
            self.assertIn("Execution duration", dashboard)
            self.assertIn("Retry count", dashboard)
            self.assertIn("First failure date", dashboard)
            self.assertIn("Last successful execution", dashboard)
            self.assertIn("GitHub Actions run", dashboard)
    def test_dashboard_shows_average_failures_and_flaky_tests_per_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            playwright = results / "playwright.json"
            site = root / "site"

            for number, unexpected, flaky in ((1, 3, 1), (2, 0, 2)):
                playwright.write_text(json.dumps({
                    "stats": {
                        "expected": 2,
                        "unexpected": unexpected,
                        "flaky": flaky,
                        "skipped": 0,
                        "duration": 1000,
                    },
                    "suites": [],
                }))
                env = os.environ.copy()
                env.update({
                    "RESULTS_DIR": str(results),
                    "SITE_DIR": str(site),
                    "GITHUB_RUN_NUMBER": str(number),
                    "GITHUB_RUN_ID": f"run-{number}",
                    "GITHUB_SERVER_URL": "https://github.com",
                    "GITHUB_REPOSITORY": "owner/repo",
                })
                subprocess.run(
                    ["bash", str(SCRIPT)],
                    check=True,
                    env=env,
                    capture_output=True,
                    text=True,
                )

            dashboard = (site / "stats" / "index.html").read_text()

            self.assertIn(
                '<div class="stat-box stat-fail"><div class="stat-val" id="overview-avg-failed">1.5</div>'
                '<div class="stat-lbl">Avg failures/run</div></div>',
                dashboard,
            )
            self.assertIn(
                '<div class="stat-box stat-flaky"><div class="stat-val" id="overview-avg-flaky">1.5</div>'
                '<div class="stat-lbl">Avg passed after retry/run</div></div>',
                dashboard,
            )
            self.assertIn("Avg retries/run", dashboard)
            self.assertNotIn("Total failures", dashboard)
            self.assertNotIn("Total flaky", dashboard)

    def test_run_picker_pages_through_runs_in_batches_of_20(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            site = root / "site"
            stats = site / "stats"
            stats.mkdir(parents=True)
            now = dt.datetime.now(dt.timezone.utc)
            prior_runs = [{
                "run_id": str(number),
                "run_url": f"https://github.com/owner/repo/actions/runs/{number}",
                "timestamp": (now - dt.timedelta(days=26 - number)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "total": 1,
                "passed": 1,
                "failed": 0,
                "skipped": 0,
                "flaky_count": 0,
                "duration_ms": 0,
                "slowest_tests": [],
                "failed_tests": [],
                "flaky_tests": [],
                "tests": [],
                "shell_passed": 0,
                "shell_failed": 0,
                "shell_skipped": 0,
                "shell_failed_tests": [],
            } for number in range(1, 26)]
            (stats / "runs.json").write_text(json.dumps({"runs": prior_runs}))
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "GITHUB_RUN_NUMBER": "26",
                "GITHUB_RUN_ID": "run-26",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(
                ["bash", str(SCRIPT)],
                check=True,
                env=env,
                capture_output=True,
                text=True,
            )

            dashboard = (stats / "index.html").read_text()
            picker_start = dashboard.index('<select id="run-picker"')
            picker_end = dashboard.index("</select>", picker_start)
            options = [
                line for line in dashboard[picker_start:picker_end].splitlines()
                if "<option value=" in line
            ]
            self.assertEqual(len(options), 20)
            self.assertTrue(options[0].startswith('<option value="25" selected>'))
            self.assertIn('<option value="6"', options[-1])
            self.assertFalse(any('value="5"' in option for option in options))
            self.assertIn('id="run-page-prev"', dashboard)
            self.assertIn('id="run-page-next"', dashboard)
            self.assertIn('id="run-page-range"', dashboard)

    def test_reads_vstest_trx_as_supplemental_test_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            trx = root / "Ocaramba.Tests.Features.xml"
            trx.write_text(
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
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(trx),
                "GITHUB_RUN_NUMBER": "8",
                "GITHUB_RUN_ID": "run-8",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })

            subprocess.run(
                ["bash", str(SCRIPT)],
                check=True,
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )

            run = json.loads((site / "stats" / "runs.json").read_text())["runs"][0]
            tests = {test["title"]: test for test in run["tests"]}
            self.assertEqual(
                (run["shell_passed"], run["shell_failed"], run["shell_skipped"]),
                (1, 1, 1),
            )
            self.assertEqual(tests["Tests.Pass"]["source"], "VSTest")
            self.assertEqual(tests["Tests.Pass"]["source_file"], "Ocaramba.Tests.Features.xml")
            self.assertEqual(tests["Tests.Pass"]["duration_ms"], 125)
            self.assertEqual(run["shell_failed_tests"][0]["error"], "broken")
            self.assertEqual(
                run["shell_failed_tests"][0]["source_file"],
                "Ocaramba.Tests.Features.xml",
            )
            dashboard = (site / "stats" / "index.html").read_text()
            self.assertIn("function sourceLabel(test)", dashboard)
            self.assertIn("sourceLabel(test)", dashboard)
            self.assertIn("Ocaramba.Tests.Features.xml", dashboard)
            self.assertIn("Test results (all configured sources)", dashboard)
            self.assertIn('id="overview-avg-duration"', dashboard)
            self.assertIn(
                '<div class="stat-box"><div class="stat-val" id="overview-avg-total">2</div>'
                '<div class="stat-lbl">Avg tests/run</div></div>',
                dashboard,
            )
            self.assertIn('66.7% pass rate', dashboard)
            self.assertIn("Failure details ('+failures.length+')", dashboard)
            self.assertIn("failure.error||'No failure message provided.'", dashboard)

    def test_reads_nunit_and_xunit_xml_as_supplemental_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            (root / "nunit3.xml").write_text(
                '<test-run><test-case fullname="NUnit3.Pass" result="Passed" duration="0.125"/>'
                '<test-case fullname="NUnit3.Fail" result="Failed"><failure><message>nunit failure'
                '</message></failure></test-case><test-case fullname="NUnit3.Skip" result="Skipped"/>'
                '</test-run>'
            )
            (root / "nunit2.xml").write_text(
                '<test-results><test-suite><results><test-case name="NUnit2.Pass" '
                'success="True" executed="True" time="0.25"/><test-case name="NUnit2.Skip" '
                'success="False" executed="False" result="Ignored"/></results></test-suite></test-results>'
            )
            (root / "xunit.xml").write_text(
                '<assemblies><assembly name="Tests"><collection><test name="Xunit.Pass" '
                'result="Pass" time="0.5"/><test name="Xunit.Fail" result="Fail">'
                '<failure><message>xunit failure</message></failure></test>'
                '<test name="Xunit.Skip" result="Skip"/></collection></assembly></assemblies>'
            )
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(root / "*.xml"),
                "GITHUB_RUN_NUMBER": "9",
                "GITHUB_RUN_ID": "run-9",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })

            subprocess.run(
                ["bash", str(SCRIPT)],
                check=True,
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )

            run = json.loads((site / "stats" / "runs.json").read_text())["runs"][0]
            tests = {test["title"]: test for test in run["tests"]}
            self.assertEqual(
                (run["shell_passed"], run["shell_failed"], run["shell_skipped"]),
                (3, 2, 3),
            )
            self.assertEqual(tests["NUnit3.Pass"]["source"], "NUnit")
            self.assertEqual(tests["NUnit3.Pass"]["source_file"], "nunit3.xml")
            self.assertEqual(tests["Xunit.Pass"]["source"], "xUnit")
            self.assertEqual(tests["Xunit.Pass"]["source_file"], "xunit.xml")
            self.assertEqual(
                {test["error"] for test in run["shell_failed_tests"]},
                {"nunit failure", "xunit failure"},
            )
            dashboard = (site / "stats" / "index.html").read_text()
            self.assertIn("nunit failure", dashboard)
            self.assertIn("xunit failure", dashboard)

    def test_expands_junit_glob_and_uses_report_name_in_dashboard_title(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for directory, name, cases in (
                (
                    "module-a",
                    "TEST-passing.xml",
                    "".join(f'<testcase name="pass-{index}"/>' for index in range(20)),
                ),
                (
                    "module-b",
                    "TEST-mixed.xml",
                    "".join(
                        f'<testcase name="fail-{index}"><failure message="failed"/></testcase>'
                        for index in range(9)
                    )
                    + '<testcase name="skipped"><skipped/></testcase>',
                ),
            ):
                junit_dir = root / "test-results" / directory / "junitreports"
                junit_dir.mkdir(parents=True)
                (junit_dir / name).write_text(f'<testsuite name="{directory}">{cases}</testsuite>')
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": "test-results/**/TEST-*.xml",
                "REPORT_NAME": "DBTestCompare & tests",
                "GITHUB_RUN_NUMBER": "201",
                "GITHUB_RUN_ID": "run-201",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(
                ["bash", str(SCRIPT)],
                check=True,
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )

            run = json.loads((site / "stats" / "runs.json").read_text())["runs"][0]
            dashboard = (site / "stats" / "index.html").read_text()

            self.assertEqual(
                (run["shell_passed"], run["shell_failed"], run["shell_skipped"]),
                (20, 9, 1),
            )
            self.assertEqual(len(run["tests"]), 30)
            self.assertEqual(len(run["shell_failed_tests"]), 9)
            self.assertNotIn("Failed additional tests", dashboard)
            self.assertNotIn("Failed tests from JSON results", dashboard)
            self.assertIn(
                "<title>repo · DBTestCompare &amp; tests &middot; Test Statistics</title>",
                dashboard,
            )
            self.assertIn(
                "repo · DBTestCompare &amp; tests &middot; Test Statistics",
                dashboard,
            )
            self.assertNotIn("Failed tests from JSON results", dashboard)

    def test_uses_repository_name_for_dashboard_title_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            shell_xml = root / "shell.xml"
            shell_xml.write_text('<testsuite name="example"/>')
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(shell_xml),
                "GITHUB_RUN_NUMBER": "1",
                "GITHUB_RUN_ID": "run-1",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "Accenture/DBTestCompare",
            })
            env.pop("REPORT_NAME", None)
            subprocess.run(
                ["bash", str(SCRIPT)],
                check=True,
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )

            dashboard = (site / "stats" / "index.html").read_text()

            self.assertIn(
                "<title>DBTestCompare &middot; Test Statistics</title>",
                dashboard,
            )
            self.assertIn(
                "DBTestCompare &middot; Test Statistics</span>",
                dashboard,
            )

    def test_fails_when_configured_junit_glob_matches_no_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": "test-results/**/TEST-*.xml",
                "GITHUB_RUN_NUMBER": "201",
                "GITHUB_RUN_ID": "run-201",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })

            result = subprocess.run(
                ["bash", str(SCRIPT)],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No XML test-result files matched", result.stderr)

    def test_lists_all_tests_and_marks_new_or_changed_statuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            shell_xml = root / "shell.xml"
            site = root / "site"

            def write_results(tests, shell_failure=False):
                (results / "playwright.json").write_text(json.dumps({
                    "stats": {
                        "expected": sum(status == "expected" for _, status in tests),
                        "unexpected": sum(status == "unexpected" for _, status in tests),
                        "flaky": sum(status == "flaky" for _, status in tests),
                        "skipped": sum(status == "skipped" for _, status in tests),
                        "duration": 1200,
                    },
                    "suites": [{
                        "title": "suite",
                        "specs": [{
                            "title": title,
                            "file": "tests/example.spec.js",
                            "tests": [{"status": status, "results": []}],
                        } for title, status in tests],
                    }],
                }))
                failure = '<failure message="failed"/>' if shell_failure else ""
                shell_xml.write_text(
                    '<testsuites><testsuite name="shell">'
                    f'<testcase classname="sh" name="check">{failure}</testcase>'
                    '</testsuite></testsuites>'
                )

            def run(number):
                env = os.environ.copy()
                env.update({
                    "RESULTS_DIR": str(results),
                    "SITE_DIR": str(site),
                    "SHELL_TESTS_XML": str(shell_xml),
                    "GITHUB_RUN_NUMBER": str(number),
                    "GITHUB_RUN_ID": f"run-{number}",
                    "GITHUB_SERVER_URL": "https://github.com",
                    "GITHUB_REPOSITORY": "owner/repo",
                })
                subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)

            write_results([("stable", "expected"), ("changes", "expected")])
            run(1)
            write_results([
                ("stable", "expected"),
                ("changes", "unexpected"),
                ("added", "expected"),
            ], shell_failure=True)
            run(2)

            store = json.loads((site / "stats" / "runs.json").read_text())
            latest = store["runs"][-1]
            tests = {(test["source"], test["title"]): test for test in latest["tests"]}
            dashboard = (site / "stats" / "index.html").read_text()

            self.assertIn("@media(max-width:640px)", dashboard)
            self.assertIn(".stats-row,.selected-run-stats,.duration-stats", dashboard)
            self.assertIn(".table-scroll{max-width:100%;overflow-x:auto}", dashboard)
            self.assertIn(
                '<div class="table-scroll"><table class="all-tests">',
                dashboard,
            )
            self.assertEqual(len(latest["tests"]), 4)
            self.assertNotIn("change", tests[("Playwright", "suite > stable")])
            self.assertEqual(tests[("Playwright", "suite > added")]["change"], "new")
            self.assertEqual(tests[("Playwright", "suite > changes")]["previous_status"], "passed")
            self.assertEqual(tests[("Playwright", "suite > changes")]["status"], "failed")
            self.assertEqual(tests[("JUnit", "shell > check")]["change"], "changed")
            self.assertEqual(tests[("Playwright", "suite > changes")]["duration_ms"], 0)
            self.assertEqual(tests[("JUnit", "shell > check")]["duration_ms"], 0)
            self.assertIn('"compared_with_run_id": "1"', dashboard)
            self.assertIn("New</span>", dashboard)
            self.assertIn("&rarr; '+esc(status)", dashboard)
            self.assertIn("test-trend-match", dashboard)
            self.assertIn(
                '"flaky": [["shell > check", 1], ["suite > changes", 1]]',
                dashboard,
            )
            self.assertIn("else if(v==='flaky')", dashboard)
            self.assertIn("else if(v==='longest')", dashboard)
            self.assertIn("else if(v==='retried')", dashboard)
            self.assertIn('<option value="1" selected>', dashboard)
            self.assertLess(
                dashboard.index('id="run-picker"'),
                dashboard.index('<h2 class="card-title" id="overview-title">Last 30 days'),
            )
            self.assertIn(
                "picker.addEventListener('change',function(){renderRun(RUNS[parseInt(this.value,10)]);});",
                dashboard,
            )
            self.assertIn('data-label="Execution time"', dashboard)
            self.assertIn("fmtTestDur(test.duration_ms)", dashboard)
            self.assertIn("function fmtTestDur(ms)", dashboard)

    def test_preserves_rolling_failure_flaky_runtime_and_shell_statistics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            (results / "playwright.json").write_text(json.dumps({
                "stats": {"expected": 2, "unexpected": 1, "flaky": 1, "skipped": 1, "duration": 900},
                "suites": [{
                    "title": "suite",
                    "specs": [
                        {
                            "title": "fails",
                            "file": "tests/example.spec.js",
                            "tests": [{
                                "status": "unexpected",
                                "results": [
                                    {"duration": 0},
                                    {"duration": 300, "errors": [{"message": "failure detail"}]},
                                ],
                            }],
                        },
                        {
                            "title": "retries",
                            "file": "tests/example.spec.js",
                            "tests": [{"status": "flaky", "results": [{"duration": 500}, {"duration": 400}]}],
                        },
                        {
                            "title": "passes",
                            "file": "tests/example.spec.js",
                            "tests": [{"status": "expected"}, {"status": "expected"}],
                        },
                        {
                            "title": "skips",
                            "file": "tests/example.spec.js",
                            "tests": [{"status": "skipped"}],
                        },
                    ],
                }],
            }))
            shell_xml = root / "shell.xml"
            shell_xml.write_text(
                '<testsuites><testsuite name="syntax">'
                '<testcase classname="sh" name="pass" time="0.125"/>'
                '<testcase classname="sh" name="fail" time="0.5"><failure message="shell failure"/></testcase>'
                '<testcase classname="sh" name="skip"><skipped/></testcase>'
                '</testsuite></testsuites>'
            )
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(shell_xml),
                "GITHUB_RUN_NUMBER": "23",
                "GITHUB_RUN_ID": "run-23",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)
            store = json.loads((site / "stats" / "runs.json").read_text())
            run = store["runs"][0]
            dashboard = (site / "stats" / "index.html").read_text()

            self.assertEqual((run["total"], run["passed"], run["failed"], run["skipped"]), (5, 2, 1, 1))
            self.assertEqual((run["passed_after_retry_count"], run["retry_count"]), (1, 2))
            self.assertEqual((run["shell_passed"], run["shell_failed"], run["shell_skipped"]), (1, 1, 1))
            self.assertIn("failure detail", run["failed_tests"][0]["error"])
            playwright_tests = {test["title"]: test for test in run["tests"] if test["source"] == "Playwright"}
            self.assertEqual(playwright_tests["suite > fails"]["duration_ms"], 300)
            self.assertEqual(playwright_tests["suite > fails"]["source_file"], "playwright.json")
            self.assertEqual(playwright_tests["suite > retries"]["duration_ms"], 900)
            self.assertEqual(
                (playwright_tests["suite > fails"]["final_status"],
                 playwright_tests["suite > fails"]["passed_after_retry"],
                 playwright_tests["suite > fails"]["retries"]),
                ("failed", False, 1),
            )
            self.assertEqual(
                (playwright_tests["suite > retries"]["final_status"],
                 playwright_tests["suite > retries"]["passed_after_retry"],
                 playwright_tests["suite > retries"]["retries"]),
                ("passed", True, 1),
            )
            junit_tests = {test["title"]: test for test in run["tests"] if test["source"] == "JUnit"}
            self.assertEqual(junit_tests["syntax > pass"]["duration_ms"], 125)
            self.assertEqual(junit_tests["syntax > pass"]["source_file"], "shell.xml")
            self.assertEqual(junit_tests["syntax > fail"]["duration_ms"], 500)
            self.assertEqual(junit_tests["syntax > skip"]["duration_ms"], 0)
            self.assertIn("Test trends (last 30 days)", dashboard)
            self.assertNotIn("Slowest tests (this run)", dashboard)
            self.assertIn("900 ms", dashboard)
            self.assertEqual(
                dashboard.count(
                    "function fmtDur(ms){if(!ms)return '&mdash;';if(ms<1000)return Math.round(ms)+' ms'"
                ),
                2,
            )
            self.assertIn('"flaky": [["suite > retries", 1]]', dashboard)
            self.assertIn("Passed after retry</th>", dashboard)
            self.assertIn("Retries</th>", dashboard)
            self.assertIn("passed_after_retry_count", dashboard)
            self.assertIn("else if(v==='flaky')", dashboard)
            self.assertIn("else if(v==='longest')", dashboard)
            self.assertIn("else if(v==='retried')", dashboard)
            self.assertIn("shell failure", run["shell_failed_tests"][0]["error"])
            self.assertIn("Test results (all configured sources)", dashboard)
            self.assertNotIn("Additional test results", dashboard)
            self.assertNotIn("JUnit-format test results", dashboard)
            self.assertNotIn("Failed shell tests", dashboard)

    def test_paginates_selected_run_tests_and_allows_page_size_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            tests = [{
                "title": f"test-{index:03d}",
                "file": "tests/pagination.spec.js",
                "tests": [{"status": "expected", "results": [{"duration": (index + 1) * 100}]}],
            } for index in range(65)]
            (results / "playwright.json").write_text(json.dumps({
                "stats": {"expected": len(tests), "unexpected": 0, "flaky": 0, "skipped": 0, "duration": 0},
                "suites": [{"title": "pagination", "specs": tests}],
            }))
            shell_xml = root / "shell.xml"
            shell_xml.write_text('<testsuite name="shell"/>')
            site = root / "site"
            stats = site / "stats"
            stats.mkdir(parents=True)
            now = dt.datetime.now(dt.timezone.utc)
            (stats / "runs.json").write_text(json.dumps({"runs": [{
                "run_id": "feature-run",
                "run_url": "https://github.com/owner/repo/actions/runs/feature-run",
                "branch": "feature/branch",
                "timestamp": (now - dt.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "total": 1,
                "passed": 1,
                "failed": 0,
                "skipped": 0,
                "flaky_count": 0,
                "tests": [{
                    "source": "Playwright",
                    "source_file": "playwright.json",
                    "title": "branch test",
                    "file": "branch.spec.js",
                    "duration_ms": 100,
                    "status": "passed",
                }],
            }]}))
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(shell_xml),
                "GITHUB_RUN_NUMBER": "1",
                "GITHUB_RUN_ID": "run-1",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
                "GITHUB_REF_NAME": "main",
            })
            subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)
            dashboard = (site / "stats" / "index.html").read_text()
            stored_runs = json.loads((site / "stats" / "runs.json").read_text())["runs"]
            run = stored_runs[-1]
            self.assertEqual(run["branch"], "main")
            self.assertFalse(run["test_comparison_available"])
            node = shutil.which("node")
            if node is None:
                self.skipTest("Node.js is required to exercise dashboard behavior")
            script_start = dashboard.index(
                "<script>\n(function(){\n  var picker=document.getElementById('run-picker');"
            ) + len("<script>")
            script_end = dashboard.index("</script>", script_start)
            trend_start = dashboard.index(
                "<script>\n(function(){\n  var sel=document.getElementById('agg-picker');"
            ) + len("<script>")
            trend_end = dashboard.index("</script>", trend_start)
            result = subprocess.run(
                [node, "-e", """
                    const { runInNewContext } = require('vm');
                    const input = JSON.parse(process.argv[1]);
                    const controls = {};
                    const tests = input.run.tests || [];
                    const distinct = values => Array.from(new Set(values));
                    const filterGroups = {
                      'test-filter-source': distinct(tests.map(test =>
                        test.source_file || (['JUnit', 'NUnit', 'xUnit', 'VSTest'].includes(test.source)
                          ? 'Additional' : test.source || ''))).map(value => ({
                            value, checked: true, addEventListener(name, callback) { this.listener = callback; }
                          })),
                      'test-filter-status': distinct(tests.map(test => test.status || 'unknown'))
                        .map(value => ({
                          value, checked: true, addEventListener(name, callback) { this.listener = callback; }
                        })),
                      'test-filter-change': distinct(tests.map(test =>
                        test.change === 'new' ? 'new' : (test.change === 'changed' ? 'changed' : 'unchanged')))
                        .map(value => ({
                          value, checked: true, addEventListener(name, callback) { this.listener = callback; }
                        }))
                    };
                    const allFilters = Object.values(filterGroups).flat();
                    function control(id) {
                      return controls[id] || (controls[id] = {
                        innerHTML: '',
                        textContent: '',
                        className: '',
                        style: {},
                        value: id === 'branch-picker' ? 'all'
                          : (id === 'run-picker' ? '0'
                          : (id === 'test-time-filter' ? 'all' : (id === 'agg-picker' ? 'top' : ''))),
                        disabled: false,
                        listeners: {},
                        addEventListener(name, callback) { this.listeners[name] = callback; },
                        dispatchEvent() {},
                        setAttribute() {},
                        querySelectorAll(selector) {
                          if (selector === '.test-filter-source, .test-filter-status, .test-filter-change') {
                            return allFilters;
                          }
                          for (const name of Object.keys(filterGroups)) {
                            if (selector === '.' + name) return filterGroups[name];
                          }
                          return buttons;
                        }
                      });
                    }
                    const buttons = ['title', 'source', 'status', 'duration', 'change'].map(column => ({
                      attributes: { 'data-sort': column, 'data-label': column },
                      getAttribute(name) { return this.attributes[name]; },
                      setAttribute(name, value) { this.attributes[name] = value; },
                      addEventListener(name, callback) { this.listener = callback; },
                      textContent: ''
                    }));
                    const headers = buttons.map(button => ({
                      querySelector() { return button; },
                      setAttribute() {}
                    }));
                    const document = {
                      cookie: '',
                      getElementById: control,
                      querySelectorAll(selector) {
                        return selector === '.all-tests th' ? headers : [];
                      }
                    };
                    const location = {
                      pathname: '/owner/repo/stats/',
                      reload() { this.didReload = true; }
                    };
                    const window = {};
                    const context = {
                      document,
                      RUNS: input.runs,
                      FILTER_STATS: input.filterStats,
                      location,
                      window,
                      AGG: input.filterStats.all.agg,
                      Event: function Event(name) { this.type = name; }
                    };
                    runInNewContext(input.script, context);
                    runInNewContext(input.trendScript, context);
                    window.initializeBranchDashboard();
                    const page = () => ({
                      titles: Array.from(control('all-tests-body').innerHTML.matchAll(/data-test-title="([^"]*)"/g),
                        match => match[1].replace(/&gt;/g, '>')),
                      range: control('test-page-range').textContent,
                      count: control('test-page-count').textContent
                    });
                    const first = page();
                    control('test-page-next').listeners.click();
                    const second = page();
                    control('test-page-next').listeners.click();
                    const third = page();
                    control('test-page-prev').listeners.click();
                    const previous = page();
                    const size = control('test-page-size');
                    size.value = '50';
                    size.listeners.change.call(size);
                    const resized = page();
                    buttons[0].listener.call(buttons[0]);
                    buttons[0].listener.call(buttons[0]);
                    const sortedDescending = page();
                    const name = control('test-name-filter');
                    name.value = 'test-064';
                    name.listeners.input();
                    const searched = page();
                    const timeFilter = control('test-time-filter');
                    timeFilter.value = 'slowest10';
                    timeFilter.listeners.change();
                    const prefs = JSON.parse(decodeURIComponent(document.cookie.split(';')[0].split('=').slice(1).join('=')));
                    name.value = '';
                    name.listeners.input();
                    const slowOnly = page();
                    timeFilter.value = 'all';
                    timeFilter.listeners.change();
                    const source = filterGroups['test-filter-source'][0];
                    source.checked = false;
                    source.listener();
                    const noSource = page();
                    source.checked = true;
                    source.listener();
                    const status = filterGroups['test-filter-status'][0];
                    status.checked = false;
                    status.listener();
                    const noStatus = page();
                    status.checked = true;
                    status.listener();
                    const change = filterGroups['test-filter-change'][0];
                    change.checked = false;
                    change.listener();
                    const noChange = page();
                    const initialColumnHtml = control('selected-run-tests').innerHTML;
                    const branchPicker = control('branch-picker');
                    branchPicker.value = 'branch:feature/branch';
                    branchPicker.listeners.change.call(branchPicker);
                    const branchSummary = control('overview-title').textContent;
                    const branchAverage = control('overview-avg-total').textContent;
                    const branchRun = control('run-picker').value;
                    const branchRange = control('run-page-range').textContent;
                    const branchSparkline = control('run-sparkline').innerHTML;
                    const aggPicker = control('agg-picker');
                    aggPicker.value = 'flaky';
                    aggPicker.listeners.change.call(aggPicker);
                    const branchPrefs = JSON.parse(decodeURIComponent(
                      document.cookie.split(';')[0].split('=').slice(1).join('=')));
                    control('reset-dashboard-preferences').listeners.click();
                    process.stdout.write(JSON.stringify({
                      first, second, third, previous, resized, sortedDescending, searched, slowOnly,
                      noSource, noStatus, noChange, prefs,
                      branchSummary, branchAverage, branchRun, branchRange, branchSparkline, branchPrefs,
                      resetCookie: document.cookie, resetReloaded: location.didReload,
                      columnHtml: initialColumnHtml
                    }));
                """, json.dumps({
                    "script": dashboard[script_start:script_end],
                    "trendScript": dashboard[trend_start:trend_end],
                    "run": run,
                    "runs": stored_runs,
                    "filterStats": json.loads(
                        re.search(r"var FILTER_STATS=(.*?);</script>", dashboard).group(1)
                    ),
                })],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            pages = json.loads(result.stdout)
            self.assertEqual(pages["first"]["range"], "Showing 1-30 of 65 tests")
            self.assertEqual(pages["first"]["count"], "Page 1 of 3")
            self.assertEqual(pages["first"]["titles"], [
                f"pagination > test-{index:03d}" for index in range(30)
            ])
            self.assertEqual(pages["second"]["range"], "Showing 31-60 of 65 tests")
            self.assertEqual(pages["second"]["titles"], [
                f"pagination > test-{index:03d}" for index in range(30, 60)
            ])
            self.assertEqual(pages["third"]["range"], "Showing 61-65 of 65 tests")
            self.assertEqual(pages["third"]["count"], "Page 3 of 3")
            self.assertEqual(pages["third"]["titles"], [
                f"pagination > test-{index:03d}" for index in range(60, 65)
            ])
            self.assertEqual(pages["previous"]["range"], "Showing 31-60 of 65 tests")
            self.assertEqual(pages["resized"]["range"], "Showing 1-50 of 65 tests")
            self.assertEqual(len(pages["resized"]["titles"]), 50)
            self.assertEqual(pages["sortedDescending"]["titles"][0], "pagination > test-064")
            self.assertEqual(pages["searched"]["titles"], ["pagination > test-064"])
            self.assertEqual(pages["slowOnly"]["range"], "Showing 1-7 of 7 tests")
            self.assertEqual(pages["slowOnly"]["titles"], [
                f"pagination > test-{index:03d}" for index in range(64, 57, -1)
            ])
            self.assertEqual(pages["prefs"]["testsPerPage"], 50)
            self.assertEqual(pages["prefs"]["sortColumn"], "title")
            self.assertEqual(pages["prefs"]["sortDirection"], -1)
            self.assertEqual(pages["prefs"]["testName"], "test-064")
            self.assertEqual(pages["prefs"]["timeFilter"], "slowest10")
            self.assertNotIn("runIndex", pages["prefs"])
            durations = sorted(test["duration_ms"] for test in run["tests"])
            slowest_10_threshold = durations[(len(durations) * 9 + 9) // 10 - 1]
            self.assertIn(
                f"Slowest 10% (≥ {slowest_10_threshold / 1000:.2f} s)",
                pages["columnHtml"],
            )
            self.assertIn('id="test-name-filter"', pages["columnHtml"])
            self.assertIn('id="reset-dashboard-preferences"', dashboard)
            self.assertIn('id="export-runs-json"', dashboard)
            self.assertIn("JSON.stringify(RUNS_STORE,null,2)", dashboard)
            self.assertIn("link.download='runs.json'", dashboard)
            self.assertEqual(pages["noSource"]["range"], "Showing 0-0 of 0 tests")
            self.assertEqual(pages["noStatus"]["range"], "Showing 0-0 of 0 tests")
            self.assertEqual(pages["noChange"]["range"], "Showing 0-0 of 0 tests")
            self.assertIn("Max-Age=0", pages["resetCookie"])
            self.assertTrue(pages["resetReloaded"])
            self.assertEqual(pages["branchSummary"], "Last 30 days — 1 run(s)")
            self.assertEqual(pages["branchAverage"], 1)
            self.assertEqual(pages["branchRun"], "0")
            self.assertEqual(pages["branchRange"], "Runs 1-1 of 1 (newest first)")
            self.assertIn("feature-run", pages["branchSparkline"])
            self.assertNotIn("Run #1", pages["branchSparkline"])
            self.assertEqual(pages["branchPrefs"]["branch"], "branch:feature/branch")

    def test_records_shell_failure_when_playwright_results_are_unavailable(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            shell_xml = root / "shell.xml"
            shell_xml.write_text(
                '<testsuites><testsuite name="shell-tests" tests="2" failures="1">'
                '<testcase classname="other-test" name="passes"/>'
                '<testcase classname="scrape-csrf-extraction" '
                'name="scrape-csrf-extraction / current-csrf-meta-name">'
                '<failure message=\'expected "current123XYZ", got ""\'/>'
                '</testcase></testsuite></testsuites>'
            )
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(shell_xml),
                "GITHUB_RUN_NUMBER": "371",
                "GITHUB_RUN_ID": "run-371",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)
            run = json.loads((site / "stats" / "runs.json").read_text())["runs"][0]
            dashboard = (site / "stats" / "index.html").read_text()

            self.assertEqual((run["total"], run["failed"]), (0, 0))
            self.assertEqual((run["shell_passed"], run["shell_failed"]), (1, 1))
            self.assertEqual(len(run["shell_failed_tests"]), 1)
            failure = run["shell_failed_tests"][0]
            self.assertEqual(failure["title"], "shell-tests > scrape-csrf-extraction / current-csrf-meta-name")
            self.assertEqual(failure["error"], 'expected "current123XYZ", got ""')
            self.assertIn("current-csrf-meta-name", dashboard)
            self.assertIn("current123XYZ", dashboard)
            self.assertIn("shell_failed_tests", dashboard)
            self.assertIn(
                '["shell-tests > scrape-csrf-extraction / current-csrf-meta-name", 1]',
                dashboard,
            )

    def test_shows_aggregate_counts_for_historical_runs_without_test_details(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            shell_xml = root / "shell.xml"
            shell_xml.write_text('<testsuite name="current"><testcase name="passes"/></testsuite>')
            site = root / "site"
            stats_dir = site / "stats"
            stats_dir.mkdir(parents=True)
            old_timestamp = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
            legacy_run = {
                "run_id": "371",
                "run_url": "https://github.com/owner/repo/actions/runs/371",
                "timestamp": old_timestamp,
                "total": 0,
                "passed": 0,
                "failed": 0,
                "skipped": 0,
                "flaky_count": 0,
                "shell_passed": 220,
                "shell_failed": 1,
                "shell_skipped": 0,
                "shell_failed_tests": [],
            }
            (stats_dir / "runs.json").write_text(json.dumps({"runs": [legacy_run]}))
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(shell_xml),
                "GITHUB_RUN_NUMBER": "372",
                "GITHUB_RUN_ID": "run-372",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)
            store = json.loads((stats_dir / "runs.json").read_text())
            dashboard = (stats_dir / "index.html").read_text()

            self.assertEqual(store["schemaVersion"], 1)
            self.assertIn('"shell_passed": 220', dashboard)
            self.assertIn("counts.total=(run.total||0)+(run.shell_passed||0)", dashboard)
            self.assertIn("counts.failed=(run.failed||0)+(run.shell_failed||0)", dashboard)
            self.assertIn(
                "Individual test results were not saved for this run; showing available aggregate counts.",
                dashboard,
            )
            self.assertIn(
                "((run.failed||0)+(run.shell_failed||0))+' failure(s); individual test details were not saved for this run.",
                dashboard,
            )

    def test_longest_tests_trend_shows_only_five_slowest_tests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            test_cases = [{
                "title": f"test-{index}",
                "file": "tests/timing.spec.js",
                "tests": [{
                    "status": "expected",
                    "results": [{"duration": index * 1000}],
                }],
            } for index in range(1, 7)]
            (results / "playwright.json").write_text(json.dumps({
                "stats": {"expected": 6, "unexpected": 0, "flaky": 0, "skipped": 0, "duration": 21000},
                "suites": [{"title": "timing", "specs": test_cases}],
            }))
            shell_xml = root / "shell.xml"
            shell_xml.write_text('<testsuite name="shell"/>')
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(shell_xml),
                "GITHUB_RUN_NUMBER": "1",
                "GITHUB_RUN_ID": "run-1",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)
            dashboard = (site / "stats" / "index.html").read_text()
            payload_start = dashboard.index("var AGG=") + len("var AGG=")
            payload_end = dashboard.index(";</script>", payload_start)
            trends = json.loads(dashboard[payload_start:payload_end])

            self.assertEqual(len(trends["slow"]), 5)
            self.assertEqual(
                trends["slow"],
                [[f"timing > test-{index}", index * 1000] for index in range(6, 1, -1)],
            )

    def test_other_trend_selections_show_at_most_five_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            failed_specs = [{
                "title": f"failed-{index}",
                "file": "tests/trends.spec.js",
                "tests": [{
                    "status": "unexpected",
                    "results": [{"duration": index * 1000, "errors": [{"message": "failure"}]}],
                }],
            } for index in range(1, 7)]
            flaky_specs = [{
                "title": f"flaky-{index}",
                "file": "tests/trends.spec.js",
                "tests": [{
                    "status": "flaky",
                    "results": [{"duration": index * 1000} for _ in range(index)],
                }],
            } for index in range(1, 7)]
            (results / "playwright.json").write_text(json.dumps({
                "stats": {"expected": 1, "unexpected": 6, "flaky": 6, "skipped": 0, "duration": 21000},
                "suites": [{"title": "trends", "specs": failed_specs + flaky_specs}],
            }))
            shell_xml = root / "shell.xml"
            shell_xml.write_text('<testsuite name="shell"/>')
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(shell_xml),
                "GITHUB_RUN_NUMBER": "1",
                "GITHUB_RUN_ID": "run-1",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)
            dashboard = (site / "stats" / "index.html").read_text()
            payload_start = dashboard.index("var AGG=") + len("var AGG=")
            payload_end = dashboard.index(";</script>", payload_start)
            trends = json.loads(dashboard[payload_start:payload_end])

            self.assertEqual(len(trends["top"]), 5)
            self.assertEqual(len(trends["flaky"]), 5)
            self.assertEqual(len(trends["retried"]), 5)
            node = shutil.which("node")
            if node is None:
                self.skipTest("Node.js is required to exercise dashboard behavior")
            script_start = dashboard.index(
                "<script>\n(function(){\n  var sel=document.getElementById('agg-picker');"
            ) + len("<script>")
            script_end = dashboard.index("</script>", script_start)
            rows = [
                {"title": f"trends > failed-{index}", "status": "failed"}
                for index in range(1, 7)
            ] + [
                {"title": f"trends > flaky-{index}", "status": "flaky"}
                for index in range(1, 7)
            ]
            result = subprocess.run(
                [node, "-e", """
                    const { runInNewContext } = require('vm');
                    const input = JSON.parse(process.argv[1]);
                    const rows = input.rows.map(row => {
                      const classes = new Set();
                      return {
                        getAttribute(name) {
                          return name === 'data-test-title' ? row.title : row.status;
                        },
                        classList: {
                          toggle(name, enabled) {
                            if (enabled) classes.add(name);
                            else classes.delete(name);
                          }
                        },
                        classes
                      };
                    });
                    const picker = {
                      value: 'top',
                      addEventListener(name, callback) { this.listener = callback; }
                    };
                    const box = { innerHTML: '' };
                    const document = {
                      cookie: '',
                      getElementById(name) { return name === 'agg-picker' ? picker : box; },
                      querySelectorAll() { return rows; }
                    };
                    runInNewContext(input.script, {
                      document,
                      AGG: input.trends,
                      window: {},
                      location: { pathname: '/owner/repo/stats/' }
                    });
                    const highlighted = () => rows
                      .filter(row => row.classes.has('test-trend-match'))
                      .map(row => row.getAttribute('data-test-title'));
                    const top = highlighted();
                    picker.value = 'flaky';
                    picker.listener.call(picker);
                    process.stdout.write(JSON.stringify({ top, flaky: highlighted() }));
                """, json.dumps({
                    "script": dashboard[script_start:script_end],
                    "trends": trends,
                    "rows": rows,
                })],
                check=True,
                capture_output=True,
                text=True,
            )
            highlights = json.loads(result.stdout)
            self.assertEqual(
                set(highlights["top"]),
                {title for title, _ in trends["top"]},
            )
            self.assertEqual(
                set(highlights["flaky"]),
                {title for title, _ in trends["flaky"]},
            )

    def test_longest_tests_trend_includes_timed_junit_results(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            results = root / "results"
            results.mkdir()
            shell_xml = root / "shell.xml"
            shell_xml.write_text(
                '<testsuite name="timing">'
                + "".join(
                    f'<testcase classname="timing" name="test-{index}" time="{index}"/>'
                    for index in range(1, 7)
                )
                + '</testsuite>'
            )
            site = root / "site"
            env = os.environ.copy()
            env.update({
                "RESULTS_DIR": str(results),
                "SITE_DIR": str(site),
                "SHELL_TESTS_XML": str(shell_xml),
                "GITHUB_RUN_NUMBER": "1",
                "GITHUB_RUN_ID": "run-1",
                "GITHUB_SERVER_URL": "https://github.com",
                "GITHUB_REPOSITORY": "owner/repo",
            })
            subprocess.run(["bash", str(SCRIPT)], check=True, env=env, capture_output=True, text=True)
            dashboard = (site / "stats" / "index.html").read_text()
            payload_start = dashboard.index("var AGG=") + len("var AGG=")
            payload_end = dashboard.index(";</script>", payload_start)
            trends = json.loads(dashboard[payload_start:payload_end])

            self.assertEqual(
                trends["slow"],
                [[f"timing > test-{index}", index * 1000] for index in range(6, 1, -1)],
            )


if __name__ == "__main__":
    unittest.main()
