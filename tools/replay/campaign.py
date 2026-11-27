"""Run a manifest of scripted replays unattended across fixture lanes and write one report.

Each manifest entry (tools/replay/campaigns/full.json) is one scripted.py (Solo)
or scripted_mp.py (dedicated server) invocation. Solo entries run one after
another on each --lanes worker, mp entries one at a time on --mp-lane (the
shared install without one). Every entry writes its runner's own folder under
the campaign folder, and campaign.json and campaign.md are rewritten after each
entry. The runners own the fixture leases, the native proxy and the game: this
script starts them, waits, reads their batch.json and drops the BMP copies of
captures that already have a PNG. It never kills a runner.

  python tools/replay/campaign.py --manifest tools/replay/campaigns/full.json --plan
  python tools/replay/campaign.py --manifest tools/replay/campaigns/full.json --candidate <release> --lanes a,b --mp-lane c

See tools/replay/SCRIPTS.md ("Campaigns").
"""
import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import fixture

SCHEMA = 'kf2vr/replay-campaign/1'
RUNNERS = {'solo': 'tools/replay/scripted.py', 'mp': 'tools/replay/scripted_mp.py'}
KINDS = ('logic', 'visual', 'evidence')
TIERS = ('core', 'issue', 'long')
FIELDS = {'id', 'runner', 'script', 'weapons', 'vars', 'matrix', 'clients', 'zeds', 'extra', 'after', 'areas', 'kind',
          'tier', 'issues', 'notes', 'skip', 'timeout'}
# The campaign sets these on every command line; an entry's `extra` must not.
OWNED_ARGS = ('--script', '--candidate', '--output', '--fixture', '--wait', '--plan', '--weapons', '--var', '--matrix',
              '--clients', '--zeds')
# scripted.py options scripted_mp.py does not have.
SOLO_ONLY_ARGS = ('--loops', '--per-launch', '--parallel', '--families', '--dual-only', '--isolated', '--yield-gap',
                  '--fail-fast', '--timeout')
ID = re.compile(r'[a-z0-9][a-z0-9._-]{0,63}')
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
MATRIX_KEY = re.compile(r'(?:var\.)?[A-Za-z_][A-Za-z0-9_]*')
ALL_WEAPONS = 140                  # catalog size estimate for `--weapons all` timeouts
PLAN_STAND_INS = ('9mm', 'ar15')   # `all` needs a game launch for the catalog; compile these instead
FINISHED = ('done', 'skipped')


# -- manifest -------------------------------------------------------------------------

def load_manifest(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    return data['entries'] if isinstance(data, dict) and 'entries' in data else data


def _arg_name(arg):
    return arg.split('=', 1)[0]


def validate(entries, root=ROOT):
    """Every problem in the manifest, as text; empty when it is usable."""
    if not isinstance(entries, list) or not entries:
        return ['The manifest must be a non-empty JSON list of entries']
    errors, seen = [], {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            errors.append(f'entry {index+1}: not an object')
            continue
        where = f"entry {entry.get('id', index+1)}"
        problem = lambda text: errors.append(f'{where}: {text}')
        unknown = sorted(set(entry) - FIELDS)
        if unknown:
            problem(f'unknown fields {unknown}')
        if not isinstance(entry.get('id'), str) or not ID.fullmatch(entry['id']):
            problem(f'id must match {ID.pattern}')
        elif entry['id'] in seen:
            problem('duplicate id')
        runner = entry.get('runner')
        if runner not in RUNNERS:
            problem(f'runner must be one of {sorted(RUNNERS)}')
        script = entry.get('script')
        if not isinstance(script, str) or not script.endswith('.kfs'):
            problem('script must be a repository-relative .kfs path')
        elif not (Path(root)/script).is_file():
            problem(f'no script at {script}')
        if entry.get('kind') not in KINDS:
            problem(f'kind must be one of {KINDS}')
        if entry.get('tier') not in TIERS:
            problem(f'tier must be one of {TIERS}')
        areas = entry.get('areas')
        if not isinstance(areas, list) or not areas or not all(isinstance(a, str) and a for a in areas):
            problem('areas must be a non-empty list of tags')
        weapons = entry.get('weapons', [])
        if not isinstance(weapons, list) or not all(isinstance(w, str) and w and ',' not in w for w in weapons):
            problem('weapons must be a list of names without commas')
        elif 'all' in weapons and runner != 'solo':
            problem('--weapons all needs the solo runner (its catalog launch)')
        variables = entry.get('vars', {})
        if not isinstance(variables, dict) or not all(isinstance(k, str) and NAME.fullmatch(k) and isinstance(v, str) and v
                                                      for k, v in variables.items()):
            problem('vars must map names to non-empty strings')
        matrix = entry.get('matrix', {})
        if not isinstance(matrix, dict) or not all(
                isinstance(k, str) and MATRIX_KEY.fullmatch(k) and isinstance(v, list) and v
                and all(isinstance(x, str) and x and ',' not in x for x in v) for k, v in matrix.items()):
            problem('matrix must map Key or var.name to a non-empty list of values')
        if 'clients' in entry and (runner != 'mp' or entry['clients'] not in (1, 2, 3)):
            problem('clients is 1 to 3 and only for the mp runner')
        if 'zeds' in entry and (runner != 'mp' or not isinstance(entry['zeds'], bool)):
            problem('zeds is a boolean and only for the mp runner')
        extra = entry.get('extra', [])
        if not isinstance(extra, list) or not all(isinstance(a, str) for a in extra):
            problem('extra must be a list of arguments')
        else:
            owned = [a for a in extra if _arg_name(a) in OWNED_ARGS]
            if owned:
                problem(f'extra must not set {owned}: the campaign sets them')
            if runner == 'mp':
                missing = [a for a in extra if _arg_name(a) in SOLO_ONLY_ARGS]
                if missing:
                    problem(f'scripted_mp.py has no {missing}')
        issues = entry.get('issues', [])
        if not isinstance(issues, list) or not all(isinstance(n, int) and n > 0 for n in issues):
            problem('issues must be a list of issue numbers')
        if 'notes' in entry and not isinstance(entry['notes'], str):
            problem('notes must be text')
        if 'skip' in entry and not (isinstance(entry['skip'], str) and entry['skip'].strip()):
            problem('skip must be a reason')
        if 'timeout' in entry and not (isinstance(entry['timeout'], int) and entry['timeout'] > 0):
            problem('timeout must be a number of seconds')
        if 'after' in entry:
            before = seen.get(entry['after'])
            if before is None:
                problem(f"after names {entry['after']!r}, which is not an earlier entry")
            elif before.get('runner') != runner:
                problem('after must name an entry of the same runner')
        if isinstance(entry.get('id'), str):
            seen.setdefault(entry['id'], entry)
    return errors


def select(entries, only=(), areas=(), tiers=(), kinds=()):
    """The entries the filters keep, in manifest order. Empty filters keep everything."""
    picked = []
    for entry in entries:
        if only and entry['id'] not in only:
            continue
        if areas and not set(areas) & set(entry['areas']):
            continue
        if tiers and entry['tier'] not in tiers:
            continue
        if kinds and entry['kind'] not in kinds:
            continue
        picked.append(entry)
    return picked


def units(entries):
    """Ordered work units: an entry with `after` joins its predecessor's unit, so
    the chain runs in order on one lane. Units go core, then issue, then long."""
    found, by_id = [], {}
    for entry in entries:
        unit = by_id.get(entry.get('after'))
        if unit is None:
            unit = []
            found.append(unit)
        unit.append(entry)
        by_id[entry['id']] = unit
    return sorted(found, key=lambda unit: TIERS.index(unit[0]['tier']))


def fingerprint(entry):
    """Changes when anything that decides what runs changes (not notes or tags)."""
    keys = ('runner', 'script', 'weapons', 'vars', 'matrix', 'clients', 'zeds', 'extra')
    text = json.dumps({k: entry.get(k) for k in keys}, sort_keys=True)
    return hashlib.sha256(text.encode('utf-8')).hexdigest()[:16]


# -- one entry --------------------------------------------------------------------------

def build_command(entry, *, candidate, output, lane=None, wait=0, python=None, root=ROOT):
    """The runner command line for one entry."""
    command = [python or sys.executable, str(Path(root)/RUNNERS[entry['runner']]), '--script', str(Path(root)/entry['script']),
               '--candidate', str(candidate), '--output', str(output), '--wait', str(int(wait))]
    if lane:
        command += ['--fixture', lane]
    if entry.get('weapons'):
        command += ['--weapons', ','.join(entry['weapons'])]
    for key, value in entry.get('vars', {}).items():
        command += ['--var', f'{key}={value}']
    for key, values in entry.get('matrix', {}).items():
        command += ['--matrix', f'{key}={",".join(values)}']
    if entry['runner'] == 'mp':
        if entry.get('clients'):
            command += ['--clients', str(entry['clients'])]
        if entry.get('zeds'):
            command.append('--zeds')
    return command + list(entry.get('extra', []))


def case_count(entry, all_weapons=ALL_WEAPONS):
    weapons = entry.get('weapons') or [None]
    count = sum(all_weapons if weapon == 'all' else 1 for weapon in weapons)
    for values in entry.get('matrix', {}).values():
        count *= len(values)
    extra = entry.get('extra', [])
    for i, arg in enumerate(extra):
        if arg == '--loops' and i + 1 < len(extra):
            count *= int(extra[i+1])
        elif arg.startswith('--loops='):
            count *= int(arg.split('=', 1)[1])
    return count


def child_timeout(entry, case_seconds, wait):
    """Generous: the queue wait, the observer compile and catalog launch, every
    case at 1.5x its script deadline, and a relaunch and yield gap per chunk."""
    if entry.get('timeout'):
        return int(entry['timeout'])
    cases = case_count(entry)
    chunks = math.ceil(cases / 12)
    return int(wait + 1800 + cases * (case_seconds + 90) * 1.5 + chunks * 270)


def compile_entry(entry, root=ROOT):
    """Compiles every case the runner would, with the runner's own code. `all`
    is replaced by stand-in guns. Returns [(weapon, label, Compiled)]."""
    import scripted
    weapons = [w for w in entry.get('weapons', []) if w != 'all']
    if 'all' in entry.get('weapons', []):
        weapons += [w for w in PLAN_STAND_INS if w not in weapons]
    opts = SimpleNamespace(var=[f'{k}={v}' for k, v in entry.get('vars', {}).items()])
    matrix = [f'{k}={",".join(v)}' for k, v in entry.get('matrix', {}).items()]
    script = Path(root)/entry['script']
    return [(weapon, label, scripted.compile_case(opts, script, weapon, overrides))
            for label, overrides in scripted.settings_cases(matrix) for weapon in (weapons or [None])]


def rel(path, base):
    try:
        return os.path.relpath(path, base).replace('\\', '/')
    except ValueError:   # another drive
        return str(path)


def read_cases(output, campaign_root):
    """Per-case rows from a runner's batch.json, with links relative to the campaign root."""
    rows = json.loads((Path(output)/'batch.json').read_text(encoding='utf-8'))
    cases = []
    for row in rows:
        summary = Path(row['summary']) if row.get('summary') else None
        if summary is not None and summary.is_dir():   # an mp runner error names its folder
            summary = summary/'batch.md'
        index = summary.parent/'captures'/'index.html' if summary is not None else None
        cases.append(dict(
            weapon=row.get('weapon'), settings=row.get('settings') or '', client=row.get('client'),
            loop=row.get('loop'), passed=bool(row.get('passed')), ended=row.get('ended'),
            failed=list(row.get('failed') or []), errors=list(row.get('errors') or []),
            captures=int(row.get('captures') or 0),
            summary=rel(summary, campaign_root) if summary is not None else None,
            captures_index=rel(index, campaign_root) if index is not None and index.is_file() else None))
    return cases


def prune_bmps(folder, campaign_root):
    """Deletes each .bmp capture that has a same-named .png beside it (or, for
    captures/originals/, in captures/). Only inside the campaign's own folder."""
    folder, campaign_root = Path(folder).resolve(), Path(campaign_root).resolve()
    if folder == campaign_root or not folder.is_relative_to(campaign_root) or not folder.is_dir():
        return 0, 0
    count = size = 0
    for bmp in folder.rglob('*'):
        if bmp.suffix.lower() != '.bmp' or bmp.is_symlink() or not bmp.is_file():
            continue
        if not bmp.resolve().is_relative_to(folder):
            continue
        twins = (bmp.with_suffix('.png'), bmp.parent.parent/(bmp.stem+'.png'))
        if any(png.is_file() and png.stat().st_size > 0 for png in twins):
            size += bmp.stat().st_size
            bmp.unlink()
            count += 1
    return count, size


# -- campaign state and report ------------------------------------------------------------

def new_record(entry):
    record = dict(id=entry['id'], runner=entry['runner'], script=entry['script'], kind=entry['kind'], tier=entry['tier'],
                  areas=list(entry['areas']), issues=list(entry.get('issues', [])), notes=entry.get('notes', ''),
                  fingerprint=fingerprint(entry), status='pending', cases=[])
    if entry.get('skip'):
        record.update(status='skipped', skip=entry['skip'])
    return record


def merge_resume(previous, entries):
    """Records for a resumed campaign: finished entries whose definition did not
    change are kept; everything else selected runs again. Records of entries not
    selected this time stay in the report as they were."""
    records = {r['id']: r for r in previous.get('entries', [])}
    for record in records.values():
        if record.get('status') == 'running':
            record['status'] = 'interrupted'
    for entry in entries:
        record = records.get(entry['id'])
        keep = (record is not None and record.get('status') in FINISHED and record.get('fingerprint') == fingerprint(entry)
                and not (record['status'] == 'skipped' and not entry.get('skip')))
        records[entry['id']] = record if keep else new_record(entry)   # keeps the earlier report order
    return list(records.values())


def summarize(records):
    statuses = {}
    for record in records:
        statuses[record['status']] = statuses.get(record['status'], 0) + 1
    cases = [c for r in records if r['status'] == 'done' for c in r['cases']]
    passed = sum(c['passed'] for c in cases)
    return dict(entries=len(records), statuses=statuses, cases=len(cases), passed=passed, failed=len(cases) - passed)


def failed(records):
    """True when any non-skipped entry has a failed case or did not finish with results."""
    for record in records:
        if record['status'] == 'skipped':
            continue
        if record['status'] != 'done' or not record['cases'] or not all(c['passed'] for c in record['cases']):
            return True
    return False


def _short(weapon):
    return re.sub(r'^(KFGameContent\.KFWeap_|KF2VR\.VRWeap_)', '', weapon or '-', flags=re.I)


def _cell(text):
    return str(text).replace('|', '\\|').replace('\n', ' ')


def first_failure(case):
    if case['failed']:
        return case['failed'][0]
    if case['errors']:
        return case['errors'][0]
    return f"ended {case['ended']}"


def _links(record):
    out = record.get('output')
    links = [f'[batch]({out}/batch.md)'] if out and record['status'] == 'done' else []
    summaries = list(dict.fromkeys(c['summary'] for c in record['cases'] if c.get('summary')))
    indexes = list(dict.fromkeys(c['captures_index'] for c in record['cases'] if c.get('captures_index')))
    links += [f'[summary{"" if len(summaries) == 1 else " "+str(i+1)}]({s})' for i, s in enumerate(summaries)]
    links += [f'[captures{"" if len(indexes) == 1 else " "+str(i+1)}]({s})' for i, s in enumerate(indexes)]
    if record.get('log'):
        links.append(f"[runner log]({record['log']})")
    return ' '.join(links)


def report(state, limit=40):
    """campaign.md text."""
    records = state['entries']
    totals = summarize(records)
    s = totals['statuses']
    lanes = ', '.join(state.get('lanes') or []) or 'shared install'
    lines = [f"# Replay campaign {state['name']}", '',
             f"Candidate `{state.get('candidate') or '-'}` · manifest `{state.get('manifest')}` · solo lanes {lanes} · "
             f"mp lane {state.get('mp_lane') or 'shared install'}",
             f"Started {state.get('started_utc')} · updated {state.get('updated_utc')}"
             + (f" · finished {state['finished_utc']}" if state.get('finished_utc') else ' · running'), '',
             f"**Entries** {totals['entries']}: {s.get('done', 0)} done, {s.get('skipped', 0)} skipped, "
             f"{s.get('timeout', 0)} timed out, {s.get('error', 0)} runner errors, {s.get('running', 0)} running, "
             f"{s.get('pending', 0) + s.get('interrupted', 0)} not run",
             f"**Cases** {totals['passed']}/{totals['cases']} passed, {totals['failed']} failed", '',
             'A scripted pass is evidence, not headset or online acceptance.', '', '## By area', '']
    for area in sorted({a for r in records for a in r['areas']}):
        rows = [r for r in records if area in r['areas'] and r['status'] != 'skipped']
        if not rows:
            continue
        lines += [f'### {area}', '', '| entry | script | runner | kind | cases | failures | links |',
                  '| --- | --- | --- | --- | --- | --- | --- |']
        for r in rows:
            if r['status'] == 'done':
                bad = [c for c in r['cases'] if not c['passed']]
                cases = f"{len(r['cases']) - len(bad)}/{len(r['cases'])}"
                notes = [f"{_short(c['weapon'])}{' '+c['settings'] if c['settings'] else ''}"
                         f"{' client '+str(c['client']) if c.get('client') else ''}: {first_failure(c)}" for c in bad[:limit]]
                if len(bad) > limit:
                    notes.append(f'and {len(bad) - limit} more (campaign.json)')
                failures = '<br>'.join(_cell(n) for n in notes) or ('no cases' if not r['cases'] else '')
            else:
                cases = r['status']
                failures = _cell(r.get('error', ''))
            lines.append(f"| {r['id']} | {Path(r['script']).name} | {r['runner']} | {r['kind']} | {cases} | {failures} | {_links(r)} |")
        lines.append('')
    visual = [r for r in records if r['kind'] == 'visual' and r['status'] == 'done']
    if visual:
        lines += ['## Frames to review', '']
        for r in visual:
            indexes = list(dict.fromkeys(c['captures_index'] for c in r['cases'] if c.get('captures_index')))
            frames = sum(c['captures'] for c in r['cases'])
            links = ' '.join(f'[{i+1}]({x})' for i, x in enumerate(indexes)) or 'no captures index'
            lines.append(f"- {r['id']} ({Path(r['script']).name}, {frames} frames): {links}")
        lines.append('')
    evidence = [r for r in records if r['kind'] == 'evidence' and r['status'] == 'done']
    if evidence:
        lines += ['## Logs to read (evidence)', '']
        lines += [f"- {r['id']} ({Path(r['script']).name}): {_links(r)}" + (f" · {r['notes']}" if r.get('notes') else '')
                  for r in evidence]
        lines.append('')
    unfinished = [r for r in records if r['status'] not in FINISHED]
    if unfinished:
        lines += ['## Not finished', '']
        lines += [f"- {r['id']}: {r['status']}" + (f" · {_cell(r['error'])}" if r.get('error') else '')
                  + (f" · {_links(r)}" if r.get('log') else '') for r in unfinished]
        lines.append('')
    skipped = [r for r in records if r['status'] == 'skipped']
    if skipped:
        lines += ['## Skipped', '']
        lines += [f"- {r['id']} ({r['script']}): {r.get('skip', '')}" for r in skipped]
        lines.append('')
    return '\n'.join(lines)


def _now():
    return datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')


def _write(path, text):
    temporary = path.with_name(path.name+'.tmp')
    temporary.write_text(text, encoding='utf-8')
    os.replace(temporary, path)


class Campaign:
    def __init__(self, root, state, opts):
        self.root, self.state, self.opts = root, state, opts
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.running = {}    # id -> Popen
        self.orphans = []    # (entry, record, Popen, output, log) past their timeout

    def save(self):
        with self.lock:
            self.state['updated_utc'] = _now()
            _write(self.root/'campaign.json', json.dumps(self.state, indent=2))
            _write(self.root/'campaign.md', report(self.state)+'\n')

    def record(self, entry_id):
        return next(r for r in self.state['entries'] if r['id'] == entry_id)

    def fresh_output(self, entry_id):
        output, attempt = self.root/entry_id, 1
        while output.exists() or (self.root/'logs'/(output.name+'.log')).exists():
            attempt += 1
            output = self.root/f'{entry_id}~{attempt}'
        return output

    def run_entry(self, entry, lane):
        record = self.record(entry['id'])
        if record['status'] in FINISHED:
            return
        try:
            seconds = max(int(c.setup['timeout']) for _, _, c in compile_entry(entry))
        except Exception as error:
            record.update(status='error', error=f'compile: {error}', finished_utc=_now())
            self.save()
            return
        output = self.fresh_output(entry['id'])
        log = self.root/'logs'/(output.name+'.log')
        log.parent.mkdir(exist_ok=True)
        command = build_command(entry, candidate=self.opts.candidate, output=output, lane=lane, wait=self.opts.wait)
        timeout = child_timeout(entry, seconds, self.opts.wait)
        record.update(status='running', lane=lane or 'shared', command=subprocess.list2cmdline(command),
                      output=rel(output, self.root), log=rel(log, self.root), started_utc=_now(), timeout_s=timeout,
                      cases=[], error='')
        record.pop('finished_utc', None)
        self.save()
        print(f'KF2VR_CAMPAIGN start id={entry["id"]} lane={lane or "shared"} timeout={timeout}s', flush=True)
        env = {k: v for k, v in os.environ.items() if k.upper() != 'KF2VR_FIXTURE'}   # the lane comes from --fixture
        env.update(PYTHONIOENCODING='utf-8', PYTHONUNBUFFERED='1')
        started = time.monotonic()
        with log.open('wb') as out:
            # Its own process group: a Ctrl-C here never reaches a running replay.
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL, stdout=out,
                                       stderr=subprocess.STDOUT,
                                       creationflags=getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0))
        with self.lock:
            self.running[entry['id']] = process
        try:
            while process.poll() is None:
                if time.monotonic() - started > timeout:
                    # Never kill a replay: a killed runner leaves its proxy in the game folder.
                    record.update(status='timeout', error=f'still running after {timeout} s (pid {process.pid}); '
                                  'left running, collected at the end if it has finished', finished_utc=_now())
                    with self.lock:
                        self.orphans.append((entry, record, process, output, log))
                    self.save()
                    print(f'KF2VR_CAMPAIGN timeout id={entry["id"]} pid={process.pid}', flush=True)
                    return
                time.sleep(5)
        finally:
            with self.lock:
                self.running.pop(entry['id'], None)
        record['seconds'] = round(time.monotonic() - started)
        self.collect(record, process, output, log)

    def collect(self, record, process, output, log):
        record['exit_code'] = process.returncode
        record['finished_utc'] = _now()
        if (output/'batch.json').is_file():
            try:
                record['cases'] = read_cases(output, self.root)
                record['status'] = 'done'
                record['error'] = '' if record['cases'] else 'the runner reported no cases'
            except (OSError, ValueError, KeyError) as error:
                record.update(status='error', error=f'unreadable batch.json: {error}')
        else:
            tail = log.read_text(encoding='utf-8', errors='replace').strip().splitlines()[-6:] if log.exists() else []
            record.update(status='error', error=f'no batch.json (exit {process.returncode}): ' + ' / '.join(tail)[-600:])
        if not self.opts.keep_bmp:
            count, size = prune_bmps(output, self.root)
            record['bmp_deleted'], record['bmp_mb_freed'] = count, round(size / 2**20, 1)
        self.save()
        bad = sum(not c['passed'] for c in record['cases'])
        print(f'KF2VR_CAMPAIGN end id={record["id"]} status={record["status"]} cases={len(record["cases"])} failed={bad}',
              flush=True)

    def worker(self, lane, queue):
        while not self.stop.is_set():
            with self.lock:
                unit = queue.pop(0) if queue else None
            if unit is None:
                return
            for entry in unit:
                if self.stop.is_set():
                    return
                try:
                    self.run_entry(entry, lane)
                except Exception as error:   # one broken entry must not stop the lane
                    record = self.record(entry['id'])
                    record.update(status='error', error=f'campaign: {error}', finished_utc=_now())
                    self.save()

    def collect_orphans(self):
        for entry, record, process, output, log in self.orphans:
            if process.poll() is not None:
                self.collect(record, process, output, log)
                record['error'] = (record.get('error') or '') + ' (finished after its campaign timeout)'
        self.save()


def plan(entries, opts, root):
    broken = 0
    for unit in units(entries):
        for entry in unit:
            output = root/entry['id']
            lane = opts.mp_lane if entry['runner'] == 'mp' else (opts.lanes[0] if opts.lanes else None)
            command = build_command(entry, candidate=opts.candidate or '<candidate>', output=output, lane=lane,
                                    wait=opts.wait)
            head = f"# {entry['id']} [{entry['runner']} {entry['tier']} {entry['kind']}] cases~{case_count(entry)}"
            if entry.get('after'):
                head += f" after {entry['after']}"
            print(head)
            if entry.get('skip'):
                print(f"#   SKIPPED: {entry['skip']}")
            print(subprocess.list2cmdline(command))
            try:
                cases = compile_entry(entry)
                seconds = max(int(c.setup['timeout']) for _, _, c in cases)
                stand_in = ' (weapons all: compiled with stand-ins '+', '.join(PLAN_STAND_INS)+')' \
                    if 'all' in entry.get('weapons', []) else ''
                print(f'#   compiled {len(cases)} cases{stand_in}; timeout {child_timeout(entry, seconds, opts.wait)} s')
            except Exception as error:
                print(f'#   COMPILE FAILED: {error}')
                broken += 0 if entry.get('skip') else 1
    print(f'# {len(entries)} entries, {broken} failed to compile')
    return 1 if broken else 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--manifest', type=Path, default=HERE/'campaigns'/'full.json')
    p.add_argument('--candidate', type=Path, help='Absolute unselected release directory from build-kf2vr.ps1 -NoSelect')
    p.add_argument('--lanes', default='', help='Solo fixture lanes (commas); each runs its entries one after another')
    p.add_argument('--mp-lane', help='Fixture lane for the mp entries (default: the shared install)')
    p.add_argument('--only', default='', help='Entry ids (commas)')
    p.add_argument('--areas', default='', help='Keep entries with any of these area tags (commas)')
    p.add_argument('--tier', default='', help='core, issue, long (commas)')
    p.add_argument('--kind', default='', help='logic, visual, evidence (commas)')
    p.add_argument('--output', type=Path, help='Campaign folder (default build/scripted-replay/campaign-<UTC stamp>)')
    p.add_argument('--resume', type=Path, help='Continue a campaign folder: finished, unchanged entries are kept')
    p.add_argument('--plan', action='store_true', help='Print each entry\'s command line and compile its cases; launch nothing')
    p.add_argument('--keep-bmp', action='store_true', help='Keep the BMP originals of captures that have a PNG')
    p.add_argument('--wait', type=int, default=3600, help='Seconds each runner queues for its game slot')
    opts = p.parse_args(argv)
    split = lambda text: [x for x in text.split(',') if x]
    opts.lanes = split(opts.lanes)
    for lane in opts.lanes + ([opts.mp_lane] if opts.mp_lane else []):
        if not fixture.LANE.fullmatch(lane):
            p.error(f'Lane names must match {fixture.LANE.pattern}: {lane!r}')
    if len(set(opts.lanes)) != len(opts.lanes):
        p.error('A lane may run only one worker')
    try:
        entries = load_manifest(opts.manifest)
    except (OSError, ValueError) as error:
        p.error(f'Cannot read the manifest: {error}')
    problems = validate(entries)
    if problems:
        p.error('Manifest problems:\n  ' + '\n  '.join(problems))
    selected = select(entries, set(split(opts.only)), split(opts.areas), split(opts.tier), split(opts.kind))
    unknown = set(split(opts.only)) - {e['id'] for e in entries}
    if unknown:
        p.error(f'Unknown entry ids: {sorted(unknown)}')
    if not selected:
        p.error('No entry matches the filters')
    if opts.output and opts.resume:
        p.error('--output and --resume are exclusive')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
    root = (opts.resume or opts.output or ROOT/'build/scripted-replay'/f'campaign-{stamp}').resolve()
    if opts.plan:
        return plan(selected, opts, root)
    if not opts.candidate or not opts.candidate.is_absolute() or not opts.candidate.is_dir():
        p.error('--candidate <absolute release directory> is required to run')
    for lane in opts.lanes + ([opts.mp_lane] if opts.mp_lane else []):
        if not fixture.game_root(lane).is_dir():
            p.error(f'No fixture for lane {lane}: python tools/replay/fixture.py create {lane}')
    if opts.resume:
        if not (root/'campaign.json').is_file():
            p.error(f'Nothing to resume at {root}')
        previous = json.loads((root/'campaign.json').read_text(encoding='utf-8'))
        records = merge_resume(previous, selected)
        name, started = previous.get('name', root.name), previous.get('started_utc', _now())
    else:
        if root.exists():
            p.error('Output exists; choose a fresh directory or --resume it')
        root.mkdir(parents=True)
        records, name, started = [new_record(e) for e in selected], root.name, _now()
    state = dict(schema=SCHEMA, name=name, manifest=rel(opts.manifest.resolve(), ROOT), candidate=str(opts.candidate),
                 lanes=opts.lanes, mp_lane=opts.mp_lane, started_utc=started, updated_utc=_now(), finished_utc=None,
                 entries=records)
    campaign = Campaign(root, state, opts)
    campaign.save()
    import scripted   # noqa: F401  (load the runner's compiler once, before the worker threads)
    solo = units([e for e in selected if e['runner'] == 'solo'])
    multi = units([e for e in selected if e['runner'] == 'mp'])
    if opts.lanes:
        workers = [(lane, solo) for lane in opts.lanes] + [(opts.mp_lane, multi)]
    elif opts.mp_lane:
        workers = [(None, solo), (opts.mp_lane, multi)]
    else:
        workers = [(None, solo + multi)]   # everything in turn on the shared install
    threads = [threading.Thread(target=campaign.worker, args=w, daemon=True) for w in workers if w[1]]
    print(f'KF2VR_CAMPAIGN output={root} entries={len(selected)} workers={len(threads)}', flush=True)
    for thread in threads:
        thread.start()
    try:
        while any(t.is_alive() for t in threads):
            for thread in threads:
                thread.join(timeout=1)
    except KeyboardInterrupt:
        campaign.stop.set()
        print('KF2VR_CAMPAIGN stopping: no new entries; waiting for the running replays to finish '
              '(Ctrl-C again leaves them running and exits)', flush=True)
        try:
            while any(t.is_alive() for t in threads):
                for thread in threads:
                    thread.join(timeout=1)
        except KeyboardInterrupt:
            with campaign.lock:
                left = {k: p.pid for k, p in campaign.running.items()}
            print(f'KF2VR_CAMPAIGN leaving running replays: {left}', flush=True)
            campaign.save()
            return 130
    campaign.collect_orphans()
    state['finished_utc'] = _now()
    campaign.save()
    totals = summarize(state['entries'])
    print(f"KF2VR_CAMPAIGN done cases={totals['passed']}/{totals['cases']} passed statuses={totals['statuses']} "
          f"report={root/'campaign.md'}", flush=True)
    return 1 if failed(state['entries']) else 0


if __name__ == '__main__':
    sys.exit(main())
