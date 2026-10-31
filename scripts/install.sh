#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_directory=$(CDPATH= cd -- "$script_directory/.." && pwd)
restart_plasma=false

if [ "${1:-}" = "--restart-plasma" ]; then
    restart_plasma=true
elif [ "$#" -gt 0 ]; then
    echo "Usage: $0 [--restart-plasma]" >&2
    exit 2
fi

for executable in python3 kpackagetool6; do
    if ! command -v "$executable" >/dev/null 2>&1; then
        echo "Required command not found: $executable" >&2
        exit 1
    fi
done

build_directory="$project_directory/build"
if [ -d "$build_directory" ]; then
    rm -rf -- "$build_directory"
fi

# Migrate from AI Usage: remove the old helper first, so the old and new
# helpers never refresh the same OAuth tokens under different lock directories.
migrated=false
if python3 -m pip show ai-usage-kde >/dev/null 2>&1; then
    if ! python3 -m pip uninstall -y --break-system-packages ai-usage-kde; then
        echo "Could not remove the old ai-usage-kde helper (it may be installed system-wide). Remove it manually, then run this script again." >&2
        exit 1
    fi
    migrated=true
fi

if kpackagetool6 -t Plasma/Applet -s com.bgn.aiusage >/dev/null 2>&1; then
    if ! kpackagetool6 -t Plasma/Applet -r com.bgn.aiusage; then
        echo "Could not remove the old com.bgn.aiusage widget (it may be installed system-wide). Remove it manually, then run this script again." >&2
        exit 1
    fi
    migrated=true
fi

# Delete only the files AI Usage is known to have written, never a symlink.
old_cache="${XDG_CACHE_HOME:-${HOME}/.cache}/ai-usage-kde"
if [ -d "$old_cache" ] && [ ! -L "$old_cache" ]; then
    rm -f -- "$old_cache/antigravity-auth.json" "$old_cache/retry-state.json"
    rmdir -- "$old_cache" 2>/dev/null || true
fi
# Old lock directories hold only empty lock files and are cleared at logout.

python3 -m pip install \
    --user \
    --upgrade \
    --force-reinstall \
    --break-system-packages \
    "$project_directory"

if kpackagetool6 -t Plasma/Applet -s io.github.flybytechprog.hearthside >/dev/null 2>&1; then
    kpackagetool6 -t Plasma/Applet -u "$project_directory/plasmoid"
else
    kpackagetool6 -t Plasma/Applet -i "$project_directory/plasmoid"
fi

if [ "$restart_plasma" = true ]; then
    if systemctl --user is-active plasma-plasmashell.service >/dev/null 2>&1; then
        systemctl --user restart plasma-plasmashell.service
    else
        kquitapp6 plasmashell >/dev/null 2>&1 || true
        kstart plasmashell >/dev/null 2>&1
    fi
fi

version=$(python3 -m hearthside --version)
echo "Hearthside ${version} installed."
if [ "$migrated" = true ]; then
    echo "Remove the old AI Usage widget from your panel if it is still there, then add Hearthside via Add Widgets…"
fi
