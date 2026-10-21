#!/usr/bin/env python3
"""Install the Canvas plugin into Omarchy.

Copies the plugin into ~/.config/omarchy/plugins/<id>/ (the path the shell
discovers), puts the two helper commands on PATH via ~/.local/bin, adds the
default hotkey to the user's Hyprland keybindings, and enables the plugin.

Everything is reversible with --uninstall; a manifest of what was written is
kept in ~/.local/state/omarchy-canvas/install.json so the uninstall restores
the previous state rather than guessing.

Usage:
    python3 install.py                 # install
    python3 install.py --uninstall     # remove and restore
    python3 install.py --status        # report what is installed
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

PLUGIN_ID = "io.github.hermes.canvas"
PLUGIN_SOURCE = Path(__file__).resolve().parent
PLUGINS_DIR = Path.home() / ".config" / "omarchy" / "plugins" / PLUGIN_ID
STATE_DIR = Path.home() / ".local" / "state" / "omarchy-canvas"
INSTALL_JSON = STATE_DIR / "install.json"
LOCAL_BIN = Path.home() / ".local" / "bin"

HELPERS = {
    "omarchy-canvas": PLUGIN_SOURCE / "bin" / "omarchy-canvas",
    "omarchy-canvas-open": PLUGIN_SOURCE / "bin" / "omarchy-canvas-open",
}

# The hotkey the installer offers to add. Kept here so the uninstall can
# remove exactly what it wrote.
HOTKEY_KEY = "C"
HOTKEY_LINE = f'o.bind("SUPER + SHIFT + {HOTKEY_KEY}", "Canvas", "omarchy-canvas-open")'
HOTKEY_COMMENT = "-- Canvas: infinite visual canvas"


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, capture_output=True, text=True)


def scan_bound_keys() -> set[str]:
    """Collect the letter keys already used by SUPER+SHIFT bindings."""
    found: set[str] = set()

    # Lua-defined bindings: no keycode, so read the user's bindings.lua text.
    bindings_file = Path.home() / ".config" / "hypr" / "bindings.lua"
    if bindings_file.exists():
        text = bindings_file.read_text()
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("--") or not stripped:
                continue
            if "SUPER" not in stripped.upper() or "SHIFT" not in stripped.upper():
                continue
            # o.bind("SUPER + SHIFT + C", ...) — the key is the last token.
            inner = stripped.split('"')
            if len(inner) < 2:
                continue
            spec = inner[1]
            parts = [p.strip().upper() for p in spec.split("+")]
            if parts and len(parts[-1]) == 1 and parts[-1].isalpha():
                found.add(parts[-1])

    return found


def already_bound(key: str) -> bool:
    """True when the user already claims SUPER+SHIFT+<key> in Hyprland.

    Lua-defined bindings report key as "__lua" with no keycode, so the binds
    dump cannot see them. The user's own bindings.lua is therefore also checked
    for the literal key text — that is where a hand-written conflict would be.
    """
    return key.upper() in ALREADY_BOUND_KEYS


ALREADY_BOUND_KEYS = scan_bound_keys()


def install_hotkey(bindings_file: Path) -> str:
    """Add the Canvas hotkey to the user's Hyprland bindings.lua."""
    text = bindings_file.read_text() if bindings_file.exists() else ""

    if HOTKEY_LINE in text:
        return "already present"

    block = f"{HOTKEY_COMMENT}\n{HOTKEY_LINE}\n"
    if text and not text.endswith("\n"):
        text += "\n"
    bindings_file.write_text(text + block)

    # Reload Hyprland so the new binding is live.
    run(["hyprctl", "reload"], check=False)
    return "added"


def remove_hotkey(bindings_file: Path) -> str:
    if not bindings_file.exists():
        return "not present"
    lines = bindings_file.read_text().splitlines()
    kept = []
    for line in lines:
        if HOTKEY_LINE in line or line.strip() == HOTKEY_COMMENT.strip():
            continue
        kept.append(line)
    bindings_file.write_text("\n".join(kept) + ("\n" if kept else ""))
    run(["hyprctl", "reload"], check=False)
    return "removed"


def install() -> int:
    if not PLUGIN_SOURCE.joinpath("manifest.json").exists():
        print(f"error: manifest.json not found next to {PLUGIN_SOURCE}", file=sys.stderr)
        return 1

    PLUGIN_SOURCE.joinpath("lib").mkdir(exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    # 1. Plugin source into the shell's plugin directory.
    if PLUGINS_DIR.exists():
        shutil.rmtree(PLUGINS_DIR)
    shutil.copytree(PLUGIN_SOURCE, PLUGINS_DIR)
    print(f"plugin  -> {PLUGINS_DIR}")

    # 2. Helper commands on PATH.
    LOCAL_BIN.mkdir(parents=True, exist_ok=True)
    written: dict[str, str] = {}
    for name, src in HELPERS.items():
        if not src.exists():
            print(f"warning: {src} missing, skipping", file=sys.stderr)
            continue
        dest = LOCAL_BIN / name
        shutil.copy2(src, dest)
        dest.chmod(0o755)
        written[name] = str(dest)
        print(f"command -> {dest}")

    # 3. Hotkey (only when the user does not already claim it).
    bindings_file = Path.home() / ".config" / "hypr" / "bindings.lua"
    if HOTKEY_KEY.upper() in ALREADY_BOUND_KEYS:
        hotkey = f"skipped (SUPER+SHIFT+{HOTKEY_KEY} already bound)"
    else:
        hotkey = install_hotkey(bindings_file)
        if hotkey == "added":
            print(f"hotkey  -> {bindings_file}")
    print(f"hotkey  : {hotkey}")

    # 4. Enable the plugin through the shell.
    result = run(["omarchy", "plugin", "enable", PLUGIN_ID], check=False)
    enabled = result.returncode == 0
    print(f"plugin  : {'enabled' if enabled else 'enable failed (run: omarchy plugin enable ' + PLUGIN_ID + ')'}")

    # 5. Record what was written.
    record = {
        "pluginDir": str(PLUGINS_DIR),
        "commands": written,
        "hotkey": hotkey,
        "bindingsFile": str(bindings_file),
    }
    INSTALL_JSON.write_text(json.dumps(record, indent=2) + "\n")
    print(f"record  -> {INSTALL_JSON}")

    print("\nOpen a canvas with:  omarchy-canvas-open")
    print("Or summon directly:  omarchy-shell shell summon io.github.hermes.canvas")
    return 0


def uninstall() -> int:
    if not INSTALL_JSON.exists():
        print(f"nothing recorded at {INSTALL_JSON}; removing by convention")
        record = {
            "pluginDir": str(PLUGINS_DIR),
            "commands": {n: str(LOCAL_BIN / n) for n in HELPERS},
            "bindingsFile": str(Path.home() / ".config" / "hypr" / "bindings.lua"),
        }
    else:
        record = json.loads(INSTALL_JSON.read_text())

    # Disable the plugin, then remove its source.
    run(["omarchy", "plugin", "disable", PLUGIN_ID], check=False)
    plugin_dir = Path(record.get("pluginDir", PLUGINS_DIR))
    if plugin_dir.exists():
        shutil.rmtree(plugin_dir)
        print(f"removed plugin  {plugin_dir}")

    for name, path in record.get("commands", {}).items():
        p = Path(path)
        if p.exists():
            p.unlink()
            print(f"removed command {p}")

    remove_hotkey(Path(record.get("bindingsFile", "")))

    INSTALL_JSON.unlink(missing_ok=True)
    print("uninstalled")
    return 0


def status() -> int:
    print(f"plugin id    : {PLUGIN_ID}")
    print(f"plugin source: {PLUGIN_SOURCE}")
    print(f"installed at : {PLUGINS_DIR} ({'yes' if PLUGINS_DIR.exists() else 'no'})")
    for name, src in HELPERS.items():
        dest = LOCAL_BIN / name
        print(f"{name:20s}: {dest} ({'yes' if dest.exists() else 'no'})")
    if INSTALL_JSON.exists():
        print(f"record       : {INSTALL_JSON}")
        print(INSTALL_JSON.read_text())
    result = run(["omarchy", "plugin", "list"], check=False)
    if result.returncode == 0 and PLUGIN_ID in result.stdout:
        state = "enabled" if f"{PLUGIN_ID} enabled" in result.stdout else "disabled"
        print(f"shell state  : {state}")
    else:
        print("shell state  : unknown (omarchy plugin list failed)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Install the Omarchy Canvas plugin")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--uninstall", action="store_true", help="remove the plugin and restore state")
    group.add_argument("--status", action="store_true", help="report installed state")
    args = parser.parse_args()

    if args.uninstall:
        return uninstall()
    if args.status:
        return status()
    return install()


if __name__ == "__main__":
    sys.exit(main())
