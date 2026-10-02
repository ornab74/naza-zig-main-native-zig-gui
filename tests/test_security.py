import hashlib
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import secure_files
import secure_model
import secure_rekey


class Response:
    def __init__(self, chunks=(), headers=None, status=200):
        self.chunks, self.headers, self.status_code = chunks, headers or {}, status
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def iter_raw(self, **kwargs): yield from self.chunks


class HTTP:
    def __init__(self, responses): self.responses, self.urls = iter(responses), []
    def Timeout(self, **kwargs): return kwargs
    def Client(self, **kwargs):
        assert kwargs['follow_redirects'] is False and kwargs['trust_env'] is False
        return self
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def stream(self, method, url, **kwargs):
        self.urls.append(url)
        return next(self.responses)


class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.original = Path.cwd()
        os.chdir(self.root)
        self.payload = b'GGUF bounded pinned test payload'
        self.sha = hashlib.sha256(self.payload).hexdigest()
        self.url = 'https://huggingface.co/repo/model.gguf'
    def tearDown(self):
        os.chdir(self.original)
        self.temp.cleanup()
    def test_private_modes_and_no_clobber(self):
        with patch('os.umask', wraps=os.umask):
            old = os.umask(0o022)
            try: secure_files.write_private(Path('.enc_key'), b'k' * 32, replace=False)
            finally: os.umask(old)
        self.assertEqual(stat.S_IMODE(Path('.enc_key').stat().st_mode), 0o600)
        with self.assertRaises(FileExistsError):
            secure_files.write_private(Path('.enc_key'), b'x', replace=False)
        self.assertEqual(secure_files.read_private(Path('.enc_key')), b'k' * 32)
        os.chmod('.enc_key', 0o644)
        with self.assertRaises(ValueError): secure_files.read_private(Path('.enc_key'))
    def test_symlink_destinations_rejected(self):
        Path('victim').write_bytes(b'keep')
        Path('key').symlink_to('victim')
        with self.assertRaises(ValueError): secure_files.write_private(Path('key'), b'overwrite')
        with self.assertRaises(OSError): secure_files.read_private(Path('key'))
        self.assertEqual(Path('victim').read_bytes(), b'keep')
    def test_download_verified_private_and_existing_preserved(self):
        dest = Path('models/model.gguf')
        http = HTTP([Response([self.payload], {'Content-Length': str(len(self.payload))})])
        self.assertEqual(secure_model.download(http, self.url, dest, self.sha, False), self.sha)
        self.assertEqual(dest.read_bytes(), self.payload)
        self.assertEqual(stat.S_IMODE(dest.stat().st_mode), 0o600)
        with self.assertRaises(FileExistsError): secure_model.download(HTTP([]), self.url, dest, self.sha, False)
        self.assertEqual(dest.read_bytes(), self.payload)
        self.assertEqual(list(dest.parent.iterdir()), [dest])
    def test_hash_failure_cleans_staging(self):
        dest = Path('models/model.gguf')
        with self.assertRaises(ValueError):
            secure_model.download(HTTP([Response([b'bad'])]), self.url, dest, self.sha, False)
        self.assertEqual(list(dest.parent.iterdir()), [])
    def test_declared_and_streamed_size_limits(self):
        with patch.object(secure_model, 'MAX_MODEL_BYTES', 4):
            for response in [Response([b'12345']), Response([], {'Content-Length': '5'})]:
                with self.assertRaises(ValueError):
                    secure_model.download(HTTP([response]), self.url, Path('models/model.gguf'), self.sha, False)
                self.assertEqual(list(Path('models').iterdir()), [])
    def test_redirects_checked_before_request(self):
        http = HTTP([Response(status=302, headers={'Location': 'http://huggingface.co/model'})])
        with self.assertRaises(ValueError): secure_model.download(http, self.url, Path('models/model'), self.sha, False)
        self.assertEqual(http.urls, [self.url])
        http = HTTP([Response(status=302, headers={'Location': '/resolved/model'}), Response([self.payload])])
        secure_model.download(http, self.url, Path('models/model'), self.sha, False)
        self.assertEqual(http.urls[-1], 'https://huggingface.co/resolved/model')
    def test_transfer_deadline_and_truncation(self):
        with patch.object(secure_model.time, 'monotonic', side_effect=[0, 901]):
            with self.assertRaises(TimeoutError):
                secure_model.download(HTTP([Response([self.payload])]), self.url, Path('models/model'), self.sha, False)
        with self.assertRaises(ValueError):
            secure_model.download(HTTP([Response([self.payload], {'Content-Length': '100'})]), self.url, Path('models/model'), self.sha, False)
        self.assertEqual(list(Path('models').iterdir()), [])
    def test_url_boundaries(self):
        for url in ['http://huggingface.co/x', 'https://user@huggingface.co/x', 'https://huggingface.co:444/x', 'https://huggingface.co.evil.example/x', 'https://evil-hf.co/x']:
            self.assertFalse(secure_model.allowed_url(url))
    def test_native_loader_receives_verified_snapshot(self):
        Path('source').write_bytes(self.payload)
        def loader(**kwargs):
            source = Path(kwargs['model_path'])
            self.assertEqual(source.read_bytes(), self.payload)
            self.assertEqual(source.parent.stat().st_mode & 0o077, 0)
            Path('source').write_bytes(b'replaced')
            self.assertEqual(source.read_bytes(), self.payload)
            return source
        snapshot = secure_model.load_verified(loader, Path('source'), self.sha)
        self.assertFalse(snapshot.exists())
        with self.assertRaises(ValueError): secure_model.load_verified(loader, Path('source'), self.sha)
    def test_rekey_rolls_back_failure(self):
        key, artifact = Path('.enc_key'), Path('history.aes')
        secure_files.write_private(key, b'old-key')
        secure_files.write_private(artifact, b'old-cipher')
        original = secure_rekey.write_private
        def fail_once(path, data, **kwargs):
            if path == key and data == b'new-key': raise OSError('simulated commit failure')
            return original(path, data, **kwargs)
        with patch.object(secure_rekey, 'write_private', side_effect=fail_once):
            with self.assertRaises(OSError):
                secure_rekey.rotate(key, [artifact], b'new-key', b'old', b'new', lambda p,k:b'new-cipher', lambda p,k:b'plain')
        self.assertEqual(key.read_bytes(), b'old-key')
        self.assertEqual(artifact.read_bytes(), b'old-cipher')
        self.assertFalse(secure_rekey.JOURNAL.exists())
    def test_rekey_recovers_interruption(self):
        key, artifact = Path('.enc_key'), Path('history.aes')
        secure_rekey.JOURNAL.mkdir(mode=0o700)
        for name, value in [('key', b'old-key'), ('artifact-0', b'old-cipher'), ('ready', b'1')]:
            secure_files.write_private(secure_rekey.JOURNAL/name, value)
        secure_files.write_private(key, b'new-key')
        secure_files.write_private(artifact, b'new-cipher')
        secure_rekey.recover(key, [artifact])
        self.assertEqual(key.read_bytes(), b'old-key')
        self.assertEqual(artifact.read_bytes(), b'old-cipher')

    def test_committed_rotation_survives_cleanup_failure(self):
        key, artifact = Path('.enc_key'), Path('history.aes')
        secure_files.write_private(key, b'old-key')
        secure_files.write_private(artifact, b'old-cipher')
        with patch.object(secure_rekey.shutil, 'rmtree', side_effect=OSError('cleanup failed')):
            secure_rekey.rotate(key, [artifact], b'new-key', b'old', b'new', lambda p,k:b'new-cipher', lambda p,k:b'plain')
        self.assertFalse(secure_rekey.JOURNAL.exists())
        self.assertEqual(key.read_bytes(), b'new-key')
        self.assertEqual(artifact.read_bytes(), b'new-cipher')
        secure_rekey.recover(key, [artifact])
        self.assertEqual(key.read_bytes(), b'new-key')

    def test_committed_journal_never_rolls_back(self):
        key, artifact = Path('.enc_key'), Path('history.aes')
        secure_files.write_private(key, b'new-key')
        secure_files.write_private(artifact, b'new-cipher')
        secure_rekey.JOURNAL.mkdir(mode=0o700)
        for name in ('ready', 'committed'):
            secure_files.write_private(secure_rekey.JOURNAL/name, b'1')
        secure_rekey.recover(key, [artifact])
        self.assertEqual(key.read_bytes(), b'new-key')
        self.assertEqual(artifact.read_bytes(), b'new-cipher')

    def test_history_exception_removes_private_plaintext_for_both_apps(self):
        import ast
        import asyncio
        import time
        import types
        project = Path(__file__).resolve().parents[1]
        for script in ('main.py', 'main_foodwater.py'):
            parsed = ast.parse((project/script).read_text())
            funcs = [node for node in parsed.body if isinstance(node, ast.AsyncFunctionDef)
                     and node.name in ('log_interaction', 'fetch_history')]
            seen = []
            def decrypt(src, dest, key):
                secure_files.write_private(dest, b'private history')
                seen.append(dest)
                self.assertEqual(dest.parent.stat().st_mode & 0o077, 0)
                self.assertEqual(dest.stat().st_mode & 0o077, 0)
            class FailedConnection:
                async def __aenter__(self): raise OSError('simulated SQLite failure')
                async def __aexit__(self, *args): pass
            namespace = {'Path': Path, 'tempfile': tempfile, 'time': time, 'Optional': __import__('typing').Optional,
                         'DB_PATH': Path('history.aes'), 'decrypt_file': decrypt, 'write_private': secure_files.write_private,
                         'aiosqlite': types.SimpleNamespace(connect=lambda p:FailedConnection())}
            exec(compile(ast.Module(body=funcs, type_ignores=[]), script, 'exec'), namespace)
            for call in (namespace['log_interaction']('prompt', 'response', b'key'), namespace['fetch_history'](b'key')):
                with self.assertRaises(OSError): asyncio.run(call)
                self.assertFalse(seen[-1].parent.exists())


if __name__ == '__main__': unittest.main()
