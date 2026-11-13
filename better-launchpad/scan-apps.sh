#!/usr/bin/env bash
# Collects XDG desktop entries and prints one JSON array.
#
# Parsing happens in awk, away from the plugin's 25 ms callback budget. The
# catalog mirrors the shell's visibility rules: user entries shadow system and
# export entries, NoDisplay/Hidden are dropped, and OnlyShowIn/NotShowIn are
# matched against XDG_CURRENT_DESKTOP.
#
# Usage: scan-apps.sh [application-dir ...]
# Without arguments the XDG application directories are searched.

set -u

add_unique() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

appdirs=()
if [ "$#" -gt 0 ]; then
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    add_unique "$dir" "${appdirs[@]:-}" || appdirs+=("$dir")
  done
else
  data_dirs=()
  if [ -n "${XDG_DATA_HOME:-}" ]; then
    data_dirs+=("$XDG_DATA_HOME")
  elif [ -n "${HOME:-}" ]; then
    data_dirs+=("$HOME/.local/share")
  fi
  IFS=':' read -r -a xdg_dirs <<< "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
  for dir in "${xdg_dirs[@]:-}"; do
    [ -n "$dir" ] || continue
    add_unique "$dir" "${data_dirs[@]:-}" || data_dirs+=("$dir")
  done
  [ -n "${HOME:-}" ] && data_dirs+=("$HOME/.local/share/flatpak/exports/share")
  data_dirs+=("/var/lib/flatpak/exports/share" "/var/lib/snapd/desktop")
  for dir in "${data_dirs[@]}"; do
    appdirs+=("$dir/applications")
  done
fi

files=()
declare -A seen_ids=()
for appdir in "${appdirs[@]}"; do
  [ -d "$appdir" ] || continue
  while IFS= read -r -d '' file; do
    stem=${file##*/}
    stem=${stem%.desktop}
    [ -n "${seen_ids[$stem]:-}" ] && continue
    seen_ids[$stem]=1
    files+=("$file")
  done < <(find "$appdir" -name '*.desktop' \( -type f -o -type l \) -print0 2>/dev/null)
done

if [ "${#files[@]}" -eq 0 ]; then
  printf '[]\n'
  exit 0
fi

awk '
function is_true(v) {
  v = tolower(v)
  return v == "true" || v == "1" || v == "yes"
}

function decode(v,   out, i, c, n) {
  out = ""
  n = length(v)
  for (i = 1; i <= n; i++) {
    c = substr(v, i, 1)
    if (c == "\\" && i < n) {
      i++
      c = substr(v, i, 1)
      if (c == "s") c = " "
      else if (c == "n") c = "\n"
      else if (c == "t") c = "\t"
      else if (c == "r") c = "\r"
    }
    out = out c
  }
  return out
}

function jesc(v,   out, i, c) {
  out = ""
  for (i = 1; i <= length(v); i++) {
    c = substr(v, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\n") out = out "\\n"
    else if (c == "\r") out = out "\\r"
    else if (c == "\t") out = out "\\t"
    else out = out c
  }
  return out
}

function trim(v) {
  gsub(/^[ \t]+/, "", v)
  gsub(/[ \t]+$/, "", v)
  return v
}

function json_list(v,   n, parts, i, out, first) {
  n = split(v, parts, ";")
  out = "["
  first = 1
  for (i = 1; i <= n; i++) {
    parts[i] = trim(parts[i])
    if (parts[i] == "") continue
    if (!first) out = out ","
    first = 0
    out = out "\"" jesc(parts[i]) "\""
  }
  return out "]"
}

function json_localized(   out, first, i) {
  out = "["
  first = 1
  for (i = 1; i <= local_count; i++) {
    if (!first) out = out ","
    first = 0
    out = out "\"" jesc(local_names[i]) "\""
  }
  return out "]"
}

function json_search_names(name_lower,   out, first, i, seen, alias) {
  out = "[\"" jesc(name_lower) "\"]"
  first = 0
  for (i = 1; i <= local_count; i++) {
    alias = tolower(local_names[i])
    if (alias == name_lower || (alias in seen)) continue
    seen[alias] = 1
    out = substr(out, 1, length(out) - 1) ",\"" jesc(alias) "\"]"
  }
  return out
}

function desktop_matches(only, not_list,   m, desktops, parts, i, j, found, hidden) {
  m = split(tolower(ENVIRON["XDG_CURRENT_DESKTOP"]), desktops, ":")
  if (only != "") {
    found = 0
    split(tolower(only), parts, ";")
    for (i = 1; i <= length(parts); i++) {
      if (parts[i] == "") continue
      for (j = 1; j <= m; j++) if (parts[i] == desktops[j]) found = 1
    }
    if (!found) return 0
  }
  if (not_list != "") {
    split(tolower(not_list), parts, ";")
    for (i = 1; i <= length(parts); i++) {
      if (parts[i] == "") continue
      for (j = 1; j <= m; j++) if (parts[i] == desktops[j]) return 0
    }
  }
  return 1
}

function origin_of(path,   home, data_home, user_root) {
  if (index(path, "/flatpak/") && index(path, "/exports/share/applications/")) return "Flatpak"
  if (index(path, "/snap/") || index(path, "/snapd/desktop/applications/")) return "Snap"
  if (index(path, "/nix/store/")) return "Nix"
  data_home = ENVIRON["XDG_DATA_HOME"]
  home = ENVIRON["HOME"]
  user_root = data_home != "" ? data_home : (home != "" ? home "/.local/share" : "")
  sub(/\/+$/, "", user_root)
  if (user_root != "" && index(path, user_root "/applications/") == 1) return "User"
  return "System"
}

function commit(   id, name, name_lower, generic, keywords, categories) {
  if (current == "") return
  if (tolower(type) != "application") return
  name = decode(t_name)
  if (name == "") return
  if (is_true(t_hidden) || is_true(t_nodisplay)) return
  if (!desktop_matches(t_only, t_not)) return

  id = current
  sub(/^.*\//, "", id)
  sub(/\.desktop$/, "", id)
  name_lower = tolower(name)
  generic = decode(t_generic)
  keywords = decode(t_keywords)
  categories = decode(t_categories)

  if (count > 0) printf ",\n"
  count++
  printf "{"
  printf "\"id\":\"%s\",", jesc(id)
  printf "\"path\":\"%s\",", jesc(current)
  printf "\"name\":\"%s\",", jesc(name)
  printf "\"nameLower\":\"%s\",", jesc(name_lower)
  printf "\"generic\":\"%s\",", jesc(generic)
  printf "\"genericLower\":\"%s\",", jesc(tolower(generic))
  printf "\"comment\":\"%s\",", jesc(decode(t_comment))
  printf "\"exec\":\"%s\",", jesc(decode(t_exec))
  printf "\"icon\":\"%s\",", jesc(decode(t_icon))
  printf "\"categories\":\"%s\",", jesc(categories)
  printf "\"keywords\":\"%s\",", jesc(keywords)
  printf "\"keywordsLower\":\"%s\",", jesc(tolower(keywords))
  printf "\"startupWmClass\":\"%s\",", jesc(decode(t_swc))
  printf "\"terminal\":%s,", is_true(t_terminal) ? "true" : "false"
  printf "\"origin\":\"%s\",", origin_of(current)
  printf "\"localizedNames\":%s,", json_localized()
  printf "\"searchNames\":%s,", json_search_names(name_lower)
  printf "\"keywordsList\":%s,", json_list(keywords)
  printf "\"categoriesList\":%s", json_list(categories)
  printf "}"
}

BEGIN {
  count = 0
  current = ""
  group = ""
  printf "["
}

FNR == 1 {
  commit()
  current = FILENAME
  group = ""
  local_count = 0
  type = ""; t_name = ""; t_generic = ""; t_comment = ""; t_exec = ""
  t_icon = ""; t_categories = ""; t_keywords = ""; t_swc = ""
  t_terminal = ""; t_hidden = ""; t_nodisplay = ""; t_only = ""; t_not = ""
}

{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^\[/) { group = line; next }
  if (group != "[Desktop Entry]") next
  p = index(line, "=")
  if (p <= 1) next
  k = substr(line, 1, p - 1)
  v = substr(line, p + 1)
  if (k ~ /^[^[]+\[[^]]+\]$/) {
    base = k
    sub(/\[.*/, "", base)
    if (base == "Name") local_names[++local_count] = decode(v)
    next
  }
  if (k == "Type") type = v
  else if (k == "Name") t_name = v
  else if (k == "GenericName") t_generic = v
  else if (k == "Comment") t_comment = v
  else if (k == "Exec") t_exec = v
  else if (k == "Icon") t_icon = v
  else if (k == "Categories") t_categories = v
  else if (k == "Keywords") t_keywords = v
  else if (k == "StartupWMClass") t_swc = v
  else if (k == "Terminal") t_terminal = v
  else if (k == "Hidden") t_hidden = v
  else if (k == "NoDisplay") t_nodisplay = v
  else if (k == "OnlyShowIn") t_only = v
  else if (k == "NotShowIn") t_not = v
}

END {
  commit()
  printf "]\n"
}
' "${files[@]}" 2>/dev/null
