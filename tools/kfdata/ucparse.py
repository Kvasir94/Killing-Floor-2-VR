"""
UnrealScript parser -> JSON.

Extracts, per .uc class: the class declaration and modifiers, the full inheritance
edge, declared vars, and the defaultproperties block (including nested
Begin Object / End Object subobjects and array element assignments).

This is deliberately a *lexical* parser, not a full grammar: defaultproperties is
a simple key=value dialect, which is all we need to recover KF2's balance data.
"""
import re, os, sys, json, io

RE_CLASS = re.compile(
    r'^\s*class\s+(?P<name>\w+)\s*(?:extends\s+(?P<parent>[\w.]+))?(?P<mods>[^;]*);',
    re.I | re.M)
RE_VAR = re.compile(
    r'^\s*var\s*(?:\((?P<cat>[^)]*)\))?\s*(?P<mods>(?:\s*(?:config|const|native|transient|'
    r'repnotify|globalconfig|localized|private|protected|editconst|editinline|export|'
    r'noexport|deprecated|instanced|databinding|interp|nontransactional|duplicatetransient)\b)*)'
    r'\s+(?P<type>[\w<>., \t]+?)\s+(?P<names>[\w\[\]\s,]+);', re.I | re.M)


def strip_comments(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n:
            if src[i+1] == '/':
                j = src.find('\n', i)
                i = n if j < 0 else j
                continue
            if src[i+1] == '*':
                depth, i = 1, i + 2       # UnrealScript nests /* */
                while i < n and depth:
                    if src.startswith('/*', i): depth += 1; i += 2
                    elif src.startswith('*/', i): depth -= 1; i += 2
                    else: i += 1
                continue
        if c == '"':                       # keep string literals intact
            j = i + 1
            while j < n and src[j] != '"':
                j += 2 if src[j] == chr(92) else 1
            out.append(src[i:j+1]); i = j + 1
            continue
        out.append(c); i += 1
    return ''.join(out)


def find_defaults(src):
    """Return the raw text inside defaultproperties{...}, brace-balanced."""
    m = re.search(r'^\s*(defaultproperties|structdefaultproperties)\s*\{',
                  src, re.I | re.M)
    if not m:
        return None
    i = m.end() - 1
    depth, start = 0, i
    while i < len(src):
        if src[i] == '{': depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[start+1:i]
        i += 1
    return src[start+1:]


def parse_defaults(text):
    """
    Parse a defaultproperties body into a dict.
    Nested `Begin Object ... End Object` become dicts under `__subobjects__`.
    """
    props, subs = {}, []
    lines = text.splitlines()
    idx = 0
    while idx < len(lines):
        line = lines[idx].strip()
        idx += 1
        if not line:
            continue
        if re.match(r'^Begin\s+Object', line, re.I):
            hdr = dict(re.findall(r'(\w+)\s*=\s*([\w.\'"]+)', line))
            body, depth = [], 1
            while idx < len(lines) and depth:
                l2 = lines[idx]; idx += 1
                if re.match(r'^\s*Begin\s+Object', l2, re.I): depth += 1
                elif re.match(r'^\s*End\s+Object', l2, re.I):
                    depth -= 1
                    if depth == 0: break
                body.append(l2)
            sub = parse_defaults('\n'.join(body))
            sub['__header__'] = hdr
            subs.append(sub)
            continue
        if re.match(r'^End\s+Object', line, re.I):
            continue
        # key=value, where value may be a (...) or {...} literal spanning lines
        m = re.match(r'^([\w\[\]().]+)\s*=\s*(.*)$', line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        # balance parens/braces across lines for struct literals
        while val.count('(') > val.count(')') or val.count('{') > val.count('}'):
            if idx >= len(lines): break
            val += ' ' + lines[idx].strip(); idx += 1
        props.setdefault(key, [])
        props[key].append(val)
    # collapse single-valued keys
    flat = {k: (v[0] if len(v) == 1 else v) for k, v in props.items()}
    if subs:
        flat['__subobjects__'] = subs
    return flat


def parse_file(path):
    try:
        src = open(path, 'r', encoding='utf-8', errors='replace').read()
    except OSError as e:
        return {'file': path, 'error': str(e)}
    src = strip_comments(src)
    cm = RE_CLASS.search(src)
    if not cm:
        return None
    rec = {
        'file': os.path.basename(path),
        'path': path,
        'class': cm.group('name'),
        'parent': (cm.group('parent') or '').split('.')[-1] or None,
        'modifiers': ' '.join((cm.group('mods') or '').split()),
        'lines': src.count('\n') + 1,
    }
    vars_ = []
    for vm in RE_VAR.finditer(src):
        for nm in vm.group('names').split(','):
            nm = nm.strip()
            if not nm: continue
            vars_.append({
                'name': nm,
                'type': ' '.join(vm.group('type').split()),
                'category': (vm.group('cat') or '').strip() or None,
                'modifiers': ' '.join((vm.group('mods') or '').split()) or None,
            })
    rec['vars'] = vars_
    dp = find_defaults(src)
    rec['defaults'] = parse_defaults(dp) if dp is not None else {}
    # counts of port-hostile constructs
    rec['stats'] = {
        'states': len(re.findall(r'^\s*(?:auto\s+|simulated\s+)*state\s+\w+', src, re.I | re.M)),
        'native_funcs': len(re.findall(r'\bnative(?:\(\d+\))?\s+(?:final\s+|static\s+|simulated\s+|noexport\s+)*function', src, re.I)),
        'functions': len(re.findall(r'^\s*(?:[\w()]+\s+)*function\s+', src, re.I | re.M)),
        'events': len(re.findall(r'^\s*(?:[\w()]+\s+)*event\s+', src, re.I | re.M)),
        'replicated': 1 if re.search(r'^\s*replication\s*\{', src, re.I | re.M) else 0,
    }
    return rec


def main(root, out):
    recs, n = [], 0
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if not fn.lower().endswith('.uc'):
                continue
            r = parse_file(os.path.join(dirpath, fn))
            n += 1
            if r: recs.append(r)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(recs, f, indent=1)
    print(f'scanned {n} files, parsed {len(recs)} classes -> {out}', file=sys.stderr)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
