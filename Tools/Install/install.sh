#!/bin/bash
# Installs LinearMouse Glide and removes LinearMouse and Mouse Glide.
#
#   bash install.sh              show what will happen, ask, then do it
#   bash install.sh --yes        don't ask
#   bash install.sh --dry-run    only show what would happen
#   bash install.sh --replace-config
#                                also replace an existing LinearMouse Glide config
#
# Everything removed goes to the Trash, so it can be put back. The old
# LinearMouse config (~/.config/linearmouse) is left alone.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="LinearMouse Glide.app"
SOURCE_APP="$HERE/$APP_NAME"
SOURCE_CONFIG="$HERE/linearmouse.json"
TARGET_APP="/Applications/$APP_NAME"
CONFIG_DIR="$HOME/.config/linearmouseglide"
NEW_ID="app.linearmouseglide.LinearMouseGlide"
DEV_ID="app.linearmouseglide.dev.LinearMouseGlide"
OLD_IDS=("com.lujjjh.LinearMouse" "com.tinfine.MouseGlide")
OLD_NAMES=("LinearMouse" "Mouse Glide")

DRY_RUN=0
ASSUME_YES=0
REPLACE_CONFIG=0
for arg in "$@"; do
    case $arg in
    --dry-run) DRY_RUN=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --replace-config) REPLACE_CONFIG=1 ;;
    *)
        echo "usage: bash install.sh [--dry-run] [--yes] [--replace-config]" >&2
        exit 2
        ;;
    esac
done

bold=$'\033[1m'
dim=$'\033[2m'
reset=$'\033[0m'
say() { echo "${bold}==>${reset} $*"; }
note() { echo "    $*"; }
run() {
    if [[ $DRY_RUN == 1 ]]; then
        echo "    ${dim}would run: $*${reset}"
    else
        "$@"
    fi
}

# Moves a path to the Trash, with sudo if it's owned by root (App Store apps).
trash() {
    local path=$1
    [[ -e $path || -L $path ]] || return 0
    local name dest
    name=$(basename "$path")
    dest="$HOME/.Trash/$name"
    [[ -e $dest ]] && dest="$HOME/.Trash/$name $(date +%Y%m%d-%H%M%S)"
    note "Trash: ${path/#$HOME/~}"
    [[ $DRY_RUN == 1 ]] && return 0
    mv "$path" "$dest" 2>/dev/null && return 0
    if [[ $path == "$HOME/Library/Containers/"* ]]; then
        # macOS protects other apps' containers from Terminal, even with sudo;
        # Finder is allowed to move them.
        protected+=("$path")
        note "  macOS protects this folder; Finder will remove it"
        return 0
    fi
    sudo mv "$path" "$dest" 2>/dev/null || note "  couldn't move it; remove it by hand"
}
protected=()

# Every copy of an app with this bundle identifier that Spotlight knows of,
# plus the usual locations in case Spotlight is off.
app_paths_for() {
    local id=$1
    {
        mdfind "kMDItemCFBundleIdentifier == '$id'" 2>/dev/null
        for dir in /Applications "$HOME/Applications"; do
            for app in "$dir"/*.app; do
                [[ -d $app ]] || continue
                [[ $(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null) == "$id" ]] && echo "$app"
            done
        done
    } | grep -E '\.app$' | grep -v "/Library/Developer/" | grep -v "/build/DerivedData/" | grep -v "^$HERE/" | sort -u
}

# --- Checks -----------------------------------------------------------------

if [[ ! -d $SOURCE_APP ]]; then
    echo "Can't find \"$APP_NAME\" next to this script ($HERE)." >&2
    exit 1
fi
if [[ $(uname -m) != arm64 ]]; then
    echo "This build is for Apple silicon Macs; this Mac is $(uname -m)." >&2
    exit 1
fi

# --- Plan -------------------------------------------------------------------

old_apps=()
for id in "${OLD_IDS[@]}"; do
    while IFS= read -r path; do
        [[ -n $path ]] && old_apps+=("$path")
    done < <(app_paths_for "$id")
done

say "LinearMouse Glide installer"
if [[ ${#old_apps[@]} == 0 ]]; then
    note "Remove:  (LinearMouse and Mouse Glide apps aren't installed)"
else
    note "Remove:  ${old_apps[*]}"
fi
note "         plus their settings, caches, login items and Accessibility entries"
note "Install: $TARGET_APP"
if [[ -f "$CONFIG_DIR/linearmouse.json" && $REPLACE_CONFIG == 0 ]]; then
    note "Config:  keep the existing ~/.config/linearmouseglide/linearmouse.json"
elif [[ -f $SOURCE_CONFIG ]]; then
    note "Config:  install the bundled linearmouse.json"
fi
note "Removed items go to the Trash. Your old ~/.config/linearmouse is left alone."
echo

if [[ $DRY_RUN == 0 && $ASSUME_YES == 0 ]]; then
    read -r -p "Continue? [y/N] " answer
    [[ $answer == [yY]* ]] || exit 0
    echo
fi
# App Store apps are owned by root; ask for the password once, up front.
if [[ $DRY_RUN == 0 ]]; then
    for app in ${old_apps[@]+"${old_apps[@]}"}; do
        if [[ ! -w $(dirname "$app") || $(stat -f %Su "$app") == root ]]; then
            say "Your password is needed to remove $(basename "$app")"
            sudo -v || exit 1
            break
        fi
    done
fi

# --- Quit -------------------------------------------------------------------

say "Quitting running copies"
for id in "${OLD_IDS[@]}" "$DEV_ID" "$NEW_ID"; do
    if osascript -e "application id \"$id\" is running" 2>/dev/null | grep -q true; then
        note "Quit $id"
        [[ $DRY_RUN == 1 ]] && continue
        osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1
        for _ in $(seq 20); do
            osascript -e "application id \"$id\" is running" 2>/dev/null | grep -q true || break
            sleep 0.5
        done
    fi
done
# Anything that ignored the quit request.
if [[ $DRY_RUN == 0 ]]; then
    for path in ${old_apps[@]+"${old_apps[@]}"} "$TARGET_APP"; do
        pkill -f "$path/Contents/MacOS/" 2>/dev/null && note "Stopped $(basename "$path")"
    done
fi

# --- Uninstall --------------------------------------------------------------

say "Clearing old privacy permissions"
for id in "${OLD_IDS[@]}" "$NEW_ID"; do
    # Before the apps are removed: tccutil can't resolve an identifier whose
    # app is gone. Clearing our own ID too means the new build gets a fresh
    # entry, not a stale one from an earlier build that silently doesn't work.
    run tccutil reset All "$id" >/dev/null 2>&1 && note "Reset: $id"
done


if command -v brew >/dev/null 2>&1 && brew list --cask linearmouse >/dev/null 2>&1; then
    say "Uninstalling the LinearMouse Homebrew cask"
    run brew uninstall --cask linearmouse
fi

say "Removing old apps"
for app in ${old_apps[@]+"${old_apps[@]}"}; do
    trash "$app"
done

say "Removing leftover settings and data"
for id in "${OLD_IDS[@]}"; do
    # Through cfprefsd, so a cached copy doesn't write the file back.
    if defaults read "$id" >/dev/null 2>&1; then
        note "Delete preferences: $id"
        run defaults delete "$id"
    fi
    for path in \
        "$HOME/Library/Preferences/$id.plist" \
        "$HOME/Library/Caches/$id" \
        "$HOME/Library/HTTPStorages/$id" \
        "$HOME/Library/HTTPStorages/$id.binarycookies" \
        "$HOME/Library/WebKit/$id" \
        "$HOME/Library/Saved Application State/$id.savedState" \
        "$HOME/Library/Application Scripts/$id" \
        "$HOME/Library/Containers/$id" \
        "$HOME/Library/LaunchAgents/$id.plist" \
        "$HOME/Library/Application Support/$id"; do
        trash "$path"
    done
done
trash "$HOME/Library/Application Support/LinearMouse"
for agent in "$HOME"/Library/LaunchAgents/*; do
    [[ -f $agent ]] || continue
    case $(basename "$agent") in
    *lujjjh* | *inear[Mm]ouse* | *tinfine* | *[Mm]ouse[Gg]lide*)
        run launchctl bootout "gui/$(id -u)" "$agent" 2>/dev/null
        trash "$agent"
        ;;
    esac
done

say "Removing old login items"
for name in "${OLD_NAMES[@]}"; do
    if osascript -e "tell application \"System Events\" to exists login item \"$name\"" 2>/dev/null | grep -q true; then
        note "Login item: $name"
        run osascript -e "tell application \"System Events\" to delete login item \"$name\"" >/dev/null
    fi
done
note "Login items the apps registered themselves disappear from System Settings"
note "once the apps are gone (sometimes only after a restart)."

# --- Install ----------------------------------------------------------------

say "Installing $APP_NAME"
trash "$TARGET_APP"
if [[ $DRY_RUN == 1 ]]; then
    note "${dim}would copy it to $TARGET_APP${reset}"
else
    ditto "$SOURCE_APP" "$TARGET_APP" 2>/dev/null || sudo ditto "$SOURCE_APP" "$TARGET_APP" || exit 1
fi
note "Unquarantine"
run xattr -dr com.apple.quarantine "$TARGET_APP"
run codesign --verify --deep --strict "$TARGET_APP" || {
    echo "The installed app's signature doesn't verify." >&2
    exit 1
}

if [[ -f $SOURCE_CONFIG ]]; then
    if [[ -f "$CONFIG_DIR/linearmouse.json" && $REPLACE_CONFIG == 0 ]]; then
        note "Keeping the existing config"
    else
        note "Config: ~/.config/linearmouseglide/linearmouse.json"
        trash "$CONFIG_DIR/linearmouse.json"
        run mkdir -p "$CONFIG_DIR"
        run cp "$SOURCE_CONFIG" "$CONFIG_DIR/linearmouse.json"
    fi
fi

if [[ ${#protected[@]} -gt 0 ]]; then
    say "Removing protected folders with Finder"
    for path in ${protected[@]+"${protected[@]}"}; do
        if osascript -e "tell application \"Finder\" to delete (POSIX file \"$path\" as alias)" >/dev/null 2>&1; then
            note "Trash: ${path/#$HOME/~}"
        else
            note "Drag ${path/#$HOME/~} to the Trash (shown in Finder)"
            open -R "$path"
        fi
    done
fi

# --- Launch -----------------------------------------------------------------

say "Opening LinearMouse Glide and the Accessibility settings"
run open "$TARGET_APP"
sleep 1
run open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

echo
if [[ $DRY_RUN == 1 ]]; then
    say "Dry run: nothing was changed."
else
    say "Done. Two things left:"
    note "1. In Accessibility, turn on LinearMouse Glide (add it with + if it isn't listed)."
    note "2. In LinearMouse Glide's Glide pane, turn on Launch at Login."
fi
