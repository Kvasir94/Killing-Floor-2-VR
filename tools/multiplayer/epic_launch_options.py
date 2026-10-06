"""Prepare reversible text for Epic's visible per-game Launch Options field.

This module never writes Epic settings or launches a process. Preserve the exact
original string; restore only if the field still contains our prepared string.
"""
from dataclasses import dataclass, field
import ctypes
import os
import re
import subprocess


def tokens(text):
    if any(ord(c)<32 for c in text):
        raise ValueError('Launch options must be one line')
    # Do not reinterpret malformed quoting or silently add options inside it.
    escaped=False;quoted=False
    for c in text:
        if c=='"' and not escaped: quoted=not quoted
        escaped=(c=='\\' and not escaped)
        if c!='\\':escaped=False
    if quoted:raise ValueError('Existing launch options contain an unmatched quote')
    if os.name!='nt':raise OSError('Windows launch-option parsing requires Windows')
    shell=ctypes.WinDLL('shell32',use_last_error=True)
    shell.CommandLineToArgvW.argtypes=(ctypes.c_wchar_p,ctypes.POINTER(ctypes.c_int))
    shell.CommandLineToArgvW.restype=ctypes.POINTER(ctypes.c_wchar_p)
    kernel=ctypes.WinDLL('kernel32');kernel.LocalFree.argtypes=(ctypes.c_void_p,)
    count=ctypes.c_int();argv=shell.CommandLineToArgvW('KFGame.exe '+text,ctypes.byref(count))
    if not argv:raise OSError('Cannot parse launch options')
    try:return [argv[i] for i in range(1,count.value)]
    finally:kernel.LocalFree(argv)


def key(arg):return arg.split('=',1)[0].casefold()


def safe_arguments(arguments):
    for arg in arguments:
        if not isinstance(arg,str) or not arg or any(ord(c)<32 for c in arg) or '"' in arg:
            raise ValueError('Invalid generated launch argument')
        if key(arg).startswith(('-auth_','-epic')):
            raise ValueError('Epic account arguments must remain inside Epic Launcher')


def render(arguments):
    safe_arguments(arguments)
    output=[]
    for arg in arguments:
        if arg.startswith('-') and '=' in arg:
            k,v=arg.split('=',1)
            if any(c.isspace() for c in v):
                output.append(k+'="'+v+'"');continue
        output.append(subprocess.list2cmdline([arg]))
    return ' '.join(output)


@dataclass(frozen=True)
class LaunchOptionsPlan:
    original: str = field(repr=False)
    prepared: str = field(repr=False)

    def restore_text(self,current):
        if current!=self.prepared:
            raise ValueError('Launch Options changed after preparation; preserve the current text for review')
        return self.original


def prepare(existing,arguments):
    old=tokens(existing);safe_arguments(arguments)
    if any(key(arg).startswith(('-auth_','-epic')) for arg in old):
        raise ValueError('Do not copy account authentication arguments into launch options')
    if any(not arg.startswith('-') for arg in old):
        raise ValueError('Existing launch options contain a map/URL or positional argument; preserve and review it')
    prior={key(arg):arg for arg in old};added=[]
    for arg in arguments:
        k=key(arg)
        if k in prior:
            if prior[k]!=arg:raise ValueError('Existing launch option conflicts with this VR session: '+k)
            continue
        prior[k]=arg;added.append(arg)
    suffix=render(added)
    separator=' ' if existing and not existing[-1].isspace() and suffix else ''
    return LaunchOptionsPlan(existing,existing+separator+suffix)


def prepare_session(existing,arguments,broker):
    """Create reviewable field text; never activate, deploy, or edit Epic."""
    keys={key(arg) for arg in arguments}
    if '-kf2vr-probe' not in keys or '-kf2vr-stereo' not in keys:
        raise ValueError('Epic VR startup requires both proxy opt-in and stereo flags')
    if not keys.intersection({'-onethread','-kf2vr-threaded-render'}):
        raise ValueError('Epic VR startup requires an explicit supported render mode')
    if not {'-engineini','-gameini','-inputini','-systemsettingsini'}.issubset(keys):
        raise ValueError('Epic VR startup requires isolated session INI paths')
    if any('replay' in arg.casefold() for arg in arguments if arg.startswith('-')):
        raise ValueError('Epic managed handoff is for player sessions, not replay runs')
    if '-kf2vr-epic-session' in keys:
        raise ValueError('The broker supplies the session marker; do not reuse one')
    return prepare(existing,[*arguments,broker.argument])
