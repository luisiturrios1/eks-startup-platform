"""Cached dependencies must retain integrity checks and bounded transient retries."""
import hashlib
import importlib.util
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('prepare_assets', ROOT/'scripts/prepare_assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


@pytest.fixture
def store(tmp_path, monkeypatch):
    monkeypatch.setattr(assets, 'ARTIFACTS', tmp_path)
    return tmp_path


def test_verified_cache_never_downloads(store):
    value = b'verified'
    (store/'asset').write_bytes(value)
    assets.prepare_asset('asset', hashlib.sha256(value).hexdigest(), None,
                         download=lambda _: pytest.fail('Verified asset should be reused'))


def test_bad_cache_fails_closed(store):
    (store/'asset').write_bytes(b'tampered')
    with pytest.raises(ValueError, match='checksum mismatch'):
        assets.prepare_asset('asset', hashlib.sha256(b'expected').hexdigest(), None,
                             download=lambda _: pytest.fail('Invalid cache must not be silently replaced'))


def test_transient_download_retry_is_verified(store):
    attempts = []
    def download(path):
        attempts.append(path)
        if len(attempts) == 1:
            raise OSError('429')
        path.write_bytes(b'expected')
    assets.prepare_asset('asset', hashlib.sha256(b'expected').hexdigest(), None,
                         download=download, sleep=lambda _: None)
    assert len(attempts) == 2
    assert (store/'asset').read_bytes() == b'expected'


def test_wrong_download_is_never_installed_or_retried(store):
    attempts = []
    def download(path):
        attempts.append(path)
        path.write_bytes(b'tampered')
    with pytest.raises(ValueError, match='checksum mismatch'):
        assets.prepare_asset('asset', hashlib.sha256(b'expected').hexdigest(), None,
                             download=download, sleep=lambda _: None)
    assert len(attempts) == 1
    assert not (store/'asset').exists()
