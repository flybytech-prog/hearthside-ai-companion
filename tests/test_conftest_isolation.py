"""The autouse fixtures in conftest.py keep every test off the host session."""

import os

from conftest import HOST_SESSION_VARIABLES

pytest_plugins = ["pytester"]


def test_bus_and_display_variables_are_unset_in_every_test():
    for name in HOST_SESSION_VARIABLES:
        assert name not in os.environ, name


def test_runtime_dir_is_the_private_per_test_one(_private_runtime_dir):
    assert os.environ["XDG_RUNTIME_DIR"] == str(_private_runtime_dir)
    assert not os.path.exists(os.path.join(os.environ["XDG_RUNTIME_DIR"], "bus"))


def test_the_fixture_removes_variables_a_test_session_inherited(pytester, monkeypatch):
    # A nested session that starts with every variable set to a host-like value.
    pytester.makeconftest(open(os.path.join(os.path.dirname(__file__), "conftest.py"), encoding="utf-8").read())
    pytester.makepyfile(test_inner="""
import os
from conftest import HOST_SESSION_VARIABLES

def test_inner():
    assert [name for name in HOST_SESSION_VARIABLES if name in os.environ] == []
""")
    for name in HOST_SESSION_VARIABLES:
        monkeypatch.setenv(name, "unix:path=/nonexistent/host-bus")
    result = pytester.runpytest_inprocess("-p", "no:cacheprovider")
    result.assert_outcomes(passed=1)
