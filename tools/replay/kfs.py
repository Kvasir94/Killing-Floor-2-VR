"""Compile .kfs replay scripts into the flat op list ScriptRunner executes.

The language is documented in tools/replay/SCRIPTS.md. Includes, macros,
repeats and variables are expanded here, so the game only sequences validated
ops. Log expectations stay on this side and are checked against the game log.
"""
from dataclasses import dataclass, field
from pathlib import Path
import re

HANDS = {'left': 'L', 'l': 'L', 'right': 'R', 'r': 'R'}
BUTTON_ALIASES = {'a': 'primary', 'x': 'primary', 'b': 'secondary', 'y': 'secondary'}
OPS = ('==', '!=', '<=', '>=', '<', '>')
PARTS = ('mag', 'well', 'action')
FRAMES = ('body', 'gun', 'world')
MAX_OPS = 4000
TOKEN = re.compile(r'"[^"]*"|/(?:\\.|[^/])+/|[^\s;{}(]*\([^)]*\)[^\s;{}]*|[^\s;{}]+|[;{}]')


class ScriptError(ValueError):
    def __init__(self, where, message):
        super().__init__(f'{where}: {message}')


@dataclass
class Compiled:
    ops: list = field(default_factory=list)
    settings: dict = field(default_factory=dict)
    setup: dict = field(default_factory=lambda: {'map': 'KF-Outpost', 'timeout': '600', 'autoshot': 'on'})
    log_checks: list = field(default_factory=list)
    sources: list = field(default_factory=list)
    origins: list = field(default_factory=list)   # op line ids -> 'file:line'

    def where(self, line):
        return self.origins[line-1] if 0 < line <= len(self.origins) else 'runner'


def seconds(text, where):
    match = re.fullmatch(r'(-?[0-9]*\.?[0-9]+)(ms|s|m)?', text)
    if not match:
        raise ScriptError(where, f'expected a duration, got {text!r}')
    value = float(match[1]) * {'ms': .001, 'm': 60.0}.get(match[2], 1.0)
    if not 0 <= value <= 3600:
        raise ScriptError(where, 'duration must be 0..3600 seconds')
    return f'{value:g}'


def number(text, where, low=-1e6, high=1e6):
    try:
        value = float(text)
    except ValueError:
        raise ScriptError(where, f'expected a number, got {text!r}') from None
    if not low <= value <= high:
        raise ScriptError(where, f'{text} is outside {low:g}..{high:g}')
    return f'{value:g}'


def triple(text, where):
    if not (text.startswith('(') and text.endswith(')')):
        raise ScriptError(where, f'expected (x,y,z), got {text!r}')
    parts = [p.strip() for p in text[1:-1].split(',')]
    if len(parts) != 3:
        raise ScriptError(where, 'expected three comma-separated numbers')
    return [number(p, where, -500, 500) for p in parts]


def hand(text, where, allow_both=False):
    value = text.lower()
    if allow_both and value == 'both':
        return ['L', 'R']
    if value not in HANDS:
        raise ScriptError(where, f'expected left, right{" or both" if allow_both else ""}, got {text!r}')
    return [HANDS[value]]


def anchor(text, where, default_hand=None):
    """Script anchors -> runner anchors (see ScriptRunner.Resolve)."""
    value = text
    if value in ('head', 'body', 'world', 'chest', 'door', 'reload.target', 'reload.held', 'reload.seat', 'reload.contact', 'bow.nock', 'reload.target2'):
        return value
    if value == 'pouch':
        if not default_hand:
            raise ScriptError(where, 'pouch needs a hand: pouch.left or pouch.right')
        return 'pouch.'+default_hand
    match = re.fullmatch(r'zed\((?:([A-Za-z_][A-Za-z0-9_]*)\s*,\s*)?([A-Za-z_][A-Za-z0-9_]*)\)', value)
    if match:
        # That bone of the nearest Zed (or of the nearest pawn of that class,
        # e.g. zed(KFPawn_ZedClot_Alpha, head) for a corpse beside the dummies),
        # placed for the moving hand's palm.
        return f'zed.{match[2]}.'+(default_hand or 'R')+(f'.{match[1]}' if match[1] else '')
    if value == 'weld.hologram':
        # The door welder offer's hologram, placed for the moving hand's palm.
        return 'weld.hologram.'+(default_hand or 'R')
    if value == 'hip':
        if not default_hand:
            raise ScriptError(where, 'hip needs a hand: hip.left or hip.right')
        return 'hip.'+default_hand
    match = re.fullmatch(r'(pouch|wrist|hip|pickup)\.(left|right|l|r)', value, re.I)
    if match:
        return match[1].lower()+'.'+HANDS[match[2].lower()]
    match = re.fullmatch(r'nearest\(([A-Za-z_][A-Za-z0-9_]*)\)', value)
    if match:
        return 'nearest.'+match[1]
    match = re.fullmatch(r'(left|right|l|r)\.(support|trigger|stroke|scope|blade)', value, re.I)
    if match:
        return HANDS[match[1].lower()]+'.'+match[2].lower()
    match = re.fullmatch(r'(left|right|l|r)\.(?:(mag|well|action)|bone\(([A-Za-z_][A-Za-z0-9_]*)\))', value, re.I)
    if match:
        side = HANDS[match[1].lower()]
        return f'{side}.part.{match[2].lower()}' if match[2] else f'{side}.bone.{match[3]}'
    raise ScriptError(where, f'unknown anchor {text!r}')


def probe(text, where):
    match = re.fullmatch(r'(left|right|l|r)\.([a-z0-9_]+)', text, re.I)
    if match:
        return HANDS[match[1].lower()]+'.'+match[2].lower()
    match = re.fullmatch(r'count\(([A-Za-z_][A-Za-z0-9_]*)\)', text)
    if match:
        return 'count.'+match[1]
    match = re.fullmatch(r'nearest\(([A-Za-z_][A-Za-z0-9_]*)\)\.([a-z_]+)', text)
    if match:
        return f'nearest.{match[1]}.{match[2]}'
    match = re.fullmatch(r'dist\(([^,]+),([^)]+)\)', text)
    if match:
        a, b = (anchor(p.strip(), where).replace('.', ':') for p in match.groups())
        return f'dist.{a}.{b}'
    if re.fullmatch(r'pawn\.(x|y|z|yaw|view_yaw|travel)|frame_ms|graphics_preset|time|health|speed|input|dosh|trader|doors\.spawn|perk|xp|perk_level|xp\.KFPerk_[A-Za-z]+|kills\.[A-Za-z][A-Za-z0-9_]*|reload\.step2?|reload\.actions|props\.(mags|mag_rounds|rounds|cases)|setting\.[A-Za-z][A-Za-z0-9_]*', text):
        return text
    raise ScriptError(where, f'unknown probe {text!r}')


def condition(tokens, where):
    if len(tokens) < 3 or tokens[1] not in OPS:
        raise ScriptError(where, 'expected <probe> <op> <value>, op one of '+' '.join(OPS))
    value = tokens[2].strip('"')
    if '|' in value:
        raise ScriptError(where, 'values cannot contain |')
    return probe(tokens[0], where), tokens[1], value, tokens[3:]


def options(tokens, where, allowed):
    """Trailing `key value` options and a final `&` (run in parallel)."""
    found, parallel, i = {}, False, 0
    while i < len(tokens):
        token = tokens[i]
        if token == '&' and i == len(tokens)-1:
            parallel = True
            i += 1
            continue
        key, equals, value = token.partition('=')
        if equals and key in allowed and value:   # key=value spelling
            found[key] = value
            i += 1
            continue
        if token not in allowed:
            raise ScriptError(where, f'unexpected {token!r}; allowed: {", ".join(sorted(allowed))}')
        if i+1 >= len(tokens):
            raise ScriptError(where, f'{token} needs a value')
        found[token] = tokens[i+1]
        i += 2
    return found, parallel


# Named setting bundles for `preset` and the runner's --matrix preset=...
PRESETS = {'advanced': dict(ReloadPreset='2', bInteractiveReloads='True',
                    bKeepChamberedRound='True', bLoseReloadAmmo='True', bRecoverMagazineAmmo='True',
                    # ADVANCED sets NEW MAG RELEASES OLD off (PHYSICAL_RELOAD_SPEC R47).
                    bGrabReleasesMagazine='False',
                    bSupportHandCarry='True', bIndependentHands='True', bReloadHints='True',
                    # Scripts say hold/release; toggle grip would flip on every press.
                    bToggleGrip='False', bHoldSupportGrip='True'),
   'classic': dict(ReloadPreset='0', bInteractiveReloads='False', bToggleGrip='False')}


class Compiler:
    def __init__(self, variables=None, resolve_weapon=None, include_root=None):
        self.variables = dict(variables or {})
        self.resolve_weapon = resolve_weapon or (lambda name: name)
        self.include_root = include_root
        self.macros = {}
        self.out = Compiled()
        self.depth = 0

    # -- reading ------------------------------------------------------------
    def statements(self, text, source):
        """Yield (where, tokens) with blocks nested as lists."""
        stack, opened = [[]], []
        for number_, raw in enumerate(text.splitlines(), 1):
            line = re.sub(r'(?<![/"\w])#.*$', '', raw)
            default = re.fullmatch(r'\s*default\s+([A-Za-z_]\w*)=(\S+)\s*', line)
            if default:   # a script's own fallback for a variable the runner may set
                self.variables.setdefault(default[1], default[2])
                continue
            for name, value in self.variables.items():
                line = line.replace('$'+name, value)
            where = f'{source}:{number_}'
            current = []
            for token in TOKEN.findall(line):
                if token == ';':
                    if current: stack[-1].append((where, current)); current = []
                elif token == '{':
                    stack[-1].append((where, current+[[]])); current = []
                    stack.append(stack[-1][-1][1][-1]); opened.append(where)
                elif token == '}':
                    if current: stack[-1].append((where, current)); current = []
                    if len(stack) == 1:
                        raise ScriptError(where, 'unmatched }')
                    stack.pop(); opened.pop()
                else:
                    current.append(token)
            if current:
                stack[-1].append((where, current))
        if len(stack) != 1:
            raise ScriptError(opened[-1], 'block opened here is missing its }')
        return stack[0]

    # -- emitting -----------------------------------------------------------
    def emit(self, where, verb, **fields):
        if len(self.out.ops) >= MAX_OPS:
            raise ScriptError(where, f'script expands past {MAX_OPS} ops; split it')
        # Ops carry a 1-based origin id so lines from includes stay unambiguous.
        if where not in self.out.origins:
            self.out.origins.append(where)
        line = str(self.out.origins.index(where)+1)
        parts = [line, verb] + [f'{k}={v}' for k, v in fields.items() if v is not None]
        for part in parts:
            unbound = re.search(r'\$[A-Za-z_]\w*', part)
            if unbound:
                raise ScriptError(where, f'undefined variable {unbound[0]}')
            if '|' in part[part.find('=')+1:] or '\n' in part or '"' in part:
                raise ScriptError(where, 'op text cannot contain | " or newlines')
        self.out.ops.append('|'.join(parts))

    def run(self, block):
        i = 0
        while i < len(block):
            where, tokens = block[i]
            follower = block[i+1][1] if i + 1 < len(block) else None
            if (tokens[0].lower() == 'if' and follower and follower[0].lower() == 'else'
                    and len(follower) == 2 and isinstance(follower[1], list)):
                self.do_if(where, tokens[1:-1], tokens[-1], follower[1])
                i += 2
                continue
            if tokens[0].lower() == 'else':
                raise ScriptError(where, 'else must follow an if block')
            self.statement(where, tokens)
            i += 1

    def compile_text(self, text, source='<script>'):
        self.out.sources.append(source)
        self.run(self.statements(text, source))
        return self.out

    def compile_file(self, path):
        path = Path(path)
        if self.include_root is None:
            self.include_root = path.parent
        return self.compile_text(path.read_text(encoding='utf-8'), str(path))

    # -- statements ---------------------------------------------------------
    def statement(self, where, tokens):
        verb, args = tokens[0].lower(), tokens[1:]
        block = args.pop() if args and isinstance(args[-1], list) else None
        if block is not None and verb not in ('repeat', 'define', 'if'):
            raise ScriptError(where, f'{verb} does not take a {{ }} block')
        handler = getattr(self, 'do_'+verb.replace('-', '_'), None)
        if handler is None:
            raise ScriptError(where, f'unknown statement {tokens[0]!r}')
        handler(where, args, block) if verb in ('repeat', 'define', 'if') else handler(where, args)

    def do_setup(self, where, args):
        for item in args:
            key, _, value = item.partition('=')
            if key not in ('map', 'timeout', 'autoshot', 'stall', 'res', 'start', 'hostgrabs') or not value:
                raise ScriptError(where, f'setup takes map=, timeout=, autoshot=, stall=, res=, start=, hostgrabs=; got {item!r}')
            # hostgrabs=off: the dedicated host's "Zed grabs" permission (scripted_mp only).
            if key == 'hostgrabs' and value not in ('on', 'off'):
                raise ScriptError(where, 'hostgrabs is on or off')
            if key == 'start' and value not in ('first', 'keep') and not re.fullmatch(r'-?[\d.]+,-?[\d.]+,-?[\d.]+(,-?[\d.]+)?', value):
                raise ScriptError(where, 'start is first, keep or X,Y,Z[,Yaw]')
            if key == 'res':
                # Window and screenshot resolution, WxH (default 640x360).
                size = re.fullmatch(r'(\d{3,4})x(\d{3,4})', value)
                if not size or not (320 <= int(size[1]) <= 3840 and 180 <= int(size[2]) <= 2160):
                    raise ScriptError(where, 'res is WxH, 320x180..3840x2160')
            if key == 'stall':
                # Seconds without any game-state change before a case fails (0: off).
                value = str(int(float(seconds(value, where))))
                if not 0 <= int(value) <= 600:
                    raise ScriptError(where, 'stall must be 0..600 seconds')
            if key == 'timeout':
                value = str(int(float(seconds(value, where))))
                if not 30 <= int(value) <= 3000:
                    raise ScriptError(where, 'timeout must be 30..3000 seconds')
            if key == 'autoshot' and value not in ('on', 'off'):
                raise ScriptError(where, 'autoshot is on or off')
            self.out.setup[key] = value

    def do_set(self, where, args):
        if not args:
            raise ScriptError(where, 'set Key=Value ...')
        for item in args:
            key, _, value = item.partition('=')
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key) or not re.fullmatch(r'[A-Za-z0-9_.\-]+', value):
                raise ScriptError(where, f'bad setting {item!r}')
            self.out.settings[key] = value

    def do_preset(self, where, args):
        if len(args) != 1 or args[0] not in PRESETS:
            raise ScriptError(where, 'preset advanced|classic')
        self.out.settings.update(PRESETS[args[0]])

    def do_include(self, where, args):
        if len(args) != 1:
            raise ScriptError(where, 'include <file>')
        path = (self.include_root or Path('.'))/args[0].strip('"')
        if not path.is_file():
            raise ScriptError(where, f'no such include {path}')
        self.depth += 1
        if self.depth > 8:
            raise ScriptError(where, 'includes nest deeper than 8')
        self.out.sources.append(str(path))
        self.run(self.statements(path.read_text(encoding='utf-8'), str(path)))
        self.depth -= 1

    @staticmethod
    def signature(text):
        """name or name(a, b) -> (name, [params]); an argument may hold its own
        parentheses, e.g. punch(right, nearest(KFPawn_Monster))."""
        match = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_-]*)(?:\((.*)\))?', text)
        if not match:
            return None, None
        params, depth, current = [], 0, ''
        for char in match[2] or '':
            depth += (char == '(') - (char == ')')
            if depth < 0:
                return None, None
            if char == ',' and depth == 0:
                params.append(current); current = ''
            else:
                current += char
        if depth:
            return None, None
        params.append(current)
        return match[1], [p.strip() for p in params if p.strip()]

    def do_define(self, where, args, block):
        name, params = self.signature(args[0]) if len(args) == 1 else (None, None)
        if name is None or block is None or not all(re.fullmatch(r'[A-Za-z_]\w*', p) for p in params):
            raise ScriptError(where, 'define <name> { ... } or define <name>(a, b) { ... $a ... }')
        self.macros[name] = (params, block)

    def do_do(self, where, args):
        name, values = self.signature(' '.join(args)) if args else (None, None)
        if name not in self.macros:
            raise ScriptError(where, f'unknown macro {" ".join(args)!r}')
        params, block = self.macros[name]
        if len(values) != len(params):
            raise ScriptError(where, f'{name} takes {len(params)} argument(s): {", ".join(params) or "none"}')
        self.depth += 1
        if self.depth > 16:
            raise ScriptError(where, 'macros nest deeper than 16')
        self.run(self.bind(block, dict(zip(params, values))))
        self.depth -= 1

    def bind(self, block, values):
        """Copy a macro body with $param replaced by its argument."""
        if not values:
            return block
        def token(t):
            if isinstance(t, list):
                return self.bind(t, values)
            for key in sorted(values, key=len, reverse=True):
                t = t.replace('$'+key, values[key])
            return t
        return [(where, [token(t) for t in tokens]) for where, tokens in block]

    def do_repeat(self, where, args, block):
        if block is None:
            raise ScriptError(where, 'repeat <n> { ... } | repeat until <probe> <op> <value> [max N] { ... }')
        if args and args[0] == 'until':
            # Runtime loop: the body runs, then jumps back while the condition is false.
            name, op, value, rest = condition(args[1:], where)
            found, _ = options(rest, where, {'max'})
            start = len(self.out.ops)
            self.run(block)
            self.emit(where, 'loop', to=str(start), probe=name, op=op, v=value,
                      max=str(int(float(number(found.get('max', '100'), where, 1, 100000)))))
            return
        if len(args) != 1:
            raise ScriptError(where, 'repeat <n> { ... }')
        count = int(float(number(args[0], where, 1, 1000)))
        for _ in range(count):
            self.run(block)

    def do_if(self, where, args, block, otherwise=None):
        if block is None:
            raise ScriptError(where, 'if <probe> <op> <value> { ... } [else { ... }]')
        name, op, value, rest = condition(args, where)
        if rest:
            raise ScriptError(where, 'if <probe> <op> <value> { ... } [else { ... }]')
        at = len(self.out.ops)
        self.emit(where, 'unless', probe=name, op=op, v=value, skip='0')
        self.run(block)
        if otherwise is not None:
            jump = len(self.out.ops)
            self.emit(where, 'jump', skip='0')
        self.out.ops[at] = self.out.ops[at].rsplit('|skip=', 1)[0]+f'|skip={len(self.out.ops)-at-1}'
        if otherwise is not None:
            self.run(otherwise)
            self.out.ops[jump] = self.out.ops[jump].rsplit('|skip=', 1)[0]+f'|skip={len(self.out.ops)-jump-1}'

    def do_draw(self, where, args):
        if len(args) < 2:
            raise ScriptError(where, 'draw <hand> <weapon> [timeout T]')
        found, _ = options(args[2:], where, {'timeout'})
        try:
            weapon = self.resolve_weapon(args[1])
        except ValueError as error:
            raise ScriptError(where, str(error)) from None
        self.emit(where, 'draw', hand=hand(args[0], where)[0], weapon=weapon,
                  timeout=seconds(found.get('timeout', '10'), where))

    def motion(self, where, verb, side, target, rest, point=None):
        align, track = 'align' in rest, 'track' in rest
        rest = [r for r in rest if r not in ('align', 'track')]
        found, parallel = options(rest, where, {'offset', 'in', 'rot', 'over', 'speed', 'tol', 'timeout'})
        fields = dict(hand=side, a=target, p=point, align='1' if align else None, track='1' if track else None)
        if 'offset' in found:
            fields.update(zip(('ox', 'oy', 'oz'), triple(found['offset'], where)))
        if found.get('in', 'body') not in FRAMES:
            raise ScriptError(where, 'in body|gun|world')
        fields['frame'] = found.get('in', 'body')
        if 'rot' in found:
            fields.update(rot='1', **dict(zip(('rp', 'ry', 'rr'), triple(found['rot'], where))))
        if 'over' in found: fields['over'] = seconds(found['over'], where)
        if 'speed' in found: fields['speed'] = number(found['speed'], where, 1, 1000)
        if 'tol' in found: fields['tol'] = number(found['tol'], where, .1, 50)
        if 'timeout' in found: fields['timeout'] = seconds(found['timeout'], where)
        return fields, parallel

    def do_pose(self, where, args):
        if len(args) < 2:
            raise ScriptError(where, 'pose <hand|both> <anchor> [offset (x,y,z)] [in F] [rot (p,y,r)] [over T] [&]')
        sides = hand(args[0], where, allow_both=True)
        for i, side in enumerate(sides):
            fields, parallel = self.motion(where, 'pose', side, anchor(args[1], where, side), args[2:])
            self.emit(where, 'pose', par='1' if parallel or i < len(sides)-1 else None, **fields)

    def do_move(self, where, args):
        # move <hand> [<point>] to <anchor> ...
        if 'to' not in args or args.index('to') not in (1, 2) or len(args) < args.index('to')+2:
            raise ScriptError(where, 'move <hand> [<carried point>] to <anchor> [speed V] [tol D] [timeout T] [&]')
        at = args.index('to')
        side = hand(args[0], where)[0]
        point = anchor(args[1], where, side) if at == 2 else None
        fields, parallel = self.motion(where, 'move', side, anchor(args[at+1], where, side), args[at+2:], point)
        self.emit(where, 'move', par='1' if parallel else None, **fields)

    def do_nudge(self, where, args):
        if len(args) < 2:
            raise ScriptError(where, 'nudge <hand|both> (x,y,z) [in F] over T [&]')
        sides = hand(args[0], where, allow_both=True)
        delta = triple(args[1], where)
        found, parallel = options(args[2:], where, {'in', 'over'})
        if found.get('in', 'body') not in FRAMES + ('rack', 'bore', 'pump'):
            raise ScriptError(where, 'in body|gun|world|rack|bore|pump')
        for i, side in enumerate(sides):
            self.emit(where, 'nudge', hand=side, dx=delta[0], dy=delta[1], dz=delta[2],
                      frame=found.get('in', 'body'), over=seconds(found.get('over', '0.2'), where),
                      par='1' if parallel or i < len(sides)-1 else None)

    def button(self, where, value):
        name = BUTTON_ALIASES.get(value.lower(), value.lower())
        if name not in ('trigger', 'grip', 'primary', 'secondary', 'stick', 'menu'):
            raise ScriptError(where, f'unknown button {value!r}')
        return name

    def do_press(self, where, args):
        if len(args) not in (2, 3):
            raise ScriptError(where, 'press <hand|both> <button> [duration]')
        sides, name = hand(args[0], where, True), self.button(where, args[1])
        for side in sides: self.emit(where, 'button', hand=side, b=name, down='1')
        self.emit(where, 'wait', t=seconds(args[2] if len(args) == 3 else '0.1', where))
        for side in sides: self.emit(where, 'button', hand=side, b=name, down='0')

    def do_hold(self, where, args):
        if len(args) != 2:
            raise ScriptError(where, 'hold <hand|both> <button>')
        for side in hand(args[0], where, True):
            self.emit(where, 'button', hand=side, b=self.button(where, args[1]), down='1')

    def do_release(self, where, args):
        if len(args) != 2:
            raise ScriptError(where, 'release <hand|both> <button|all>')
        names = ['trigger', 'grip', 'primary', 'secondary', 'stick', 'menu'] if args[1] == 'all' else [self.button(where, args[1])]
        for side in hand(args[0], where, True):
            for name in names:
                self.emit(where, 'button', hand=side, b=name, down='0')

    def do_stick(self, where, args):
        if len(args) not in (3, 5) or (len(args) == 5 and args[3] != 'for'):
            raise ScriptError(where, 'stick <hand> <x> <y> [for T]')
        side = hand(args[0], where)[0]
        self.emit(where, 'stick', hand=side, x=number(args[1], where, -1, 1), y=number(args[2], where, -1, 1))
        if len(args) == 5:
            self.emit(where, 'wait', t=seconds(args[4], where))
            self.emit(where, 'stick', hand=side, x='0', y='0')

    def do_walk(self, where, args):
        directions = {'forward': (0, 1), 'back': (0, -1), 'left': (-1, 0), 'right': (1, 0)}
        if len(args) not in (2, 4) or args[0] not in directions or (len(args) == 4 and args[2] != 'speed'):
            raise ScriptError(where, 'walk forward|back|left|right <duration> [speed 0..1]')
        scale = float(number(args[3], where, 0, 1)) if len(args) == 4 else 1.0
        x, y = directions[args[0]]
        self.do_stick(where, ['left', f'{x*scale:g}', f'{y*scale:g}', 'for', args[1]])

    def do_snap(self, where, args):
        if len(args) != 3 or args[1] != 'as' or not re.fullmatch(r'[A-Za-z_]\w*', args[2]):
            raise ScriptError(where, 'snap <probe> as <name>   (compare later with @name)')
        self.emit(where, 'snap', probe=probe(args[0], where), name=args[2])

    def do_stroke(self, where, args):
        # stroke <hand> [<gun hand>] to <0..1> [speed V] [tol D] [timeout T]
        if 'to' not in args or args.index('to') not in (1, 2) or len(args) < args.index('to') + 2:
            raise ScriptError(where, 'stroke <hand> [<gun L|R>] to <0..1> [speed V] [tol D] [timeout T]')
        at = args.index('to')
        gun = HANDS[args[1].lower()] if at == 2 and args[1].lower() in HANDS else None
        if at == 2 and gun is None:
            raise ScriptError(where, f'unknown gun hand {args[1]!r}')
        soft = 'soft' in args[at+2:]   # a soft stroke just stops at its timeout
        found, _ = options([a for a in args[at+2:] if a != 'soft'], where, {'speed', 'timeout', 'tol'})
        self.emit(where, 'stroke', hand=hand(args[0], where)[0], gun=gun, s=number(args[at+1], where, 0, 1),
                  speed=number(found.get('speed', '60'), where, 1, 500), timeout=seconds(found.get('timeout', '8'), where),
                  tol=number(found.get('tol', '0.05'), where, 0.005, 0.5), soft='1' if soft else None)

    # Friendly zed names -> the stock SpawnZed prefixes (KFCheatManager.LoadMonsterByName).
    ZEDS = {'clot': 'ClotA', 'alpha': 'ClotA', 'cyst': 'ClotC', 'slasher': 'ClotS', 'gorefast': 'GF',
            'crawler': 'Crawler', 'stalker': 'Stalker', 'bloat': 'Bloat', 'siren': 'Siren', 'husk': 'Husk',
            'scrake': 'Scrake', 'fleshpound': 'FP', 'fp': 'FP'}

    def do_spawn(self, where, args):
        # spawn <zed> [dist D] [yaw Y]: the stock SpawnZed cheat (standalone),
        # D UU ahead along the view turned by Y degrees.
        if not args or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', args[0]):
            raise ScriptError(where, 'spawn <zed> [dist D] [yaw Y]')
        found, _ = options(args[1:], where, {'dist', 'yaw'})
        self.emit(where, 'spawn', zed=self.ZEDS.get(args[0].lower(), args[0]),
                  dist=number(found.get('dist', '300'), where, 50, 5000), yaw=number(found.get('yaw', '0'), where, -180, 180))

    def do_trace(self, where, args):
        # trace <probe>... [every T] [for T]: log probes in the background while later ops run.
        split = next((i for i, a in enumerate(args) if a in ('every', 'for')), len(args))
        found, _ = options(args[split:], where, {'every', 'for'})
        probes = [probe(n, where) for n in args[:split]]
        if not probes:
            raise ScriptError(where, 'trace <probe>... [every T] [for T]')
        self.emit(where, 'trace', probes=','.join(probes), every=seconds(found.get('every', '0.1'), where),
                  **{'for': seconds(found.get('for', '30'), where)})

    def do_setammo(self, where, args):
        # setammo <hand> [mag N] [reserve N] [mag2 N] [reserve2 N]: test setup counts.
        if not args:
            raise ScriptError(where, 'setammo <hand> [mag N] [reserve N] [mag2 N] [reserve2 N]')
        found, _ = options(args[1:], where, {'mag', 'reserve', 'mag2', 'reserve2'})
        self.emit(where, 'setammo', hand=hand(args[0], where)[0],
                  **{k: str(int(number(v, where, 0, 10000))) for k, v in found.items()})

    def do_aim(self, where, args):
        # aim <hand> at <anchor>: point the hand's controller axis (the gravity grab's aim) at it.
        if len(args) != 3 or args[1] != 'at':
            raise ScriptError(where, 'aim <hand> at <anchor>')
        side = hand(args[0], where)[0]
        self.emit(where, 'aim', hand=side, a=anchor(args[2], where, side))

    def do_dosh(self, where, args):
        if len(args) != 1:
            raise ScriptError(where, 'dosh <amount>')
        self.emit(where, 'dosh', n=str(int(number(args[0], where, 1, 1000000))))

    def do_netdrop(self, where, args):
        # netdrop magazine [N]: the owner ignores the authority's next N
        # magazine-channel replies (fault injection for lost-reply expiry).
        if len(args) not in (1, 2) or args[0] != 'magazine':
            raise ScriptError(where, 'netdrop magazine [count]')
        self.emit(where, 'netdrop', kind=args[0], n=str(int(number(args[1] if len(args) == 2 else '1', where, 1, 20))))

    def do_perk(self, where, args):
        # perk <class>, e.g. KFPerk_Demolitionist.
        if len(args) != 1 or not re.fullmatch(r'KFPerk_[A-Za-z0-9_]+', args[0]):
            raise ScriptError(where, 'perk <KFPerk_...>')
        self.emit(where, 'perk', perk=args[0])

    def do_buy(self, where, args):
        # buy <weapon>: a trader purchase through the stock server path.
        if len(args) != 1:
            raise ScriptError(where, 'buy <weapon>')
        try:
            weapon = self.resolve_weapon(args[0])
        except ValueError as error:
            raise ScriptError(where, str(error)) from None
        self.emit(where, 'buy', weapon=weapon)

    def do_trader(self, where, args):
        # trader open|close: open through the stock trader-trigger path (the
        # server's OpenTraderMenu, forced outside trader time); read it with
        # the `trader` probe. Close shuts the menu as the player would.
        if len(args) != 1 or args[0] not in ('open', 'close'):
            raise ScriptError(where, 'trader open|close')
        self.emit(where, 'trader', act=args[0])

    def do_empty_reload(self, where, args):
        # A deliberate reload that may end with no rounds added (closing an
        # unloaded cylinder, #81): the hand's next ledger close skips "reload-added".
        if len(args) != 1:
            raise ScriptError(where, 'empty-reload <hand>')
        self.emit(where, 'emptyreload', hand=hand(args[0], where)[0])

    def do_goto(self, where, args):
        # goto <anchor> [dist D | tol D] [face] [path] [speed 0..1] [timeout T]
        # path: steer along the level's navigation network (FindPathTo) instead
        # of a straight line, for targets around walls and corners.
        if not args:
            raise ScriptError(where, 'goto <anchor> [dist D] [face] [path] [speed 0..1] [timeout T]')
        face = 'face' in args[1:]
        path = 'path' in args[1:]
        found, _ = options([a for a in args[1:] if a not in ('face', 'path')], where, {'tol', 'dist', 'speed', 'timeout', 'ahead'})
        stop = found.get('dist', found.get('tol', '20'))
        # ahead D: stand D UU along the anchor's own facing (in front of a pawn), facing the anchor.
        self.emit(where, 'goto', a=anchor(args[0], where), tol=number(stop, where, 1, 500),
                  speed=number(found.get('speed', '1'), where, 0.1, 1), timeout=seconds(found.get('timeout', '8'), where),
                  face='1' if face else None, path='1' if path else None,
                  ahead=number(found['ahead'], where, -2000, 2000) if 'ahead' in found else None)

    def do_turn(self, where, args):
        if len(args) not in (1, 2) or args[0] not in ('left', 'right'):
            raise ScriptError(where, 'turn left|right [duration]')
        self.do_stick(where, ['right', '-1' if args[0] == 'left' else '1', '0', 'for', args[1] if len(args) == 2 else '0.15'])

    def do_look(self, where, args):
        # look at <anchor> [over T] [&]: turn the head (and view) onto an anchor.
        if args and args[0] == 'at':
            if len(args) < 2:
                raise ScriptError(where, 'look at <anchor> [over T] [&]')
            found, parallel = options(args[2:], where, {'over'})
            self.emit(where, 'look', at=anchor(args[1], where), over=seconds(found.get('over', '0'), where),
                      par='1' if parallel else None)
            return
        found, parallel = options(args, where, {'yaw', 'pitch', 'roll', 'over'})
        self.emit(where, 'look', rp=number(found.get('pitch', '0'), where, -89, 89),
                  ry=number(found.get('yaw', '0'), where, -180, 180), rr=number(found.get('roll', '0'), where, -90, 90),
                  over=seconds(found.get('over', '0'), where), par='1' if parallel else None)

    def do_wait(self, where, args):
        if args and args[0] == 'until':
            name, op, value, rest = condition(args[1:], where)
            soft = 'soft' in rest   # a soft wait just moves on at its timeout
            found, _ = options([r for r in rest if r != 'soft'], where, {'timeout'})
            self.emit(where, 'until', probe=name, op=op, v=value, within=seconds(found.get('timeout', '10'), where),
                      soft='1' if soft else None)
        elif len(args) == 1:
            self.emit(where, 'wait', t=seconds(args[0], where))
        else:
            raise ScriptError(where, 'wait <duration> | wait until <probe> <op> <value> [timeout T]')

    def do_sync(self, where, args):
        if args: raise ScriptError(where, 'sync takes no arguments')
        self.emit(where, 'sync')

    def log_check(self, where, kind, args):
        if not args or not (args[0].startswith('/') and args[0].endswith('/') and len(args[0]) > 2):
            raise ScriptError(where, f'{kind} log /regex/ [since MARK]')
        pattern = args[0][1:-1]
        try:
            re.compile(pattern)
        except re.error as error:
            raise ScriptError(where, f'bad regex: {error}') from None
        found, _ = options(args[1:], where, {'since'})
        self.out.log_checks.append(dict(kind=kind, pattern=pattern, since=found.get('since'), where=where))
        if found.get('since') and found['since'] not in self.marks():
            raise ScriptError(where, f'mark {found["since"]!r} is not defined before this line')

    def marks(self):
        return {op.split('|name=')[1].split('|')[0] for op in self.out.ops if '|mark|' in op}

    def do_expect(self, where, args):
        if args and args[0] == 'log':
            return self.log_check(where, 'expect', args[1:])
        name, op, value, rest = condition(args, where)
        found, _ = options(rest, where, {'within'})
        self.emit(where, 'expect', probe=name, op=op, v=value, within=seconds(found.get('within', '0'), where))

    def do_forbid(self, where, args):
        if not args or args[0] != 'log':
            raise ScriptError(where, 'forbid log /regex/ [since MARK]')
        self.log_check(where, 'forbid', args[1:])

    def do_watch(self, where, args):
        name, op, value, rest = condition(args, where)
        if rest: raise ScriptError(where, 'watch <probe> <op> <value>')
        self.emit(where, 'watch', probe=name, op=op, v=value)

    def do_log(self, where, args):
        if not args: raise ScriptError(where, 'log <probe> ...')
        self.emit(where, 'log', probes=','.join(probe(a, where) for a in args))

    def do_shot(self, where, args):
        pose = 'pose' in args
        names = [a for a in args if a != 'pose']
        if len(names) > 1: raise ScriptError(where, 'shot [name] [pose]')
        name = names[0].strip('"') if names else 'shot'
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,63}', name):
            raise ScriptError(where, 'shot names are letters, digits, _ and -, starting with a letter')
        self.emit(where, 'shot', name=name, pose='1' if pose else None)

    def do_console(self, where, args):
        text = ' '.join(a.strip('"') for a in args)
        if not text or len(text) > 380 or not all(32 <= ord(c) <= 126 for c in text):
            raise ScriptError(where, 'console <printable text up to 380 characters>')
        if re.match(r'\s*(quit|exit|disconnect|open)\b', text, re.I):
            raise ScriptError(where, 'the runner owns quit/travel; use end')
        self.emit(where, 'console', text=text)

    def do_mark(self, where, args):
        if len(args) != 1 or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]*', args[0]):
            raise ScriptError(where, 'mark <name>')
        self.emit(where, 'mark', name=args[0])

    def do_autoshot(self, where, args):
        if args not in (['on'], ['off']): raise ScriptError(where, 'autoshot on|off')
        self.emit(where, 'autoshot', on='1' if args[0] == 'on' else '0')

    def do_catalog(self, where, args):
        if args: raise ScriptError(where, 'catalog takes no arguments')
        self.emit(where, 'catalog')

    def do_end(self, where, args):
        if args: raise ScriptError(where, 'end takes no arguments')
        self.emit(where, 'end')


def compile_script(path, variables=None, resolve_weapon=None):
    return Compiler(variables, resolve_weapon).compile_file(path)


def check_log(log, compiled):
    """Evaluate expect/forbid log checks against the game log. Marks bound windows."""
    results = []
    marks = {m[1]: m.start() for m in re.finditer(r'KF2VR_SCRIPT line=\d+ t=\S+ mark=(\S+)', log)}
    for check in compiled.log_checks:
        start = 0
        if check['since']:
            start = marks.get(check['since'], -1)
        if start < 0:
            results.append(dict(check, passed=False, detail='mark never reached'))
            continue
        hit = re.search(check['pattern'], log[start:], re.M)
        passed = bool(hit) if check['kind'] == 'expect' else not hit
        results.append(dict(check, passed=passed, detail=hit[0][:300] if hit else ''))
    return results


def catalog_rows(log):
    """Registry rows from a `catalog` op: one dict of the game's own reload facts per weapon."""
    rows = []
    for line in log.splitlines():
        if 'KF2VR_SCRIPT' in line and ' catalog index=' in line:
            rows.append(dict(re.findall(r'(\w+)=(\S+)', line.split(' catalog ', 1)[1])))
    return rows


def runner_verdicts(log):
    """Parse ScriptRunner check lines and its completion line."""
    checks = []
    for m in re.finditer(r'KF2VR_SCRIPT line=(\d+) t=(\S+) check=(\S+) probe=(\S+) value=(\S*) op=(\S+) expected=(\S*) passed=(true|false)', log):
        checks.append(dict(line=int(m[1]), t=float(m[2]), kind=m[3], probe=m[4], value=m[5],
                           op=m[6], expected=m[7], passed=m[8] == 'true'))
    done = re.findall(r'KF2VR_SCRIPT phase=complete passed=(true|false) reason=(\S+)', log)
    return dict(checks=checks, complete=bool(done), passed=bool(done) and done[-1][0] == 'true',
                reason=done[-1][1] if done else 'no-completion-line',
                ingress_stopped='value=stopped' in log)
