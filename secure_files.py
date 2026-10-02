"""Private local storage primitives shared by the Python reference apps."""
import os
import stat
import tempfile
from pathlib import Path


def checked_directory(path: Path) -> None:
    # Inspect every component: symlinked or writable ancestors undermine the
    # protection of exclusive staging names and pathname-based native loading.
    absolute = Path(os.path.abspath(path))
    for component in (absolute, *absolute.parents):
        info = component.lstat()
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"Not a real directory: {component}")
        trusted_sticky = component != absolute and info.st_mode & stat.S_ISVTX
        if info.st_mode & 0o022 and not trusted_sticky:
            raise ValueError(f"Directory is writable by other users: {component}")
    if absolute.stat().st_uid != os.getuid():
        raise ValueError(f"Directory is not owned by you: {absolute}")


def read_bounded(path: Path, max_bytes: int = 512 * 1024 * 1024 + 28, *, private: bool = False) -> bytes:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > max_bytes:
            raise ValueError(f"File must be bounded and regular: {path}")
        if private and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError(f"Secret must be an owned regular mode-0600 file: {path}")
        with os.fdopen(fd, "rb", closefd=False) as source:
            data = source.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise ValueError(f"File grew beyond its size limit: {path}")
        return data
    finally:
        os.close(fd)


def read_private(path: Path, max_bytes: int = 512 * 1024 * 1024 + 28) -> bytes:
    return read_bounded(path, max_bytes, private=True)


def write_private(path: Path, data: bytes, *, replace: bool = True) -> None:
    path = Path(path)
    checked_directory(path.parent)
    if path.is_symlink():
        raise ValueError(f"Refusing symlink destination: {path}")
    fd, name = tempfile.mkstemp(prefix=".naza-write-", dir=path.parent)
    stage = Path(name)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        if replace:
            os.replace(stage, path)
        else:
            os.link(stage, path)  # atomic no-clobber creation
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        stage.unlink(missing_ok=True)
