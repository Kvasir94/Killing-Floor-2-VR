"""One-shot, same-user Windows pipe broker for an Epic-started KF2 process.

No game launch or deployment occurs here. The caller owns the prepared session
and must persist the accepted OS process identity before allowing gameplay.
"""
import ctypes as c
from ctypes import wintypes as w
import hashlib
import os
from pathlib import Path
import threading
import time
from epic_session import ProcessIdentity, filetime_now

class OVERLAPPED(c.Structure):
    _fields_=[('Internal',c.c_size_t),('InternalHigh',c.c_size_t),('Offset',w.DWORD),('OffsetHigh',w.DWORD),('hEvent',w.HANDLE)]


def api():
    k=c.WinDLL('kernel32',use_last_error=True)
    specs={
      'CreateNamedPipeW':(w.HANDLE,[w.LPCWSTR,w.DWORD,w.DWORD,w.DWORD,w.DWORD,w.DWORD,w.DWORD,c.c_void_p]),
      'ConnectNamedPipe':(w.BOOL,[w.HANDLE,c.POINTER(OVERLAPPED)]),
      'ReadFile':(w.BOOL,[w.HANDLE,c.c_void_p,w.DWORD,c.POINTER(w.DWORD),c.POINTER(OVERLAPPED)]),
      'WriteFile':(w.BOOL,[w.HANDLE,c.c_void_p,w.DWORD,c.POINTER(w.DWORD),c.POINTER(OVERLAPPED)]),
      'GetOverlappedResult':(w.BOOL,[w.HANDLE,c.POINTER(OVERLAPPED),c.POINTER(w.DWORD),w.BOOL]),
      'CancelIoEx':(w.BOOL,[w.HANDLE,c.POINTER(OVERLAPPED)]),
      'CreateEventW':(w.HANDLE,[c.c_void_p,w.BOOL,w.BOOL,w.LPCWSTR]),
      'WaitForSingleObject':(w.DWORD,[w.HANDLE,w.DWORD]),
      'CloseHandle':(w.BOOL,[w.HANDLE]),
      'GetNamedPipeClientProcessId':(w.BOOL,[w.HANDLE,c.POINTER(w.ULONG)]),
      'OpenProcess':(w.HANDLE,[w.DWORD,w.BOOL,w.DWORD]),
      'QueryFullProcessImageNameW':(w.BOOL,[w.HANDLE,w.DWORD,w.LPWSTR,c.POINTER(w.DWORD)]),
      'GetProcessTimes':(w.BOOL,[w.HANDLE]+[c.POINTER(c.c_uint64)]*4),
      'GetCurrentProcess':(w.HANDLE,[]),
      'LocalFree':(c.c_void_p,[c.c_void_p]),
    }
    for name,(result,args) in specs.items():
        fn=getattr(k,name);fn.restype=result;fn.argtypes=args
    return k


def process_identity(k,pid):
    handle=k.OpenProcess(0x1000|0x100000,False,pid)
    if not handle:raise OSError('Cannot hold Epic peer process')
    try:
        name=c.create_unicode_buffer(32768);size=w.DWORD(len(name))
        times=[c.c_uint64() for _ in range(4)]
        if not k.QueryFullProcessImageNameW(handle,0,name,c.byref(size)) or not k.GetProcessTimes(handle,*[c.byref(t) for t in times]):
            raise OSError('Cannot identify Epic peer process')
        with Path(name.value).open('rb') as stream:sha=hashlib.file_digest(stream,'sha256').hexdigest().upper()
        return ProcessIdentity(pid,times[0].value,Path(name.value),sha),handle
    except BaseException:
        k.CloseHandle(handle);raise


def user_security(k):
    a=c.WinDLL('advapi32',use_last_error=True)
    a.OpenProcessToken.argtypes=(w.HANDLE,w.DWORD,c.POINTER(w.HANDLE))
    a.GetTokenInformation.argtypes=(w.HANDLE,c.c_int,c.c_void_p,w.DWORD,c.POINTER(w.DWORD))
    a.ConvertSidToStringSidW.argtypes=(c.c_void_p,c.POINTER(c.c_void_p))
    a.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes=(w.LPCWSTR,w.DWORD,c.POINTER(c.c_void_p),c.c_void_p)
    token=w.HANDLE();sid_text=c.c_void_p();descriptor=c.c_void_p()
    if not a.OpenProcessToken(k.GetCurrentProcess(),8,c.byref(token)):raise OSError('Cannot identify broker user')
    try:
        size=w.DWORD();a.GetTokenInformation(token,1,None,0,c.byref(size))
        data=c.create_string_buffer(size.value)
        if not a.GetTokenInformation(token,1,data,size,c.byref(size)):raise OSError('Cannot read broker user identity')
        sid=c.cast(data,c.POINTER(c.c_void_p))[0]
        if not a.ConvertSidToStringSidW(sid,c.byref(sid_text)):raise OSError('Cannot build broker ACL')
        sddl='D:P(A;;GA;;;'+c.wstring_at(sid_text)+')'
        if not a.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,1,c.byref(descriptor),None):raise OSError('Cannot build broker ACL')
        return descriptor
    finally:
        if sid_text:k.LocalFree(sid_text)
        k.CloseHandle(token)


class SECURITY_ATTRIBUTES(c.Structure):
    _fields_=[('nLength',w.DWORD),('lpSecurityDescriptor',c.c_void_p),('bInheritHandle',w.BOOL)]


class EpicBroker:
    def __init__(self,ticket,session_root,*,on_claim,eye_percent=100):
        requested=Path(session_root).absolute()
        self.ticket=ticket;self.root=requested.resolve();self.eye_percent=eye_percent
        if requested!=self.root:raise ValueError("Linked session root is not accepted")
        if not callable(on_claim):raise ValueError("A durable ownership journal callback is required")
        self.on_claim=on_claim;self.ready=threading.Event();self.error=None;self.owner_handle=None
        self._pipe=None;self._pipe_lock=threading.Lock();self._observed=[]
        if type(eye_percent) is not int or not 50<=eye_percent<=100:raise ValueError('Invalid eye render percentage')
        self._validate_root()
        self.kernel=api()
        self.broker_identity,handle=process_identity(self.kernel,os.getpid());self.kernel.CloseHandle(handle)

    def _validate_root(self):
        if not self.root.is_dir() or self.root.is_symlink() or self.root.is_junction():raise ValueError('Session root must be an existing ordinary directory')
        if any(c in str(self.root) for c in '\r\n\x00'):raise ValueError('Invalid session root')
        for name in ('native.log','stop.request','playable.ready'):
            if (self.root/name).exists() or (self.root/name).is_symlink():raise ValueError('Session output already exists; preserve it')

    @property
    def argument(self):
        # Public session identity and process birth stamp; no nonce or account credential.
        return f'-kf2vr-epic-session={self.ticket.session_id}:{self.broker_identity.pid}:{self.broker_identity.creation_time}'

    @property
    def pipe_name(self):return r'\\.\pipe\KF2VR.Epic.'+self.ticket.session_id

    def _io(self,pipe,operation,payload=None):
        if self.ticket.cancelled:raise ValueError("Epic handoff was cancelled")
        k=self.kernel;ov=OVERLAPPED();ov.hEvent=k.CreateEventW(None,True,False,None)
        if not ov.hEvent:raise OSError('Cannot create broker event')
        count=w.DWORD();pending=False
        buffer=c.create_string_buffer(payload) if payload is not None else c.create_string_buffer(65536)
        try:
            # CancelIoEx cannot cancel an operation that has not been issued.
            # Serialize issuance with cancellation, then release before waiting.
            # Otherwise cancel() can miss the connect between the initial ticket
            # check and ConnectNamedPipe and leave a five-minute pending session.
            with self._pipe_lock:
                if self.ticket.cancelled:raise ValueError("Epic handoff was cancelled")
                if operation=='connect':ok=k.ConnectNamedPipe(pipe,c.byref(ov))
                else:ok=getattr(k,operation)(pipe,buffer,len(payload) if payload is not None else 65536,c.byref(count),c.byref(ov))
                error=c.get_last_error()
            if not ok:
                if operation=='connect' and error==535:return b''
                if error!=997:raise OSError(error,'Epic broker pipe operation failed')
                pending=True
                remaining=max(0,min(300000,(self.ticket.expires-filetime_now())//10000))
                if k.WaitForSingleObject(ov.hEvent,remaining)!=0:raise TimeoutError('Epic session handoff expired')
                if not k.GetOverlappedResult(pipe,c.byref(ov),c.byref(count),False):raise OSError('Epic broker pipe completion failed')
                pending=False
            if payload is not None and count.value!=len(payload):raise OSError('Incomplete Epic broker write')
            return buffer.raw[:count.value]
        finally:
            if pending:
                k.CancelIoEx(pipe,c.byref(ov));k.GetOverlappedResult(pipe,c.byref(ov),c.byref(count),True)
            k.CloseHandle(ov.hEvent)

    def serve(self):
        k=self.kernel;descriptor=None;pipe=None;peer_handle=None
        try:
            descriptor=user_security(k);sa=SECURITY_ATTRIBUTES(c.sizeof(SECURITY_ATTRIBUTES),descriptor,False)
            pipe=k.CreateNamedPipeW(self.pipe_name,3|0x40000000|0x80000,4|2|8,1,65536,65536,0,c.byref(sa))
            if pipe in (None,c.c_void_p(-1).value):raise OSError('Cannot create exclusive local Epic broker')
            with self._pipe_lock:self._pipe=pipe
            self.ready.set();self._io(pipe,'connect')
            pid=w.ULONG()
            if not k.GetNamedPipeClientProcessId(pipe,c.byref(pid)):raise OSError('Cannot identify pipe client')
            peer,peer_handle=process_identity(k,pid.value)
            self._observed.append(peer_handle)
            if (not peer.valid() or peer.executable.resolve()!=self.ticket.executable.resolve()
                    or peer.sha256!=self.ticket.sha256 or not self.ticket.issued<=peer.creation_time<=filetime_now()):
                raise ValueError('Pipe peer is not the new selected game process')
            nonce=self.ticket.nonce
            self._io(pipe,'WriteFile',('KF2VR-CHALLENGE/1\n'+nonce+'\n').encode())
            expected=('KF2VR-HELLO/1\n'+self.ticket.session_id+'\n'+nonce+'\n').encode()
            if self._io(pipe,'ReadFile')!=expected:raise ValueError('Epic session challenge failed')
            self._validate_root()
            payload=f'KF2VR-CONFIG/1\n{self.ticket.session_id}\n{self.root}\n{self.eye_percent}\n'.encode('utf-8')
            self._io(pipe,'WriteFile',payload)
            if self._io(pipe,'ReadFile')!=b'KF2VR-READY/1\n':raise ValueError('Native session setup refused')
            if k.WaitForSingleObject(peer_handle,0)!=258:raise ValueError('Epic game exited during handoff')
            journal=self.ticket.claim(peer,session_id=self.ticket.session_id,nonce=nonce)
            self.on_claim(journal)
            self.owner_handle=peer_handle;peer_handle=None
            self._io(pipe,'WriteFile',b'KF2VR-ACCEPTED/1\n')
        except BaseException as error:
            self.error=error;self.ready.set()
        finally:
            with self._pipe_lock:
                self._pipe=None
                if pipe not in (None,c.c_void_p(-1).value):k.CloseHandle(pipe)
            if descriptor:k.LocalFree(descriptor)

    def cancel(self):
        self.ticket.cancel()
        with self._pipe_lock:
            if self._pipe:self.kernel.CancelIoEx(self._pipe,None)

    def observed_peers_exited(self):
        # Necessary, not sufficient for deployment restoration: after protocol
        # activation an unacknowledged game may exist without reaching the pipe.
        # The launcher must also exclude a live unclaimed selected game process.
        return all(self.kernel.WaitForSingleObject(handle,0)==0 for handle in self._observed)

    def close(self):
        # Call after serve has ended; retained handles prevent PID reuse.
        for handle in self._observed:self.kernel.CloseHandle(handle)
        self._observed.clear();self.owner_handle=None
