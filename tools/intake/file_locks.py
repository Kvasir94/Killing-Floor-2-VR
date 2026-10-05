"""Read-only Windows Restart Manager query for a named fixture artifact."""
import ctypes as c
from ctypes import wintypes as w
import json
import sys

class UniqueProcess(c.Structure):
    _fields_ = [('pid', w.DWORD), ('started', w.FILETIME)]
class ProcessInfo(c.Structure):
    _fields_ = [('process', UniqueProcess), ('app_name', w.WCHAR * 256),
                ('service_name', w.WCHAR * 64), ('app_type', c.c_int),
                ('status', w.ULONG), ('session_id', w.DWORD), ('restartable', w.BOOL)]

def query(path):
    api = c.WinDLL('rstrtmgr')
    session = w.DWORD()
    key = c.create_unicode_buffer(33)
    result = api.RmStartSession(c.byref(session), 0, key)
    if result: raise OSError(result, 'RmStartSession')
    try:
        filenames = (w.LPCWSTR * 1)(path)
        result = api.RmRegisterResources(session, 1, filenames, 0, None, 0, None)
        if result: raise OSError(result, 'RmRegisterResources')
        needed, count, reason = w.UINT(), w.UINT(), w.DWORD()
        result = api.RmGetList(session, c.byref(needed), c.byref(count), None, c.byref(reason))
        if result == 0: return []
        if result != 234: raise OSError(result, 'RmGetList')
        count.value = needed.value
        processes = (ProcessInfo * count.value)()
        result = api.RmGetList(session, c.byref(needed), c.byref(count), processes, c.byref(reason))
        if result: raise OSError(result, 'RmGetList')
        return [{'pid': p.process.pid, 'app': p.app_name, 'service': p.service_name,
                 'session_id': p.session_id} for p in processes[:count.value]]
    finally:
        api.RmEndSession(session)

if __name__ == '__main__':
    for filename in sys.argv[1:]:
        print(json.dumps({'file': filename, 'users': query(filename)}))
