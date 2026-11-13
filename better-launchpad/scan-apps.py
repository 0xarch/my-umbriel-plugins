#!/usr/bin/env python3
"""Collect XDG desktop entries for the Better Launchpad plugin.

Prints one JSON array on stdout. Parsing happens here rather than in Luau so a
large catalog never competes with the plugin's 25 ms callback budget.
"""

import json
import os
import re
import sys

LOCALIZED_KEY = re.compile(r"^([^\[]+)\[([^\]]+)\]$")


def unescape(value):
    out = []
    index = 0
    length = len(value)
    while index < length:
        char = value[index]
        if char == "\\" and index + 1 < length:
            nxt = value[index + 1]
            out.append({
                "s": " ",
                "n": "\n",
                "t": "\t",
                "r": "\r",
                "\\": "\\",
            }.get(nxt, nxt))
            index += 2
        else:
            out.append(char)
            index += 1
    return "".join(out)


def as_bool(value):
    return value is not None and value.strip().lower() in ("true", "1", "yes")


def split_list(value):
    if not value:
        return []
    return [part.strip() for part in value.split(";") if part.strip()]


def parse_desktop(text):
    in_main = False
    seen_main = False
    fields = {}
    localized_names = []

    for raw in text.splitlines():
        line = raw.rstrip("\r")
        if line.startswith("[") and line.endswith("]"):
            in_main = line == "[Desktop Entry]"
            seen_main = seen_main or in_main
            continue
        if not in_main or not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        localized = LOCALIZED_KEY.match(key)
        if localized is not None:
            if localized.group(1) == "Name":
                localized_names.append(unescape(value))
        else:
            fields[key] = unescape(value)

    return (seen_main, fields, localized_names)


def detect_origin(path, user_root):
    normalized = path.replace("\\", "/")
    if "/flatpak/" in normalized and "/exports/share/applications/" in normalized:
        return "Flatpak"
    if "/snap/" in normalized or "/snapd/desktop/applications/" in normalized:
        return "Snap"
    if "/nix/store/" in normalized:
        return "Nix"
    if normalized.startswith(user_root + "/applications/"):
        return "User"
    return "System"


def search_roots():
    seen = set()
    roots = []

    def add(base):
        if not base:
            return
        path = os.path.normpath(os.path.join(base, "applications"))
        if path not in seen:
            seen.add(path)
            roots.append(path)

    home = os.environ.get("HOME", "")
    data_home = os.environ.get("XDG_DATA_HOME") or (os.path.join(home, ".local/share") if home else "")
    add(data_home)
    for entry in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":"):
        add(entry)
    if home:
        add(os.path.join(home, ".local/share/flatpak/exports/share"))
    add("/var/lib/flatpak/exports/share")
    add("/var/lib/snapd/desktop")
    return roots


def walk_files(root):
    if not os.path.isdir(root):
        return
    root_depth = root.rstrip("/").count("/")
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames[:] = sorted(name for name in dirnames if not name.startswith("."))
        if dirpath.rstrip("/").count("/") - root_depth >= 3:
            dirnames[:] = []
        for name in sorted(filenames):
            if name.endswith(".desktop"):
                yield os.path.join(dirpath, name)


def main():
    home = os.environ.get("HOME", "")
    data_home = os.environ.get("XDG_DATA_HOME") or (os.path.join(home, ".local/share") if home else "")
    user_root = os.path.normpath(data_home) if data_home else ""
    current_desktop = os.environ.get("XDG_CURRENT_DESKTOP", "").upper()

    roots = [os.path.normpath(path) for path in sys.argv[1:]] if len(sys.argv) > 1 else search_roots()

    seen = set()
    entries = []
    for root in roots:
        for path in walk_files(root):
            entry_id = os.path.basename(path)[: -len(".desktop")]
            if entry_id in seen:
                continue
            seen.add(entry_id)
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    text = handle.read()
            except OSError:
                continue

            seen_main, fields, localized_names = parse_desktop(text)
            if not seen_main or fields.get("Type") != "Application":
                continue
            if as_bool(fields.get("NoDisplay")) or as_bool(fields.get("Hidden")):
                continue
            name = (fields.get("Name") or "").strip()
            if not name:
                continue

            only_show_in = split_list(fields.get("OnlyShowIn"))
            if only_show_in and not any(token.upper() in current_desktop for token in only_show_in):
                continue
            not_show_in = split_list(fields.get("NotShowIn"))
            if any(token.upper() in current_desktop for token in not_show_in):
                continue

            name_lower = name.lower()
            search_names = [name_lower]
            for alias in localized_names:
                alias_lower = alias.lower()
                if alias_lower != name_lower:
                    search_names.append(alias_lower)

            keywords = fields.get("Keywords") or ""
            categories = fields.get("Categories") or ""
            generic = fields.get("GenericName") or ""
            entries.append({
                "id": entry_id,
                "path": path,
                "name": name,
                "nameLower": name_lower,
                "generic": generic,
                "genericLower": generic.lower(),
                "comment": fields.get("Comment") or "",
                "exec": fields.get("Exec") or "",
                "icon": fields.get("Icon") or "",
                "categories": categories,
                "keywords": keywords,
                "keywordsLower": keywords.lower(),
                "startupWmClass": fields.get("StartupWMClass") or "",
                "terminal": as_bool(fields.get("Terminal")),
                "origin": detect_origin(path, user_root),
                "localizedNames": localized_names,
                "searchNames": search_names,
                "keywordsList": split_list(keywords),
                "categoriesList": split_list(categories),
            })

    entries.sort(key=lambda entry: (entry["nameLower"], entry["id"]))
    json.dump(entries, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
