import os
import sys
from pathlib import Path

import pytest

# Headless Qt for any test that touches PySide6.
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

SRC = Path(__file__).resolve().parent.parent / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def fixture(name: str) -> Path:
    return FIXTURES / name


@pytest.fixture(autouse=True)
def _private_runtime_dir(tmp_path_factory, monkeypatch):
    """Keep credential lock files out of the real XDG_RUNTIME_DIR."""
    runtime = tmp_path_factory.mktemp("runtime")
    runtime.chmod(0o700)
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(runtime))
    return runtime
