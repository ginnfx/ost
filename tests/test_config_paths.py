"""Per-OS data-home resolution in ost_tracker.config."""

from pathlib import Path

from ost_tracker import config


def test_override_wins(monkeypatch, tmp_path):
    monkeypatch.setenv("OST_TRACKER_HOME", str(tmp_path))
    assert config.app_support_dir() == tmp_path
    assert tmp_path.exists()


def test_darwin_default(monkeypatch):
    monkeypatch.setattr(config.sys, "platform", "darwin")
    d = config._default_data_home()
    assert d.name == "ost-tracker"
    assert d == Path.home() / "Library" / "Application Support" / "ost-tracker"


def test_windows_uses_appdata(monkeypatch):
    monkeypatch.setattr(config.sys, "platform", "win32")
    monkeypatch.setenv("APPDATA", "C:\\Users\\test\\AppData\\Roaming")
    assert config._default_data_home() == Path("C:\\Users\\test\\AppData\\Roaming") / "ost-tracker"


def test_windows_fallback_without_appdata(monkeypatch):
    monkeypatch.setattr(config.sys, "platform", "win32")
    monkeypatch.delenv("APPDATA", raising=False)
    d = config._default_data_home()
    assert d.name == "ost-tracker"
    assert "AppData" in d.parts and "Roaming" in d.parts


def test_linux_uses_xdg(monkeypatch):
    monkeypatch.setattr(config.sys, "platform", "linux")
    monkeypatch.setenv("XDG_DATA_HOME", "/home/test/.local/share")
    assert config._default_data_home() == Path("/home/test/.local/share/ost-tracker")


def test_linux_fallback_without_xdg(monkeypatch):
    monkeypatch.setattr(config.sys, "platform", "linux")
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    d = config._default_data_home()
    assert d.name == "ost-tracker"
    assert d == Path.home() / ".local" / "share" / "ost-tracker"
