"""Live control of a scripted replay: drive a running game one statement at a time.

  python tools/replay/live.py start --candidate <release dir> --fixture live [--script x.kfs] [--weapons 9mm]
  python tools/replay/live.py send "draw right 9mm; do ready"
  python tools/replay/live.py probe R.ammo R.reserve reload.step
  python tools/replay/live.py shot            # prints the PNG's absolute path
  python tools/replay/live.py status | pause | resume | abort
  python tools/replay/live.py quit            # clean end; prints the summary
  python tools/replay/live.py repl            # a prompt for a person

`start` launches through scripted.py (or scripted_mp.py with --mp) in a
background session process and returns once the game is in live mode. That
process owns the fixture lease, the native deployment and the watchdogs, and
runs a broker on 127.0.0.1 that the game's KF2VRReplay.LiveLink dials out to
(an outbound connection: no firewall prompt). Every other command is a short
client of that broker: it compiles kfs with kfs.py (lib/common, lib/melee and
lib/mp macros, $weapon and --var values from the session), sends the ops,
waits for them, prints the runner's notes and exits.

Exit codes: 0 ok, 1 a check failed or the batch was aborted, 2 usage or
compile error, 3 session or game gone, 4 timed out (the ops keep running;
`abort` drops them). See tools/replay/SCRIPTS.md "Live control".
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
import traceback
from types import SimpleNamespace

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fixture
import kfs

ROOT = HERE.parents[1]
RUNS = ROOT/'build/scripted-replay'
SCRIPTS = HERE/'scripts'
LIBS = ('lib/common.kfs', 'lib/melee.kfs', 'lib/mp.kfs')
OK, CHECK_FAILED, USAGE, GONE, TIMED_OUT = 0, 1, 2, 3, 4
# The adapter holds the head-tracking tape's last sample (KF2VR_INPUT_REPLAY_HOLD),
# so a session can run for hours; it still quits itself after --minutes. A
# candidate built before that ends its tape after 50 minutes, so such a
# session is cut to OLD_TAPE_MINUTES.
MAX_MINUTES = 480
OLD_TAPE_MINUTES = 45


class LiveError(RuntimeError):
    def __init__(self, message, code=GONE):
        super().__init__(message)
        self.code = code


# ---- pure helpers (live_test.py) ---------------------------------------------

def relocate(ops, line_base):
    """Make a compiled batch position-independent: line ids move past the
    session's earlier lines, and repeat-until jumps (absolute `to=` indices
    within the batch) become relative `back=` jumps. if/else `skip=` jumps are
    relative already."""
    out = []
    for index, op in enumerate(ops):
        line, rest = op.split('|', 1)
        rest = re.sub(r'(?<=\|)to=(\d+)(?=\||$)', lambda m: f'back={index - int(m[1])}', rest)
        out.append(f'{int(line) + line_base}|{rest}')
    return out


def bind_live(ops, port, client):
    """Give every `live` op the broker port and this game's client number."""
    out = []
    for op in ops:
        parts = op.split('|')
        if parts[1:2] == ['live']:
            parts = [p for p in parts if not p.startswith(('port=', 'client='))] + [f'port={port}', f'client={client}']
        out.append('|'.join(parts))
    return out


def has_live(ops):
    return any(op.split('|')[1:2] == ['live'] for op in ops)


def fields(text, separator=None):
    """key=value tokens of a reply line (tab-separated for PROBE and STATUS)."""
    found = {}
    for token in text.split(separator):
        key, equals, value = token.partition('=')
        if equals:
            found[key.strip()] = value
    return found


def compile_statements(text, variables=None, resolve_weapon=None, macros=None):
    """Compile live statements with the shared macro libraries. Returns
    (ops, origins, new_macros). Launch-only statements are refused."""
    compiler = kfs.Compiler(variables, resolve_weapon, include_root=SCRIPTS)
    for lib in LIBS:
        compiler.compile_text(f'include {lib}\n', '<libs>')
    for name, (params, block) in (macros or {}).items():
        compiler.macros[name] = (params, block)
    known = dict(compiler.macros)
    compiler.out = kfs.Compiled()
    out = compiler.compile_text(text, '<live>')
    if out.settings or out.setup != kfs.Compiled().setup:
        raise kfs.ScriptError('<live>', 'setup, set and preset apply at launch only: start a new session '
                              'with live.py start --preset NAME / --set Key=Value')
    if out.log_checks:
        raise kfs.ScriptError('<live>', 'expect log / forbid log need the finished log; put them in a start --script')
    if has_live(out.ops):
        raise kfs.ScriptError('<live>', 'the session is live already')
    new = {name: value for name, value in compiler.macros.items() if known.get(name) is not value}
    return out.ops, out.origins, new


def launch_settings(preset=None, sets=()):
    """live.py start --preset NAME and --set Key=Value (repeatable) -> the bridge
    settings for the launch config, as a script's preset/set lines give them."""
    compiler = kfs.Compiler()
    if preset:
        compiler.do_preset('--preset', [preset])
    for item in sets:
        compiler.do_set('--set', [item])
    return compiler.out.settings


def note_text(text, origins):
    """A runner note `line=N t=T rest` as `t=T [origin] rest`."""
    match = re.match(r'line=(\d+) t=(\S+) ?(.*)', text)
    if not match:
        return text
    line = int(match[1])
    where = origins[line-1] if 0 < line <= len(origins) else 'runner'
    return f't={float(match[2]):.2f} [{where}] {match[3]}'


# ---- session files -------------------------------------------------------------

def write_json(path, data):
    path = Path(path)
    temporary = path.with_name(path.name+f'.{os.getpid()}.{threading.get_ident()}.tmp')
    temporary.write_text(json.dumps(data, indent=2), encoding='utf-8')
    for _ in range(40):
        try:
            temporary.replace(path)
            return
        except PermissionError:   # a reader holds it open for a moment
            time.sleep(0.05)
    temporary.replace(path)


def read_json(path, default=None):
    for _ in range(40):
        try:
            return json.loads(Path(path).read_text(encoding='utf-8'))
        except FileNotFoundError:
            return default
        except (PermissionError, json.JSONDecodeError):
            time.sleep(0.05)
    return default


SESSION_LOCK = threading.Lock()


def update_session(root, **changes):
    with SESSION_LOCK:
        data = read_json(Path(root)/'session.json', {}) or {}
        data.update(changes)
        write_json(Path(root)/'session.json', data)
        return data


def pointer(lane=None):
    return RUNS/(f'live-session-{lane}.json' if lane else 'live-session.json')


def find_session(explicit=None, lane=None):
    if explicit:
        root = Path(explicit).resolve()
    else:
        lane = lane or os.environ.get('KF2VR_FIXTURE') or None
        note = read_json(pointer(lane)) or (read_json(pointer()) if lane else None)
        if not note:
            raise LiveError('No live session; start one with live.py start (or pass --session <dir>)')
        root = Path(note['root'])
    session = read_json(root/'session.json')
    if not session:
        raise LiveError(f'No session.json in {root}')
    session['root'] = str(root)
    return session


class FileLock:
    """A cross-process lock file (O_EXCL), stale after 10 s."""
    def __init__(self, path):
        self.path = Path(path)

    def __enter__(self):
        deadline = time.monotonic() + 10
        while True:
            try:
                self.handle = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                return self
            except FileExistsError:
                if time.monotonic() > deadline:
                    self.path.unlink(missing_ok=True)   # a crashed command's lock
                time.sleep(0.02)

    def __exit__(self, *_):
        os.close(self.handle)
        self.path.unlink(missing_ok=True)


def allocate_lines(root, origins, label):
    """Give a batch's op line ids a session-unique range; returns the base.
    origins.json maps every id back to its source for printed notes."""
    with FileLock(Path(root)/'origins.lock'):
        known = read_json(Path(root)/'origins.json', []) or []
        write_json(Path(root)/'origins.json', known + [f'{label} {o}' if label else o for o in origins])
        return len(known)


def load_macros(root):
    data = read_json(Path(root)/'macros.json', {}) or {}
    return {name: (value['params'], value['block']) for name, value in data.items()}


def save_macros(root, new):
    if not new:
        return
    with FileLock(Path(root)/'macros.lock'):
        data = read_json(Path(root)/'macros.json', {}) or {}
        data.update({name: dict(params=params, block=block) for name, (params, block) in new.items()})
        write_json(Path(root)/'macros.json', data)


def process_alive(pid):
    import ctypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.restype = ctypes.c_void_p
    handle = kernel.OpenProcess(0x1000, False, int(pid))   # PROCESS_QUERY_LIMITED_INFORMATION
    if not handle:
        return False
    try:
        code = ctypes.c_ulong()
        kernel.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code))
        return code.value == 259   # STILL_ACTIVE
    finally:
        kernel.CloseHandle(ctypes.c_void_p(handle))


# ---- broker (inside the session process) --------------------------------------

def socket_lines(conn):
    buffer = b''
    while True:
        try:
            data = conn.recv(65536)
        except OSError:
            data = b''
        if not data:
            if buffer.strip():
                yield buffer.decode('latin-1').rstrip('\r')
            return
        buffer += data
        while b'\n' in buffer:
            line, buffer = buffer.split(b'\n', 1)
            yield line.decode('latin-1').rstrip('\r')


class Broker:
    """127.0.0.1 line relay between the games (HELLO game client=K) and live.py
    commands (HELLO cmd client=K). Game lines go to every command watching that
    client and to live-clientK.log; command lines go to that client's game."""

    def __init__(self, root, clients):
        self.root, self.clients = Path(root), list(clients)
        self.games, self.watchers, self.ready = {}, {k: set() for k in self.clients}, set()
        self.lock = threading.Lock()
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.bind(('127.0.0.1', 0))
        self.server.listen(16)
        self.port = self.server.getsockname()[1]
        self.live_at = None
        self.closed = False
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while not self.closed:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(conn,), daemon=True).start()

    @staticmethod
    def say(conn, text):
        try:
            conn.sendall((text+'\n').encode('latin-1', 'replace'))
            return True
        except OSError:
            return False

    def serve(self, conn):
        lines = socket_lines(conn)
        words = next(lines, '').split()
        if len(words) < 2 or words[0] != 'HELLO' or words[1] not in ('game', 'cmd'):
            conn.close()
            return
        client = int(fields(' '.join(words[2:])).get('client', '1') or 1)
        if words[1] == 'game':
            self.serve_game(conn, client, lines)
        else:
            self.serve_command(conn, client, lines)

    def serve_game(self, conn, client, lines):
        with self.lock:
            old = self.games.get(client)
            self.games[client] = conn
        if old is not None:
            old.close()
        print(f'KF2VR_LIVE game client={client} connected', flush=True)
        log = (self.root/f'live-client{client}.log').open('a', encoding='utf-8')
        try:
            for line in lines:
                log.write(line+'\n'); log.flush()
                if line.startswith('READY'):
                    self.mark_ready(client)
                with self.lock:
                    watchers = list(self.watchers.get(client, ()))
                for watcher in watchers:
                    self.say(watcher, line)
        finally:
            log.close()
            conn.close()
            with self.lock:
                if self.games.get(client) is conn:
                    del self.games[client]
                watchers = list(self.watchers.get(client, ()))
            for watcher in watchers:
                self.say(watcher, f'GONE client={client}')
            print(f'KF2VR_LIVE game client={client} disconnected', flush=True)

    def serve_command(self, conn, client, lines):
        with self.lock:
            self.watchers.setdefault(client, set()).add(conn)
            game = self.games.get(client)
        self.say(conn, f'WELCOME client={client} game={"yes" if game else "no"}')
        try:
            for line in lines:
                with self.lock:
                    game = self.games.get(client)
                if game is None or not self.say(game, line):
                    self.say(conn, f'GONE client={client}')
        finally:
            with self.lock:
                self.watchers.get(client, set()).discard(conn)
            conn.close()

    def mark_ready(self, client):
        with self.lock:
            self.ready.add(client)
            everyone = set(self.clients) <= self.ready
            if everyone and self.live_at is None:
                self.live_at = time.monotonic()
        update_session(self.root, ready=sorted(self.ready), **({'state': 'live'} if everyone else {}))

    def send_all(self, text):
        with self.lock:
            games = list(self.games.values())
        for game in games:
            self.say(game, text)

    def close(self):
        self.closed = True
        try:
            self.server.close()
        except OSError:
            pass
        with self.lock:
            conns = list(self.games.values()) + [w for ws in self.watchers.values() for w in ws]
        for conn in conns:
            try:
                conn.close()
            except OSError:
                pass


# ---- the session process ------------------------------------------------------

def build_compiled(start, opts, client, port):
    """The script (or nothing) plus a closing `live` op, bound to the broker."""
    import scripted
    if start.get('script'):
        compiled = scripted.compile_case(opts, Path(start['script']), start.get('weapon'))
    else:
        compiled = kfs.Compiled()
        compiled.setup['autoshot'] = 'off'
    # live.py start --preset/--set: launch settings, over the script's own.
    compiled.settings.update(start.get('settings') or {})
    if not has_live(compiled.ops):
        compiled.origins.append('live.py start')
        compiled.ops.append(f'{len(compiled.origins)}|live')
    compiled.ops = bind_live(compiled.ops, port, client)
    for key in ('res', 'map'):
        if start.get(key):
            compiled.setup[key] = start[key]
    # The launch watchdog runs the whole session; the script keeps its own timeout.
    compiled.setup['session_timeout'] = str(int(start['minutes'] * 60 + 300))
    return compiled


def held_tape(root):
    """False when a game's adapter predates the held tape (its tape then ends after 50 minutes)."""
    for log in Path(root, 'run').rglob('native.log'):
        try:
            line = next((l for l in log.read_text(encoding='utf-8', errors='replace').splitlines()
                         if 'ReplayInput schema=1' in l), None)
        except OSError:
            continue
        if line is not None and 'hold=1' not in line:
            return False
    return True


def quit_timer(broker, minutes, root):
    checked = False
    while not broker.closed:
        if broker.live_at is not None and not checked:
            checked = True
            if minutes > OLD_TAPE_MINUTES and not held_tape(root):
                minutes = OLD_TAPE_MINUTES
                print(f'KF2VR_LIVE this candidate does not hold the tracking tape; the session ends after '
                      f'{minutes} minutes', flush=True)
        if broker.live_at is not None and time.monotonic() - broker.live_at > minutes * 60:
            print(f'KF2VR_LIVE session reached its {minutes} minute limit; quitting', flush=True)
            broker.send_all('QUIT limit')
            return
        time.sleep(2)


def run_session(root):
    root = Path(root)
    start = read_json(root/'start.json')
    if start.get('fixture'):
        os.environ['KF2VR_FIXTURE'] = fixture.lane(start['fixture'])
    import scripted
    clients = list(range(1, start['clients'] + 1)) if start['mp'] else [1]
    broker = Broker(root, clients)
    update_session(root, state='starting', port=broker.port, pid=os.getpid(), clients=clients)
    print(f'KF2VR_LIVE session root={root} port={broker.port} pid={os.getpid()}', flush=True)
    threading.Thread(target=quit_timer, args=(broker, start['minutes'], root), daemon=True).start()
    opts = SimpleNamespace(candidate=Path(start['candidate']), game_root=None, user_config=None,
                           stall=10**7, hang=start['hang'], memory_growth=start['memory_growth'],
                           wait=start['wait'], live=True, timeout=None, var=start['var'])
    outcome = dict(state='failed')
    try:
        scripted.steam_preflight()
        update_session(root, state='compiling-observer')
        observer = scripted.compile_observer(opts.candidate/'Packages', root/'Observer', opts.wait)
        if start['mp']:
            outcome = run_mp(start, opts, broker, root, observer, clients)
        else:
            compiled = build_compiled(start, opts, 1, broker.port)
            merged = scripted.merge_cases([(1, start.get('weapon'), 'live', compiled)])
            allocate_lines(root, merged.origins, '')
            with scripted.queued_gate(opts.wait):
                update_session(root, state='launching')
                result = scripted.launch(opts, merged, root/'run', observer, start.get('script') or 'live',
                                         start.get('weapon'), deadline=merged.timeout + 60)
            # Name live statements' checks by their source in the summary.
            origins = read_json(root/'origins.json', []) or []
            for check in result['verdicts']['checks']:
                if 0 < check['line'] <= len(origins):
                    check['where'] = origins[check['line']-1]
            scripted.write_summary(root/'run', result)
            outcome = dict(state='ended', passed=result['passed'], ended=result['ended'], errors=result['errors'],
                           summary=str(root/'run/summary.md'),
                           checks=len(result['verdicts']['checks']),
                           failed=[f"{c['where']} {c['kind']} {c['probe']}={c['value']} (want {c['op']} {c['expected']})"
                                   for c in result['verdicts']['checks'] if not c['passed']])
    except BaseException as error:
        traceback.print_exc()
        outcome = dict(state='failed', error=str(error))
    finally:
        broker.close()
        update_session(root, finished=datetime.now(timezone.utc).isoformat(), **outcome)
        try:
            scripted.prune_run(root)
        except OSError:
            pass
        print(f'KF2VR_LIVE session {outcome["state"]}', flush=True)


def run_mp(start, opts, broker, root, observer, clients):
    import scripted
    import scripted_mp
    batches = [[(k, start.get('weapon'), 'live', build_compiled(start, opts, k, broker.port))] for k in clients]
    first = batches[0][0][3]
    opts.server_root = Path(start['server_root'])
    opts.port, opts.query_port = start['mp_port'], start['mp_query_port']
    opts.map = start.get('map') or first.setup['map']
    opts.zeds = start['zeds']
    opts.hostgrabs = first.setup.get('hostgrabs', 'on')
    allocate_lines(root, scripted.merge_cases(batches[0]).origins, '')
    with scripted.queued_gate(opts.wait):
        update_session(root, state='launching')
        rows = scripted_mp.run_net_session(opts, start.get('script') or 'live', batches, observer, root/'run')
    errors = sorted({e for row in rows for e in row.get('errors', [])})
    return dict(state='ended', passed=bool(rows) and all(r['passed'] for r in rows),
                ended=','.join(str(r.get('ended')) for r in rows), errors=errors,
                summary=str(root/'run'), failed=[f for r in rows for f in r.get('failed', [])],
                clients_summary=[r.get('summary') for r in rows])


# ---- commands -------------------------------------------------------------------

class Channel:
    """One command connection to the session broker for one game client."""

    def __init__(self, session, client):
        if session.get('state') in ('ended', 'failed'):
            raise LiveError(f"Session {session['root']} has {session['state']}")
        try:
            self.sock = socket.create_connection(('127.0.0.1', int(session['port'])), timeout=5)
        except (OSError, KeyError, TypeError) as error:
            raise LiveError(f'Session broker unreachable ({error}); is the session process alive? '
                            f'pid={session.get("pid")}') from None
        self.lines = self._lines()
        self.send(f'HELLO cmd client={client}')
        welcome = self.read(time.monotonic() + 5)
        if not welcome or not welcome.startswith('WELCOME'):
            raise LiveError(f'Unexpected broker reply {welcome!r}')
        if fields(welcome).get('game') != 'yes':
            raise LiveError(f'Game client {client} is not connected (session state: {session.get("state")})')

    def _lines(self):
        buffer = b''
        while True:
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                yield line.decode('latin-1').rstrip('\r')
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                yield None
                continue
            except OSError:
                data = b''
            if not data:
                raise LiveError('Session broker closed the connection')
            buffer += data

    def send(self, line):
        try:
            self.sock.sendall((line+'\n').encode('latin-1'))
        except OSError as error:
            raise LiveError(f'Send failed: {error}') from None

    def read(self, deadline):
        """The next line, or None once the deadline passes."""
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            self.sock.settimeout(min(left, 1.0))
            line = next(self.lines)
            if line is None:
                continue
            if line.startswith('GONE'):
                raise LiveError('The game disconnected (it ended or crashed); see live.py status')
            return line

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def new_id():
    return secrets.token_hex(4)


def resolver():
    from weapons import weapon_path
    return weapon_path


def session_client(session, client):
    clients = session.get('clients') or [1]
    if client not in clients:
        raise LiveError(f'No client {client}; this session has {clients}', USAGE)
    return client


def print_note(text, origins, out):
    print(note_text(text, origins), file=out, flush=True)


def send_statements(session, text, client=1, wait=True, timeout=120.0, out=sys.stdout, collect=None):
    """Compile and run statements; returns an exit code. collect, a list,
    receives (kind, fields) for CAPTURE lines."""
    root = Path(session['root'])
    variables = dict(session.get('variables') or {})
    try:
        ops, origins, new = compile_statements(text, variables, resolver(), load_macros(root))
    except kfs.ScriptError as error:
        print(f'compile error: {error}', file=out, flush=True)
        return USAGE
    save_macros(root, new)
    if not ops:
        print('ok (no ops)' + (f'; defined {", ".join(sorted(new))}' if new else ''), file=out, flush=True)
        return OK
    number = len(read_json(root/'batches.json', []) or []) + 1
    base = allocate_lines(root, origins, f'live{number}')
    with FileLock(root/'batches.lock'):
        batches = read_json(root/'batches.json', []) or []
        batches.append(dict(n=number, client=client, text=text, ops=len(ops)))
        write_json(root/'batches.json', batches)
    ops = relocate(ops, base)
    batch = new_id()
    channel = Channel(session, session_client(session, client))
    try:
        channel.send(f'BEGIN {batch}')
        for op in ops:
            channel.send(f'OP {op}')
        channel.send(f'COMMIT {batch}')
        deadline = time.monotonic() + 15
        while True:
            line = channel.read(deadline)
            if line is None:
                print('timed out waiting for the game to take the batch', file=out, flush=True)
                return TIMED_OUT
            kind, rest = line.partition(' ')[::2]
            if kind == 'ERROR' and fields(rest).get('id') == batch:
                print(f'refused: {rest}', file=out, flush=True)
                return GONE
            if kind == 'QUEUED' and fields(rest).get('id') == batch:
                queued = fields(rest)
                break
        if not wait:
            print(f'queued batch {batch} live{number} ops={len(ops)} at={queued.get("at")}', file=out, flush=True)
            return OK
        origins_all = read_json(root/'origins.json', []) or []
        failed, aborted = False, None
        deadline = time.monotonic() + timeout
        while True:
            line = channel.read(deadline)
            if line is None:
                print(f'timed out after {timeout:g}s; the ops keep running (live.py abort drops them)', file=out, flush=True)
                return TIMED_OUT
            kind, rest = line.partition(' ')[::2]
            if kind == 'NOTE':
                if re.search(r'\bpassed=false\b', rest):
                    failed = True
                if 'live-done id=' not in rest:
                    print_note(rest, origins_all, out)
            elif kind == 'CAPTURE':
                print(f'capture {rest}', file=out, flush=True)
                if collect is not None:
                    collect.append(fields(rest))
            elif kind == 'DONE' and fields(rest).get('id') == batch:
                aborted = fields(rest).get('aborted')
                break
        if aborted:
            print(f'aborted: {aborted}', file=out, flush=True)
            return CHECK_FAILED
        print('FAIL (a check failed)' if failed else 'ok', file=out, flush=True)
        return CHECK_FAILED if failed else OK
    finally:
        channel.close()


def control(session, verb, client=1, payload='', out=sys.stdout, timeout=10.0):
    """PROBE / STATUS / PAUSE / RESUME / ABORT: one request, one reply."""
    ident = new_id()
    channel = Channel(session, session_client(session, client))
    expect = dict(PROBE='PROBE', STATUS='STATUS', PAUSE='PAUSED', RESUME='RESUMED', ABORT='ABORTED')[verb]
    try:
        channel.send(f'{verb} {ident}' + (f' {payload}' if payload else ''))
        deadline = time.monotonic() + timeout
        while True:
            line = channel.read(deadline)
            if line is None:
                raise LiveError(f'No {expect} reply in {timeout:g}s', TIMED_OUT)
            kind, rest = line.partition(' ')[::2]
            separator = '\t' if kind in ('PROBE', 'STATUS') else None
            if kind == expect and fields(rest.split('\t')[0]).get('id') == ident:
                return fields(rest, separator)
            if kind == 'NOTE' and verb in ('PAUSE', 'RESUME', 'ABORT') and re.search(r'live (paused|resumed|aborted)', rest):
                continue
    finally:
        channel.close()


def screenshot_roots(session, client):
    root = Path(session['root'])/'run'
    roots = [root/'driver/ScreenShotPath'] if not session.get('mp') else [root/f'client{client}/driver/ScreenShotPath']
    game = Path(session['game_root'])
    roots += [game/'KFGame/Screenshots']
    if session.get('user_screenshots'):
        roots.append(Path(session['user_screenshots']))
    return roots


def find_capture(roots, name, since, timeout=20.0):
    """The engine's file for a logged capture, once it has stopped growing."""
    pattern = re.compile(r'[A-Za-z0-9_.() -]*'+re.escape(name)+r'(0)?\.(bmp|png)$', re.I)
    deadline, last = time.monotonic() + timeout, None
    while time.monotonic() < deadline:
        found = []
        for base in roots:
            if not base.is_dir():
                continue
            for folder, _, files in os.walk(base):
                for filename in files:
                    match = pattern.fullmatch(filename)
                    path = Path(folder)/filename
                    if match and path.stat().st_mtime >= since - 2:
                        found.append((match[1] is not None, path))
        if found:
            path = sorted(found)[0][1]   # the exact name before UE's trailing 0
            size = path.stat().st_size
            if size and size == last:
                return path
            last = size
        time.sleep(0.4)
    return None


def take_shot(session, name, client, out=sys.stdout):
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,63}', name):
        print('shot names are letters, digits, _ and -, starting with a letter', file=out)
        return USAGE, None
    since = time.time()
    captures = []
    code = send_statements(session, f'shot {name} pose', client, out=out, collect=captures, timeout=30)
    if code not in (OK, CHECK_FAILED) or not captures:
        print('no capture was logged', file=out, flush=True)
        return code or GONE, None
    capture = captures[-1]['name']
    source = find_capture(screenshot_roots(session, client), capture, since)
    if source is None:
        print(f'capture {capture} was requested but no file appeared', file=out, flush=True)
        return GONE, None
    shots = Path(session['root'])/'shots'
    shots.mkdir(exist_ok=True)
    target = shots/f'{name}-{capture.rsplit("_", 2)[-2]}_{capture.rsplit("_", 1)[-1]}.png'
    if source.suffix.lower() == '.bmp':
        sys.path.insert(0, str(HERE.parent))
        from melee_runtime_launcher import bmp_to_png
        bmp_to_png(source, target)
    else:
        shutil.copy2(source, target)
    print(target.resolve(), file=out, flush=True)
    return OK, target


def wait_state(root, states, timeout, out=sys.stdout, tail=True, pid=None):
    """Follow the session process log until session.json reaches a state."""
    root = Path(root)
    log, offset = root/'daemon.log', 0
    deadline = time.monotonic() + timeout
    while True:
        session = read_json(root/'session.json', {}) or {}
        if tail and log.exists():
            text = log.read_text(encoding='utf-8', errors='replace')
            for line in text[offset:].splitlines():
                print(line, file=out, flush=True)
            offset = len(text)
        if session.get('state') in states:
            return session
        owner = session.get('pid') or pid
        if owner and not process_alive(owner) and session.get('state') not in ('ended', 'failed'):
            session['state'] = 'session-process-died'
            return session
        if time.monotonic() > deadline:
            return None
        time.sleep(1)


def spawn_session(root):
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    command = [sys.executable, str(Path(__file__).resolve()), '_serve', str(root)]
    with (root/'daemon.log').open('ab') as log:
        for extra in (0x01000000, 0):   # CREATE_BREAKAWAY_FROM_JOB where the job allows it
            try:
                return subprocess.Popen(command, cwd=ROOT, creationflags=flags | extra, stdin=subprocess.DEVNULL,
                                        stdout=log, stderr=subprocess.STDOUT, close_fds=True)
            except OSError:
                if not extra:
                    raise


def cmd_start(a):
    if not a.candidate or not a.candidate.is_absolute() or not a.candidate.is_dir():
        print('--candidate <absolute release directory> is required', file=sys.stderr)
        return USAGE
    lane = fixture.lane(a.fixture) if a.fixture else (os.environ.get('KF2VR_FIXTURE') or None)
    if lane is not None and not fixture.game_root(lane).is_dir():
        print(f'No fixture for lane {lane}: python tools/replay/fixture.py create {lane}', file=sys.stderr)
        return USAGE
    weapons = [w for item in a.weapons for w in item.split(',') if w]
    if len(weapons) > 1:
        print('A live session has one $weapon; draw others by name', file=sys.stderr)
        return USAGE
    try:
        settings = launch_settings(a.preset, a.set)
    except kfs.ScriptError as error:
        print(f'error: {error}', file=sys.stderr)
        return USAGE
    if not 1 <= a.minutes <= MAX_MINUTES:
        print(f'--minutes is 1..{MAX_MINUTES}', file=sys.stderr)
        return USAGE
    start = dict(candidate=str(a.candidate.resolve()), script=str(a.script.resolve()) if a.script else None,
                 weapon=weapons[0] if weapons else None, var=a.var, fixture=lane, res=a.res, map=a.map,
                 mp=a.mp, clients=a.clients, zeds=a.zeds, server_root=str(a.server_root.resolve()),
                 mp_port=a.port, mp_query_port=a.query_port, wait=a.wait, minutes=a.minutes,
                 hang=a.hang, memory_growth=a.memory_growth, settings=settings)
    # Fail on a script, variable or setup error before launching anything.
    try:
        if a.res:
            kfs.Compiler().do_setup('--res', [f'res={a.res}'])
        if a.script:
            import scripted
            scripted.compile_case(SimpleNamespace(var=a.var), a.script, start['weapon'])
        variables = dict(v.split('=', 1) for v in a.var)
    except (kfs.ScriptError, ValueError) as error:
        print(f'compile error: {error}', file=sys.stderr)
        return USAGE
    if start['weapon']:
        variables['weapon'] = start['weapon']
    root = (a.output or RUNS/(datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')+('-live-mp' if a.mp else '-live'))).resolve()
    if root.exists():
        print(f'{root} exists; choose a fresh --output', file=sys.stderr)
        return USAGE
    root.mkdir(parents=True)
    write_json(root/'start.json', start)
    import scripted
    user = scripted.user_config_root(None)
    write_json(root/'session.json', dict(schema='kf2vr/live-session/1', state='spawning', root=str(root),
               mp=a.mp, clients=list(range(1, a.clients + 1)) if a.mp else [1], variables=variables,
               fixture=lane, game_root=str(fixture.game_root(lane)), user_screenshots=str(user.parent/'Screenshots'),
               started=datetime.now(timezone.utc).isoformat()))
    process = spawn_session(root)
    for note in {pointer(), pointer(lane)}:
        write_json(note, dict(root=str(root)))
    print(f'session {root} (session process pid {process.pid})'
          + (f' settings {" ".join(f"{k}={v}" for k, v in settings.items())}' if settings else ''), flush=True)
    if a.no_wait:
        return OK
    return report_ready(root, a.timeout, process.pid)


def report_ready(root, timeout, pid=None):
    session = wait_state(root, ('live', 'ended', 'failed'), timeout, pid=pid)
    if session is None:
        print(f'not live yet after {timeout}s (still starting or queued); `live.py wait` keeps waiting', flush=True)
        return TIMED_OUT
    if session['state'] != 'live':
        print(f"session {session['state']}: {session.get('error') or session.get('ended') or ''} "
              f"summary={session.get('summary')}", flush=True)
        return GONE
    print(f"LIVE port={session['port']} clients={session.get('clients')} root={root}", flush=True)
    return OK


def cmd_wait(a, session):
    return report_ready(session['root'], a.timeout)


def cmd_send(a, session):
    text = ' ; '.join(a.statements) if a.statements else sys.stdin.read()
    return send_statements(session, text, a.client, wait=not a.no_wait, timeout=a.timeout)


def cmd_probe(a, session):
    try:
        # Commas separate probes, except inside parentheses: dist(a, b).
        names = [kfs.probe(name.strip(), '<probe>') for item in a.probes
                 for name in re.split(r',(?![^()]*\))', item) if name.strip()]
    except kfs.ScriptError as error:
        print(f'error: {error}')
        return USAGE
    if not names:
        print('probe <probe> ...')
        return USAGE
    reply = control(session, 'PROBE', a.client, ','.join(names))
    if reply.get('error'):
        print(f"error: {reply['error']}")
        return GONE
    for name in names:
        print(f'{name}={reply.get(name, "?")}')
    return OK


def cmd_status(a, session):
    print(f"session {session['root']} state={session.get('state')} pid={session.get('pid')} "
          f"alive={bool(session.get('pid')) and process_alive(session['pid'])}")
    ready = session.get('ready') or []
    if session.get('state') != 'live' and not (ready and session.get('state') == 'launching'):
        for key in ('error', 'ended', 'passed', 'summary', 'errors', 'failed'):
            if session.get(key) not in (None, [], ''):
                print(f'{key}: {session[key]}')
        log = Path(session['root'])/'daemon.log'
        if log.exists():
            print('session log (last lines):')
            print('\n'.join(log.read_text(encoding='utf-8', errors='replace').splitlines()[-8:]))
        return OK if session.get('state') not in ('failed',) else GONE
    for client in ([a.client] if a.client else session.get('clients') or [1]):
        if session.get('state') != 'live' and client not in ready:
            print(f'client {client}: not live yet')
            continue
        reply = control(session, 'STATUS', client)
        reply.pop('id', None)
        print(f'client {client}: ' + '  '.join(f'{k}={v}' for k, v in reply.items()))
    return OK


def cmd_simple(verb):
    def run(a, session):
        reply = control(session, verb, a.client)
        reply.pop('id', None)
        print(verb.lower() + ' ' + ' '.join(f'{k}={v}' for k, v in reply.items()))
        return OK
    return run


def cmd_shot(a, session):
    count = len(list((Path(session['root'])/'shots').glob('*.png'))) + 1
    code, _ = take_shot(session, a.name or f'shot{count}', a.client)
    return code


def cmd_quit(a, session):
    root = Path(session['root'])
    if session.get('state') in ('ended', 'failed'):
        print(f"session already {session['state']}; summary={session.get('summary')}")
        return OK if session['state'] == 'ended' else GONE
    for client in session.get('clients') or [1]:
        try:
            channel = Channel(session, client)
            channel.send(f'QUIT {new_id()}')
            channel.close()
        except LiveError as error:
            print(f'client {client}: {error}')
    print('quitting; waiting for the runner to restore the game folder', flush=True)
    done = wait_state(root, ('ended', 'failed'), a.timeout, tail=False)
    if done is None:
        print(f'session still finishing after {a.timeout}s; run live.py status later')
        return TIMED_OUT
    print(f"session {done['state']} passed={done.get('passed')} ended={done.get('ended')}")
    for error in done.get('errors') or []:
        print(f'error: {error}')
    for failed in done.get('failed') or []:
        print(f'failed: {failed}')
    print(f"summary={done.get('summary')}")
    # 0: ended cleanly and every check passed; 1: ended, but a check failed or
    # the runner reported errors; 3: the session failed.
    if done['state'] != 'ended':
        return GONE
    return OK if done.get('passed') and not done.get('errors') else CHECK_FAILED


def cmd_recover(a, session):
    """Restore a session whose process died, from its deployment journals."""
    if session.get('pid') and process_alive(session['pid']):
        print('The session process is alive; use live.py quit')
        return USAGE
    sys.path.insert(0, str(ROOT/'tools/multiplayer'))
    from native_fixture import NativeDeployment
    from run import digest
    errors, found = [], 0
    for journal in Path(session['root']).glob('**/*NativeBackup/deployment.json'):
        data = read_json(journal)
        destination = Path(data['destination'])
        running = subprocess.run(['powershell', '-NoProfile', '-Command',
            f"@(Get-Process KFGame,KFServer -ErrorAction SilentlyContinue | Where-Object {{ $_.Path -like '{destination}*' }}).Count"],
            capture_output=True, text=True).stdout.strip()
        if running not in ('', '0'):
            errors.append(f'A game is still running from {destination}; wait for it to exit')
            continue
        found += 1
        receipt = {'artifacts_sha256': {name: item['installed'] for name, item in data['files'].items()}}
        deploy = NativeDeployment(None, destination, journal.parent, receipt, digest,
                                  server='openxr_loader.dll' not in data['files'])
        errors += deploy.restore()
    update_session(session['root'], state='failed' if errors else 'ended', recovered=not errors, errors=errors)
    print(f'journals={found} errors={errors or "none"}')
    return OK if not errors else CHECK_FAILED


HELP = """statements are kfs (tools/replay/SCRIPTS.md); macros from lib/common, lib/melee, lib/mp
controls: probe <p>...  shot [name]  status  pause  resume  abort  quit  client <n>  exit"""


def cmd_repl(a, session):
    client = a.client
    print(f"live session {session['root']} client {client}. {HELP}")
    while True:
        try:
            line = input(f'kfs[{client}]> ').strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return OK
        if not line:
            continue
        verb, _, rest = line.partition(' ')
        verb = verb.lower()
        try:
            session = find_session(session['root'])
            if verb in ('exit', 'bye'):
                return OK
            if verb == 'help':
                print(HELP)
            elif verb == 'client':
                client = int(rest)
            elif verb == 'probe':
                cmd_probe(SimpleNamespace(probes=rest.split(), client=client), session)
            elif verb == 'shot' and len(rest.split()) <= 1:
                cmd_shot(SimpleNamespace(name=rest or None, client=client), session)
            elif verb == 'status':
                cmd_status(SimpleNamespace(client=client), session)
            elif verb in ('pause', 'resume', 'abort'):
                cmd_simple(verb.upper())(SimpleNamespace(client=client), session)
            elif verb == 'quit':
                return cmd_quit(SimpleNamespace(timeout=300), session)
            else:
                send_statements(session, line, client)
        except LiveError as error:
            print(f'error: {error}')
        except ValueError as error:
            print(f'error: {error}')


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ['_serve']:
        run_session(argv[1])
        return OK
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest='command', required=True)

    def common(q, client=True):
        q.add_argument('--session', help='Session folder (default: the last one started, per --fixture lane)')
        q.add_argument('--fixture', help='Find the last session started in this lane')
        if client:
            q.add_argument('--client', type=int, default=1, help='Game client (dedicated-server sessions: 1..N)')
        return q

    s = sub.add_parser('start', help='Launch a game and leave it in live mode')
    s.add_argument('--candidate', type=Path, required=True)
    s.add_argument('--script', type=Path, help='Run this script first, then go live')
    s.add_argument('--weapons', nargs='*', default=[], help='The session $weapon (one)')
    s.add_argument('--var', action='append', default=[], help='name=value for $name')
    s.add_argument('--fixture', help='Replay lane (tools/replay/fixture.py)')
    s.add_argument('--res', help='Window and capture size, WxH (default 640x360)')
    s.add_argument('--preset', choices=sorted(kfs.PRESETS), help='Reload preset bundle, as a script preset line')
    s.add_argument('--set', action='append', default=[], metavar='Key=Value',
                   help='A VRHandsBridge setting, as a script set line (repeatable; applied after --preset)')
    s.add_argument('--map', help='Map (default: the script setup map, KF-Outpost)')
    s.add_argument('--mp', action='store_true', help='Dedicated server with --clients VR clients (scripted_mp.py)')
    s.add_argument('--clients', type=int, default=2, choices=range(1, 4))
    s.add_argument('--zeds', action='store_true', help='With --mp: let the wave spawn Zeds')
    s.add_argument('--server-root', type=Path, default=ROOT/'build/multiplayer/server')
    s.add_argument('--port', type=int, default=18777, help='With --mp: the server game port')
    s.add_argument('--query-port', type=int, default=38015)
    s.add_argument('--wait', type=int, default=900, help='Seconds to queue for a busy game slot')
    s.add_argument('--minutes', type=int, default=40, help=f'Session length cap after going live (1..{MAX_MINUTES})')
    s.add_argument('--hang', type=int, default=20)
    s.add_argument('--memory-growth', type=int, default=1500)
    s.add_argument('--output', type=Path)
    s.add_argument('--timeout', type=int, default=540, help='Seconds to wait for live mode before returning')
    s.add_argument('--no-wait', action='store_true', help='Return once the session process is started')

    w = common(sub.add_parser('wait', help='Wait for a starting session to go live'), client=False)
    w.add_argument('--timeout', type=int, default=540)
    q = common(sub.add_parser('send', help='Run kfs statements and print what they logged'))
    q.add_argument('statements', nargs='*', help='Statements (several args are joined with ;); stdin when none')
    q.add_argument('--no-wait', action='store_true')
    q.add_argument('--timeout', type=float, default=120)
    q = common(sub.add_parser('probe', help='Read probes now'))
    q.add_argument('probes', nargs='+')
    q = common(sub.add_parser('shot', help='Take a capture and print its PNG path'))
    q.add_argument('name', nargs='?')
    common(sub.add_parser('status'), client=False).add_argument('--client', type=int)
    for verb in ('pause', 'resume', 'abort'):
        common(sub.add_parser(verb))
    q = common(sub.add_parser('quit', help='End the session cleanly'), client=False)
    q.add_argument('--timeout', type=int, default=300)
    common(sub.add_parser('recover', help='Restore the game folder of a session whose process died'), client=False)
    common(sub.add_parser('repl', help='Interactive prompt'))
    a = p.parse_args(argv)
    try:
        if a.command == 'start':
            return cmd_start(a)
        session = find_session(a.session, fixture.lane(a.fixture) if a.fixture else None)
        handler = dict(wait=cmd_wait, send=cmd_send, probe=cmd_probe, shot=cmd_shot, status=cmd_status,
                       pause=cmd_simple('PAUSE'), resume=cmd_simple('RESUME'), abort=cmd_simple('ABORT'),
                       quit=cmd_quit, recover=cmd_recover, repl=cmd_repl)[a.command]
        return handler(a, session)
    except LiveError as error:
        print(f'error: {error}', file=sys.stderr)
        return error.code


if __name__ == '__main__':
    sys.exit(main())
