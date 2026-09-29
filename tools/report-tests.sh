#!/usr/bin/env bash
# Writes a Markdown test report from .xcresult bundles and `swift test` logs. CI appends it to the run's summary.
# Run tools/report-tests.sh --help for usage and the report's format.
set -eu

usage() {
  cat <<'EOF'
Usage: tools/report-tests.sh [--help] RESULT...

Writes a Markdown test report to standard output.

Each RESULT is an Xcode result bundle (*.xcresult, from `xcodebuild test -resultBundlePath`) or a log
file of `swift test` output (Swift Testing). Give at least one; the kinds can be mixed.

The report has:
  - a title line (date, commit, devices), the trigger, the toolchain and the test data versions;
  - a summary per layer and environment: tests, passed, failed, skipped. The layer comes from the test ID
    at the start of the test name, or in an XCTest name such as testE2E_001_... (U- unit, I- recognition
    integration, P- performance, EXP- device experiments, E2E- end-to-end); tests in a UI test bundle are
    UI, other tests without an ID are unit;
  - failure details: failed tests with their messages, build errors, crashes and timeouts;
  - performance metrics, when there are any: XCTest measure blocks, and the `[EXP] test=ID ...` records
    that tests print into a `swift test` log. The app's device performance gates are judged here against
    their thresholds: pass or fail on a device, only recorded elsewhere.

A bundle that cannot be read, or a log without the Swift Testing summary line (the build failed, the
test process crashed or it timed out), is reported as such instead of stopping the report.

Run it on the machine that ran the tests: the toolchain line describes the Xcode selected now
(xcode-select or DEVELOPER_DIR), and the commit is the HEAD of this script's repository.
Needs python3, and Xcode 16 or later for .xcresult input. Uses no network.

Exit status: 0 when the report was written, whatever the test results; 2 on a usage error or when a
RESULT does not exist.

Example:
  tools/report-tests.sh build/results/core-macos.log build/results/app.xcresult > report.md
EOF
}

inputs=()
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "report-tests.sh: unknown option $1 (see --help)" >&2; exit 2;;
    *) inputs+=("$1"); shift;;
  esac
done
while [ $# -gt 0 ]; do inputs+=("$1"); shift; done
if [ ${#inputs[@]} -eq 0 ]; then
  echo "report-tests.sh: no results given" >&2
  usage >&2
  exit 2
fi

status=0
bundles=0
for f in "${inputs[@]}"; do
  case ${f%/} in
    *.xcresult)
      bundles=1
      if [ ! -d "$f" ]; then echo "report-tests.sh: no such result bundle: $f" >&2; status=2
      elif [ ! -f "$f/Info.plist" ]; then echo "report-tests.sh: not an Xcode result bundle (no Info.plist): $f" >&2; status=2; fi;;
    *)
      if [ ! -e "$f" ]; then echo "report-tests.sh: no such file: $f" >&2; status=2
      elif [ ! -f "$f" ] || [ ! -r "$f" ]; then echo "report-tests.sh: not a readable log file: $f" >&2; status=2; fi;;
  esac
done
command -v python3 >/dev/null 2>&1 || { echo "report-tests.sh: needs python3" >&2; status=2; }
if [ $bundles -eq 1 ] && ! xcrun --find xcresulttool >/dev/null 2>&1; then
  echo "report-tests.sh: .xcresult input needs xcresulttool from Xcode 16 or later (xcrun --find xcresulttool failed)" >&2; status=2
fi
[ $status -eq 0 ] || exit $status

root=$(cd "$(dirname "$0")/.." && pwd)
exec python3 - "$root" "${inputs[@]}" <<'PY'
import datetime, hashlib, json, os, plistlib, re, subprocess, sys

root, paths = sys.argv[1], sys.argv[2:]

LAYERS = ('Unit', 'Recognition integration', 'UI', 'Performance', 'End-to-end', 'Device experiments')
PREFIX = {'U': 'Unit', 'I': 'Recognition integration', 'UI': 'UI', 'P': 'Performance', 'E2E': 'End-to-end',
          'EXP': 'Device experiments'}
TEST_ID = re.compile(r'((?:[A-Z0-9]+-)+\d{3})\b')  # U-ANN-001, P-SYNC-001, EXP-LEM-002 at the start of a test name
XCTEST_ID = re.compile(r'test((?:[A-Z0-9]+_)+\d{3})(?=_|\(|$)')  # testE2E_001_…(), testP_LAUNCH_001_…(): E2E-001, P-LAUNCH-001
# The app's device performance gates (App/ReadStairUITests/PerformanceGates.swift), by test ID: the words the metric's name must
# contain, the statistic over the measured runs, and the limit, which the value must stay under. Judged only on a device; a device
# run that reports no value fails.
GATES = {
    'P-LAUNCH-001': [(('duration',), 'median', 1, 's')],
    'P-MEM-001': [(('peak', 'physical'), 'max', 150, 'MB'), (('hitch', 'ratio'), 'median', 5, 'ms per s')],
    'P-DB-001': [(('duration',), 'median', 0.2, 's')],
}
UNITS = {'s': ('s', 1), 'ms': ('s', 1e-3), 'kB': ('MB', 1 / 1024), 'KB': ('MB', 1 / 1024), 'MB': ('MB', 1),
         'B': ('MB', 1 / 1048576), 'ms per s': ('ms per s', 1), 'ms/s': ('ms per s', 1)}
OUTCOME = {'Passed': 'passed', 'Expected Failure': 'passed', 'Failed': 'failed', 'Mixed': 'failed', 'Skipped': 'skipped'}
MAX_FAILURES, MAX_RECORDS, MAX_TEXT = 60, 40, 400

# Swift Testing console output. A test name may itself contain quotes, so names match greedily up to the fixed text after them.
ANSI = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')
RUN = re.compile(r'Test run with (\d+) tests?(?: in \d+ suites?)? (passed|failed) after ([\d.]+) seconds?')
END = re.compile(r'^[✔✘➜] Test "(.*)"(?: with \d+ test cases?)? (passed|failed|skipped)(.*)$')
ISSUE = re.compile(r'^✘ Test "(.*?)" recorded an issue(?: with (.*?))?(?: at (\S+:\d+:\d+))?: (.*)$')
COMPILE_ERROR = re.compile(r'^(\S.*?\.swift):(\d+):\d+: error: (.*)$')
RUNTIME_ERROR = re.compile(r'^error: .*|Fatal error: .*')
TIMEOUT = re.compile(r'^::error::(Timed out after \d+ s)')  # printed by the hard timeout in .github/workflows/ci.yml
RECORD_EXP = re.compile(r'^\[EXP\] test=(\S+)\s*(.*)$')

rows, failures, metrics, devices, starts = [], [], [], [], []


def run(*cmd):
    try:
        done = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding='utf-8', errors='replace', timeout=120)
        return done.stdout.strip() if done.returncode == 0 else ''
    except (OSError, subprocess.SubprocessError):
        return ''


def clean(text):
    """One line, home directories shortened (no user names in the report), long decimals cut to three places."""
    text = re.sub(r'\s+', ' ', str(text)).strip()
    text = re.sub(r'/(?:Users|home)/[^/\s\'"]+/', '~/', text)
    return re.sub(r'(\d+\.\d{3})\d+', r'\1', text)


def cell(text, limit=MAX_TEXT):
    text = clean(text)
    if len(text) > limit:
        text = text[:limit - 1] + '…'
    return text.replace('|', '\\|').replace('<', '&lt;')


def source_path(path):
    """A repository-relative path for a source file (the part from App/, Packages/ ... on), else its file name."""
    match = re.search(r'(?:^|/)((?:App|Packages|tools|Fixtures|Data|Config)/.*)$', path)
    return match.group(1) if match else os.path.basename(path)


def test_id(name):
    match = XCTEST_ID.match(name)
    if match:
        return match.group(1).replace('_', '-')
    match = TEST_ID.match(name)
    return match.group(1) if match else None


def gate_results(ident, reported, on_device):
    """Rows (value, threshold, result) for a gate test's run. reported: (name, values, unit) for every metric it reported."""
    rows = []
    for words, statistic, limit, unit in GATES[ident]:
        found = []
        for name, values, from_unit in reported:
            to_unit, factor = UNITS.get(from_unit, (None, 0))
            if to_unit == unit and all(w in re.sub(r'[^a-z]+', ' ', name.lower()).split() for w in words):
                ordered = sorted(v * factor for v in values)
                found.append(ordered[-1] if statistic == 'max' else ordered[(len(ordered) - 1) // 2])
        value = max(found) if found else None
        threshold = '{} < {:g} {}'.format(statistic, limit, unit)
        shown = '{}: {} {}'.format(' '.join(words), number(value), unit) if found else '{}: no value'.format(' '.join(words))
        passed = value is not None and value < limit
        rows.append((shown, threshold, ('pass' if passed else 'fail') if on_device else 'not judged off a device'))
    return rows


def layer_of(name, default):
    found = test_id(name)
    return PREFIX.get(found.split('-')[0], default) if found else default


def number(value):
    return '{:,.0f}'.format(value) if abs(value) >= 100 else '{:.2f}'.format(value)


def device_text(device):
    platform = device.get('platform', '')
    system = 'macOS' if platform.startswith('macOS') else 'iOS'
    kind = ' simulator' if 'Simulator' in platform else ''
    return '{}{} / {} {}'.format(device.get('modelName') or device.get('deviceName') or 'unknown device', kind, system,
                                 device.get('osVersion', '?'))


def add_rows(environment, outcomes, notes, first_note=None):
    """One summary row per layer. outcomes: (layer, 'passed' | 'failed' | 'skipped', skip reason or None)."""
    tally = {}
    for layer, outcome, reason in outcomes:
        entry = tally.setdefault(layer, {'passed': 0, 'failed': 0, 'skipped': 0, 'reasons': []})
        entry[outcome] += 1
        if reason and reason not in entry['reasons']:
            entry['reasons'].append(reason)
    if not tally:
        tally['—'] = {'passed': 0, 'failed': 0, 'skipped': 0, 'reasons': []}
    for index, layer in enumerate(sorted(tally, key=lambda l: LAYERS.index(l) if l in LAYERS else -1)):
        entry = tally[layer]
        row_notes = (list(notes) if index == 0 else []) + ['skipped: ' + r for r in entry['reasons'][:2]]
        if index == 0 and first_note:
            row_notes.insert(0, first_note)
        rows.append({'layer': layer, 'environment': environment, 'passed': entry['passed'], 'failed': entry['failed'],
                     'skipped': entry['skipped'], 'known': True, 'notes': row_notes})


def unreadable(environment, name, error):
    rows.append({'layer': '—', 'environment': environment, 'known': False, 'notes': ['could not be read']})
    failures.append(('—', 'Could not read the result: ' + error, '`{}`'.format(name)))


# --- Result bundles

def xcresulttool(path, *command):
    done = subprocess.run(['xcrun', 'xcresulttool', 'get'] + list(command) + ['--path', path],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8', errors='replace')
    if done.returncode != 0:
        message = (done.stderr or done.stdout).strip().splitlines()
        raise RuntimeError(message[0] if message else 'xcresulttool exited with {}'.format(done.returncode))
    return json.loads(done.stdout)


def read_bundle(path):
    name = os.path.basename(path.rstrip('/'))
    try:
        summary = xcresulttool(path, 'test-results', 'summary')
        tree = xcresulttool(path, 'test-results', 'tests')
    except (RuntimeError, ValueError) as error:
        print('report-tests.sh: could not read {}: {}'.format(path, error), file=sys.stderr)
        unreadable('`{}`'.format(name), name, str(error))
        return
    bundle_devices = [c['device'] for c in summary.get('devicesAndConfigurations', []) if c.get('device')]
    if summary.get('startTime'):
        starts.append(summary['startTime'])

    cases = []  # (name, identifier, result, layer)

    def walk(node, bundle_type):
        kind = node.get('nodeType', '')
        if kind.endswith('test bundle'):
            bundle_type = kind
        if kind == 'Test Case':
            default = 'UI' if bundle_type == 'UI test bundle' else 'Unit'
            cases.append((node.get('name', ''), node.get('nodeIdentifier'), node.get('result', ''),
                          layer_of(node.get('name', ''), default)))
            return
        for child in node.get('children', []):
            walk(child, bundle_type)

    for node in tree.get('testNodes', []):
        walk(node, '')
    outcomes = [(layer, OUTCOME.get(result, 'failed'), None) for _, _, result, layer in cases]
    notes = []
    total = summary.get('totalTestCount')
    if total is not None and total != len(cases):
        notes.append('the bundle summary counts {} tests'.format(total))
    duration = None
    if summary.get('startTime') and summary.get('finishTime'):
        duration = 'run {:.0f} s'.format(summary['finishTime'] - summary['startTime'])

    for failure in summary.get('testFailures', []):
        test = failure.get('testName', '?')
        failures.append((test_id(test) or test, failure.get('failureText', ''),
                         '{} · `{}`'.format(failure.get('targetName', ''), name)))
    if not cases or summary.get('result') not in ('Passed', 'Failed'):
        build = None
        try:
            build = xcresulttool(path, 'build-results')
        except (RuntimeError, ValueError):
            pass
        errors = (build or {}).get('errors', [])
        if not bundle_devices and (build or {}).get('destination'):
            bundle_devices = [build['destination']]  # tests never started: the device the build was for
        notes.append('no tests ran' if not cases else 'result: {}'.format(summary.get('result', 'unknown')))
        if errors:
            notes.append('build failed: {} errors'.format(build.get('errorCount', len(errors))))
        for error in errors:
            where = error.get('sourceURL', '')
            if where:
                line = re.search(r'StartingLineNumber=(\d+)', where)  # zero-based
                file = source_path(re.sub(r'^file://', '', where.split('#')[0]))
                where = file + (':{}'.format(int(line.group(1)) + 1) if line else '')
            failures.append(('(build)', error.get('message', ''), '{} · `{}`'.format(where, name) if where else '`{}`'.format(name)))
    names = list(dict.fromkeys(device_text(d) for d in bundle_devices))
    devices.extend(n for n in names if n not in devices)
    add_rows('{} · `{}`'.format(', '.join(names) or 'no device', name), outcomes, notes, duration)

    results = {identifier: result for _, identifier, result, _ in cases if identifier}
    try:
        measured = xcresulttool(path, 'test-results', 'metrics')
    except (RuntimeError, ValueError):
        measured = []  # older xcresulttool: no metrics subcommand
    # Devices, not simulators: only there are the gates judged
    real = sorted({d.get('deviceName', '') for d in bundle_devices if not re.search(r'Simulator|macOS', d.get('platform', ''))})
    judged = set()
    for entry in measured:
        identifier = entry.get('testIdentifier', '')
        test = identifier.split('/')[-1]
        ident = test_id(test) or test
        for test_run in entry.get('testRuns', []):
            device = (test_run.get('device') or {}).get('deviceName', '')
            where = '{} · `{}`'.format(device, name)
            reported = []
            for metric in test_run.get('metrics', []):
                values = metric.get('measurements') or []
                if not values:
                    continue
                unit = metric.get('unitOfMeasurement', '')
                label = metric.get('displayName', metric.get('identifier', ''))
                reported.append(('{} {}'.format(label, metric.get('identifier', '')), values, unit))
                if ident in GATES:
                    continue
                value = '{}: {} {}'.format(label, number(sum(values) / len(values)), unit)
                if len(values) > 1:
                    value += ' (average of {}, {}–{})'.format(len(values), number(min(values)), number(max(values)))
                baseline = metric.get('baselineAverage') or 0
                threshold = ('baseline {} {} + {:g}%'.format(number(baseline), unit, metric.get('maxPercentRegression', 0))
                             if baseline else 'no baseline')
                metrics.append((ident, where, value, threshold, results.get(identifier, '?')))
            if ident in GATES:
                judged.add(ident)
                metrics.extend((ident, where) + row for row in gate_results(ident, reported, device in real))
    # A gate that ran on a device and reported no metric at all fails too
    for test, _, result, _ in cases:
        ident = test_id(test)
        if ident in GATES and ident not in judged and real and OUTCOME.get(result) != 'skipped':
            metrics.extend((ident, '{} · `{}`'.format(real[0], name)) + row for row in gate_results(ident, [], True))


# --- swift test logs

def read_log(path):
    name = os.path.basename(path)
    environment = 'macOS `swift test` · `{}`'.format(name)
    try:
        with open(path, encoding='utf-8', errors='replace') as file:
            lines = [ANSI.sub('', line).rstrip() for line in file]
    except OSError as error:
        unreadable(environment, name, str(error))
        return
    ends, issues, summaries, errors, records, timeout = [], {}, [], [], [], None
    last_issue = None
    for line in lines:
        match = ISSUE.match(line)
        if match:
            test, arguments, where, message = match.groups()
            last_issue = [where, ('({}) '.format(arguments) if arguments else '') + message, 0]
            issues.setdefault(test, []).append(last_issue)
            continue
        if line.startswith('↳') and last_issue is not None:  # ↳ detail lines of the issue above
            if last_issue[2] < 3:
                last_issue[1] += ' — ' + line[1:].strip()
                last_issue[2] += 1
            continue
        last_issue = None
        match = END.match(line)
        if match:
            reason = re.match(r'^:\s*"(.*)"\.?$', match.group(3))
            ends.append((match.group(1), match.group(2), reason.group(1) if reason else None))
            continue
        match = RUN.search(line)
        if match:
            summaries.append(match)
            continue
        match = COMPILE_ERROR.match(line)
        if match:
            errors.append(('(build)', match.group(3), '{}:{}'.format(source_path(match.group(1)), match.group(2))))
            continue
        match = RUNTIME_ERROR.search(line)
        if match:
            errors.append(('(run)', match.group(0), ''))
            continue
        match = TIMEOUT.match(line)
        if match:
            timeout = match.group(1)
            continue
        match = RECORD_EXP.match(line)
        if match:
            records.append(match.groups())

    outcomes = [(layer_of(test, 'Unit'), outcome, reason) for test, outcome, reason in ends]
    notes, first = [], None
    if summaries:
        total, verdict, seconds = summaries[-1].groups()
        first = 'run {:.0f} s'.format(float(seconds))
        if len(summaries) > 1:
            notes.append('{} test runs in this log, counted together'.format(len(summaries)))
        elif int(total) != len(ends):
            notes.append('the run summary counts {} tests'.format(total))
        if verdict == 'failed' and not any(o == 'failed' for _, o, _ in ends):
            notes.append('the run failed without a failed test')
    else:
        notes.append('no Swift Testing summary line: the build failed, the tests crashed or timed out')
    if timeout:
        notes.append(timeout.lower())
        failures.append(('(run)', timeout + ' (hard timeout around swift test)', '`{}`'.format(name)))
    add_rows(environment, outcomes, notes, first)

    for test, outcome, _ in ends:
        if outcome != 'failed':
            continue
        found = issues.get(test) or [[None, 'failed (no issue line in the log)', 0]]
        for where, message, _ in found[:3]:
            failures.append((test_id(test) or test, message, '{} · `{}`'.format(where, name) if where else '`{}`'.format(name)))
        if len(found) > 3:
            failures.append((test_id(test) or test, '{} more issue{}'.format(len(found) - 3, 's' if len(found) > 4 else ''), '`{}`'.format(name)))
    if not summaries or summaries[-1].group(2) == 'failed':  # error lines in a passing run are test output, not failures
        for kind, message, where in errors[:10]:
            failures.append((kind, message, '{} · `{}`'.format(where, name) if where else '`{}`'.format(name)))
        if len(errors) > 10:
            failures.append(('(build)', '{} more error{}'.format(len(errors) - 10, 's' if len(errors) > 11 else ''), '`{}`'.format(name)))
        if not summaries and not errors and not timeout:
            tail = next((line for line in reversed(lines) if line.strip()), '(empty log)')
            failures.append(('(run)', 'The log ends without a summary; its last line: ' + tail, '`{}`'.format(name)))

    def result_of(record_id):
        base = test_id(record_id) or record_id
        seen = {o for test, o, _ in ends if test == base or test.startswith(base + ' ')}
        return 'Failed' if 'failed' in seen else 'Passed' if 'passed' in seen else 'Skipped' if seen else '—'

    for record_id, value in records[:MAX_RECORDS]:
        metrics.append((record_id.strip(), 'macOS · `{}`'.format(name), value, '—',
                        result_of(record_id)))
    if len(records) > MAX_RECORDS:
        metrics.append(('…', 'macOS · `{}`'.format(name), '{} more records in the log'.format(len(records) - MAX_RECORDS), '', ''))


for path in paths:
    if path.rstrip('/').endswith('.xcresult'):
        read_bundle(path)
    else:
        read_log(path)

# --- Header

commit = run('git', '-C', root, 'rev-parse', '--short=7', 'HEAD') or 'unknown commit'
if commit != 'unknown commit' and subprocess.call(['git', '-C', root, 'diff', '--quiet', 'HEAD'],
                                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 1:
    commit += '-dirty'
host = run('sw_vers', '-productVersion')
places = list(devices)
if any(not p.rstrip('/').endswith('.xcresult') for p in paths):
    places.append('macOS {} host'.format(host) if host else 'macOS host')
day = datetime.datetime.fromtimestamp(min(starts)) if starts else datetime.datetime.now()

env = os.environ
if env.get('GITHUB_ACTIONS') == 'true':
    event, ref = env.get('GITHUB_EVENT_NAME', ''), env.get('GITHUB_REF', '')
    pull = re.match(r'refs/pull/(\d+)/', ref)
    trigger = ('CI (pull request #{})'.format(pull.group(1)) if event == 'pull_request' and pull else
               'CI (push to {})'.format(env.get('GITHUB_REF_NAME', '?')) if event == 'push' else 'CI ({})'.format(event or '?'))
    if env.get('GITHUB_RUN_ID'):
        trigger += ' · [run {}]({}/{}/actions/runs/{})'.format(env['GITHUB_RUN_ID'], env.get('GITHUB_SERVER_URL', 'https://github.com'),
                                                                  env.get('GITHUB_REPOSITORY', ''), env['GITHUB_RUN_ID'])
    if env.get('ImageOS'):
        trigger += ' · runner image {} {} ({})'.format(env['ImageOS'], env.get('ImageVersion', ''), env.get('RUNNER_ARCH', '?'))
else:
    trigger = 'local'

developer = env.get('DEVELOPER_DIR') or run('xcode-select', '-p')
try:
    with open(os.path.join(developer, '..', 'version.plist'), 'rb') as file:
        version = plistlib.load(file)
    xcode = 'Xcode {} ({})'.format(version['CFBundleShortVersionString'], version['ProductBuildVersion'])
except (OSError, KeyError, ValueError, plistlib.InvalidFileException):
    xcode = 'Xcode unknown'
swift = re.search(r'Apple Swift version (\S+)', run('xcrun', 'swift', '-version'))
sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version')
toolchain = ' · '.join([xcode, 'Swift ' + (swift.group(1) if swift else 'unknown'),
                             'iOS Simulator SDK ' + (sdk or 'unknown'), 'macOS ' + (host or 'unknown')])

data = []
fixtures = run('git', '-C', root, 'rev-parse', '--short=7', 'HEAD:Fixtures')
if fixtures:
    data.append('Fixtures tree ' + fixtures)
try:
    with open(os.path.join(root, 'Packages/ReadStairCore/Sources/ReadStairCore/Resources/lexicon/bands.tsv'), 'rb') as file:
        data.append('word list bands.tsv sha256 ' + hashlib.sha256(file.read()).hexdigest()[:8] + '…')
except OSError:
    pass

# --- Report

out = ['# Test results · {} · {} · {}'.format(day.strftime('%Y-%m-%d'), commit, ' + '.join(places) or 'no device'), '',
       '- Trigger: ' + trigger,
       '- Toolchain: ' + toolchain]
if data:
    out.append('- Test data: ' + ' · '.join(data))
out += ['', '## Summary', '', '| Layer | Environment | Tests | Passed | Failed | Skipped | Notes |', '|---|---|---|---|---|---|---|']
totals = [0, 0, 0]
for row in rows:
    if row['known']:
        counts = [row['passed'], row['failed'], row['skipped']]
        totals = [a + b for a, b in zip(totals, counts)]
        numbers = [str(sum(counts))] + [str(c) for c in counts]
    else:
        numbers = ['?'] * 4
    out.append('| {} | {} | {} | {} |'.format(row['layer'], row['environment'], ' | '.join(numbers), cell('; '.join(row['notes']))))
incomplete = 'incomplete: a result could not be read' if any(not r['known'] for r in rows) else ''
out.append('| **Total** | | **{}** | **{}** | **{}** | **{}** | {} |'.format(sum(totals), totals[0], totals[1], totals[2], incomplete))

out += ['', '## Failure details', '']
if failures:
    out += ['| ID | Symptom | Screenshot/log | Handling |', '|---|---|---|---|']
    for ident, symptom, where in failures[:MAX_FAILURES]:
        out.append('| {} | {} | {} | |'.format(cell(ident, 120), cell(symptom), cell(where, 200)))
    if len(failures) > MAX_FAILURES:
        out.append('| … | {} more | | |'.format(len(failures) - MAX_FAILURES))
else:
    out.append('None.')

if metrics:
    out += ['', '## Performance metrics', '', '| ID | Environment | Value | Threshold | Result |', '|---|---|---|---|---|']
    for ident, where, value, threshold, result in metrics:
        out.append('| {} | {} | {} | {} | {} |'.format(cell(ident, 120), cell(where, 200), cell(value), cell(threshold), cell(result)))

print('\n'.join(out))
PY
