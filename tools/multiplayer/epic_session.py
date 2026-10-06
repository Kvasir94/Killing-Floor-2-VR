"""Fail-closed ownership state for an Epic-managed game launch.

The transport must identify the peer using GetNamedPipeClientProcessId and a
held process handle, then supply ProcessIdentity. Never construct it from a
PID/path claimed in JSON, a window title, or a launcher's returned PID. This
module grants no ownership merely because an executable appeared after launch.
No Epic account token or game command line is needed or accepted.
"""
from dataclasses import dataclass, field
import hmac
from pathlib import Path
import re
import secrets
import time
import uuid

WINDOWS_EPOCH_TICKS = 116444736000000000


def filetime_now():
    return WINDOWS_EPOCH_TICKS + time.time_ns() // 100


def path_key(path):
    return str(Path(path).resolve()).casefold()


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    creation_time: int
    executable: Path
    sha256: str

    def valid(self):
        return (type(self.pid) is int and self.pid > 0 and
                type(self.creation_time) is int and self.creation_time > 0 and
                self.executable.is_absolute() and
                bool(re.fullmatch(r'[0-9A-F]{64}', self.sha256)))


@dataclass
class PendingEpicLaunch:
    executable: Path
    sha256: str
    issued: int
    expires: int
    session_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    nonce: str = field(default_factory=lambda: secrets.token_hex(32), repr=False)
    owner: ProcessIdentity | None = field(default=None, init=False)
    cancelled: bool = field(default=False, init=False)

    def __post_init__(self):
        if (not self.executable.is_absolute() or not re.fullmatch(r'[0-9A-F]{64}', self.sha256)
                or type(self.issued) is not int or type(self.expires) is not int
                or not 0 < self.issued < self.expires <= self.issued + 300 * 10_000_000):
            raise ValueError('Invalid bounded Epic launch ticket')
        if str(uuid.UUID(self.session_id)) != self.session_id or not re.fullmatch(r'[0-9a-f]{64}', self.nonce):
            raise ValueError('Invalid Epic session binding')

    @classmethod
    def create(cls, executable, sha256, *, timeout_seconds=120):
        if type(timeout_seconds) is not int or not 1 <= timeout_seconds <= 300:
            raise ValueError('Epic launch timeout must be 1..300 seconds')
        now=filetime_now()
        return cls(Path(executable).resolve(), sha256.upper(), now, now+timeout_seconds*10_000_000)

    def claim(self, peer: ProcessIdentity, *, session_id, nonce, now=None):
        """Accept exactly one OS-identified peer with this ephemeral binding.

        Only call after the local pipe transport authenticated its OS peer.
        The adapter must already have passed its exact executable hash gate.
        A candidate found by process enumeration is insufficient proof.
        """
        now=filetime_now() if now is None else now
        if self.cancelled or self.owner is not None:
            raise ValueError('Epic session is no longer awaiting a game')
        if type(now) is not int or not self.issued <= now <= self.expires:
            raise ValueError('Epic launch ticket expired or clock moved backwards')
        if (not isinstance(session_id, str) or not isinstance(nonce, str)
                or not hmac.compare_digest(session_id, self.session_id)
                or not hmac.compare_digest(nonce, self.nonce)):
            raise ValueError('Epic session binding mismatch')
        if (not peer.valid() or not self.issued <= peer.creation_time <= now
                or path_key(peer.executable) != path_key(self.executable)
                or peer.sha256 != self.sha256):
            raise ValueError('Epic peer does not match the new selected game process')
        self.owner=peer
        self.nonce=''  # Consumed; never put a live nonce in the recovery journal.
        return self.recovery_identity()

    def cancel(self):
        self.cancelled=True
        self.nonce=''

    def recovery_identity(self):
        if self.owner is None:
            return None
        return dict(session_id=self.session_id, pid=self.owner.pid,
                    creation_time=self.owner.creation_time,
                    executable=str(self.owner.executable), sha256=self.owner.sha256)

    def owns(self, current: ProcessIdentity):
        """Recheck the held/reopened OS process before recovery or termination."""
        return bool(self.owner and current.valid()
                    and current.pid == self.owner.pid
                    and current.creation_time == self.owner.creation_time
                    and path_key(current.executable) == path_key(self.owner.executable)
                    and current.sha256 == self.owner.sha256)
