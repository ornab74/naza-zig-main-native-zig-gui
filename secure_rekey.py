"""Recoverable key rotation; the journal retains only encrypted originals."""
import os
import shutil
import stat
import fcntl
import secrets
from contextlib import contextmanager
from pathlib import Path

from secure_files import checked_directory, read_private, write_private

JOURNAL = Path(".naza-rekey-pending")


@contextmanager
def _lock():
    checked_directory(Path("."))
    fd = os.open(".naza-rekey.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Unsafe rekey lock")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def recover(key_path: Path, artifacts) -> None:
    with _lock():
        _recover(key_path, artifacts)


def _retire_journal() -> None:
    # Remove the recovery name atomically before recursive disposal. A crash
    # during cleanup can never turn a complete journal into a partial rollback.
    disposable = JOURNAL.with_name(".naza-rekey-discard-" + secrets.token_hex(16))
    try:
        os.rename(JOURNAL, disposable)
        parent_fd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
        shutil.rmtree(disposable)
    except OSError:
        # A private leftover is recoverable and must not change the commit
        # result or leave the caller using a stale in-memory key.
        pass


def _recover(key_path: Path, artifacts, *, force_rollback=False) -> None:
    if not os.path.lexists(JOURNAL):
        return
    checked_directory(JOURNAL)
    if JOURNAL.stat().st_mode & 0o077:
        raise ValueError("Rekey recovery journal must have mode 0700")
    # A ready marker is synced only after every original has a durable backup.
    # Without it, the rotation never started publishing.
    committed = (JOURNAL / "committed").exists() and not force_rollback
    if committed:
        read_private(JOURNAL / "committed")
    if (JOURNAL / "ready").exists() and not committed:
        read_private(JOURNAL / "ready")
        originals = [(key_path, JOURNAL / "key")]
        originals.extend((path, JOURNAL / f"artifact-{i}") for i, path in enumerate(artifacts)
                         if (JOURNAL / f"artifact-{i}").exists())
        for destination, backup in originals:
            write_private(destination, read_private(backup))
    _retire_journal()


def rotate(key_path: Path, artifacts, payload: bytes, old_key: bytes, new_key: bytes, encrypt, decrypt) -> None:
    with _lock():
        _rotate(key_path, artifacts, payload, old_key, new_key, encrypt, decrypt)


def _rotate(key_path: Path, artifacts, payload: bytes, old_key: bytes, new_key: bytes, encrypt, decrypt) -> None:
    checked_directory(key_path.parent)
    os.mkdir(JOURNAL, 0o700)  # exclusive lock and crash-recovery journal
    ready = False
    try:
        write_private(JOURNAL / "key", read_private(key_path), replace=False)
        active = []
        for i, path in enumerate(artifacts):
            if not os.path.lexists(path):
                continue
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_size > 512 * 1024 * 1024 + 28:
                    raise ValueError("Invalid encrypted artifact")
                with os.fdopen(fd, "rb", closefd=False) as source:
                    original = source.read(512 * 1024 * 1024 + 29)
                if len(original) > 512 * 1024 * 1024 + 28:
                    raise ValueError("Encrypted artifact too large")
            finally:
                os.close(fd)
            write_private(JOURNAL / f"artifact-{i}", original, replace=False)
            write_private(JOURNAL / f"new-{i}", encrypt(decrypt(original, old_key), new_key), replace=False)
            active.append((i, path))
        write_private(JOURNAL / "ready", b"1", replace=False)
        parent_fd = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent_fd)
        finally:
            os.close(parent_fd)
        ready = True
        for i, path in active:
            write_private(path, read_private(JOURNAL / f"new-{i}"))
        write_private(key_path, payload)  # commit key only after ciphertext
        write_private(JOURNAL / "committed", b"1", replace=False)
    except BaseException:
        if ready:
            _recover(key_path, artifacts, force_rollback=True)
        else:
            _retire_journal()
        raise
    else:
        _retire_journal()
