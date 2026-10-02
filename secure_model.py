"""Pinned HTTPS downloads and bounded private model snapshots."""
import hashlib
import hmac
import os
import tempfile
import time
from pathlib import Path
from urllib.parse import urljoin, urlsplit

from secure_files import checked_directory

MAX_MODEL_BYTES = 512 * 1024 * 1024
MAX_REDIRECTS = 5
DOWNLOAD_SECONDS = 15 * 60


def allowed_url(url: str) -> bool:
    try:
        parsed = urlsplit(url)
        host = (parsed.hostname or "").lower()
        return (parsed.scheme == "https" and not parsed.username and not parsed.password
                and parsed.port in (None, 443) and not parsed.fragment
                and any(host == domain or host.endswith("." + domain)
                        for domain in ("huggingface.co", "hf.co")))
    except ValueError:
        return False


def expected_digest(expected: str) -> str:
    expected = (expected or "").lower()
    if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        raise ValueError("A valid pinned SHA-256 is required")
    return expected


def verify_file(path: Path, expected: str) -> str:
    import stat
    expected = expected_digest(expected)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_MODEL_BYTES:
            raise ValueError("Model must be a bounded nonempty regular file")
        digest = hashlib.sha256()
        total = 0
        with os.fdopen(fd, "rb", closefd=False) as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                total += len(chunk)
                if total > MAX_MODEL_BYTES:
                    raise ValueError("Model too large")
                digest.update(chunk)
        actual = digest.hexdigest()
        if not hmac.compare_digest(actual, expected):
            raise ValueError("MODEL SHA256 MISMATCH: model was not accepted")
        return actual
    finally:
        os.close(fd)


def download(httpx, url: str, dest: Path, expected: str, show_progress=True, timeout=None):
    expected = expected_digest(expected)
    if not allowed_url(url):
        raise ValueError("Untrusted model URL")
    dest = Path(dest)
    dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    checked_directory(dest.parent)
    if os.path.lexists(dest):
        raise FileExistsError("Existing model is preserved; verify it or move it explicitly")
    timeout = timeout or httpx.Timeout(connect=30, read=30, write=30, pool=30)
    fd, name = tempfile.mkstemp(prefix=".naza-model-", dir=dest.parent)
    stage = Path(name)
    started = time.monotonic()
    total = 0
    digest = hashlib.sha256()
    try:
        with os.fdopen(fd, "wb") as output, httpx.Client(timeout=timeout, follow_redirects=False, trust_env=False) as client:
            for hop in range(MAX_REDIRECTS + 1):
                if not allowed_url(url):
                    raise ValueError("Untrusted model redirect")
                with client.stream("GET", url, headers={"Accept-Encoding": "identity"}) as response:
                    if response.status_code in (301, 302, 303, 307, 308):
                        if hop == MAX_REDIRECTS or not response.headers.get("Location"):
                            raise ValueError("Too many redirects or missing location")
                        url = urljoin(url, response.headers["Location"])
                        continue
                    if response.status_code != 200:
                        raise ValueError("Model server did not return HTTP 200")
                    if response.headers.get("Content-Encoding", "identity").lower() != "identity":
                        raise ValueError("Encoded model response refused")
                    length = response.headers.get("Content-Length")
                    length = int(length) if length is not None else None
                    if length is not None and not 0 < length <= MAX_MODEL_BYTES:
                        raise ValueError("Invalid or excessive model length")
                    # Yield each transport read; buffering a large chunk could
                    # hide a slowly progressing response past our deadline.
                    for chunk in response.iter_raw():
                        if time.monotonic() - started > DOWNLOAD_SECONDS:
                            raise TimeoutError("Model download deadline exceeded")
                        if total + len(chunk) > MAX_MODEL_BYTES:
                            raise ValueError("Model too large")
                        output.write(chunk)
                        digest.update(chunk)
                        total += len(chunk)
                        if show_progress:
                            print(f"\rDownloading: {total // (1024 * 1024)} MiB", end="", flush=True)
                    if not total or (length is not None and total != length):
                        raise ValueError("Empty or truncated model download")
                    break
            actual = digest.hexdigest()
            if not hmac.compare_digest(actual, expected):
                raise ValueError("MODEL SHA256 MISMATCH: downloaded model was not accepted")
            output.flush()
            os.fsync(output.fileno())
        os.link(stage, dest)  # never replaces an existing destination
        return actual
    finally:
        stage.unlink(missing_ok=True)


def load_verified(loader, path: Path, expected: str):
    # llama.cpp consumes a pathname. Supply a private snapshot whose exact
    # copied bytes have been hashed, so replacement of the source cannot bypass
    # verification. Its mapping remains valid after constructor completion.
    import stat
    expected = expected_digest(expected)
    with tempfile.TemporaryDirectory(prefix="naza-model-") as private:
        snapshot = Path(private) / "model.gguf"
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_MODEL_BYTES:
                raise ValueError("Invalid model file")
            digest = hashlib.sha256()
            total = 0
            with os.fdopen(fd, "rb", closefd=False) as source, snapshot.open("xb") as output:
                os.fchmod(output.fileno(), 0o600)
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    total += len(chunk)
                    if total > MAX_MODEL_BYTES:
                        raise ValueError("Model too large")
                    output.write(chunk)
                    digest.update(chunk)
            if not hmac.compare_digest(digest.hexdigest(), expected):
                raise ValueError("MODEL SHA256 MISMATCH: refusing inference")
            return loader(model_path=str(snapshot), n_ctx=2048, n_threads=4)
        finally:
            os.close(fd)
