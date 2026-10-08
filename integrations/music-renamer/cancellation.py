"""Windows named mutexes: termination and mutation share an atomic boundary.

No media mutation/recovery lives here. A missing optional gate means standalone
contract use; production supplies both a job gate and per-invocation gate.
"""
import ctypes
from pathlib import Path


class Gate:
    def __init__(self, name):
        self.handle = None
        self.owned = False
        if name:
            self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            self.kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
            self.kernel.CreateMutexW.restype = ctypes.c_void_p
            self.kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            self.kernel.ReleaseMutex.argtypes = [ctypes.c_void_p]
            self.kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            self.handle = self.kernel.CreateMutexW(None, False, name)
            if not self.handle:
                raise ctypes.WinError(ctypes.get_last_error())

    def __enter__(self):
        if not self.acquire(0xffffffff):
            raise RuntimeError('Could not acquire mutation gate')
        return self

    def acquire(self, milliseconds=0):
        if self.handle:
            result = self.kernel.WaitForSingleObject(self.handle, milliseconds)
            if result == 0x102:
                return False
            if result not in (0, 0x80):  # acquired or abandoned by crashed owner
                raise ctypes.WinError(ctypes.get_last_error())
            self.owned = True
        return True

    def __exit__(self, *_):
        if self.handle:
            if self.owned:
                self.kernel.ReleaseMutex(self.handle)
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def requested(*paths):
    return any(path and Path(path).is_file() for path in paths)
