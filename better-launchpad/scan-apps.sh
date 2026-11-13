#!/usr/bin/env bash
# Collects XDG desktop entries and prints one JSON array.
#
# Parsing happens in awk, away from the plugin's 25 ms callback budget. The
# catalog mirrors the shell's visibility rules: user entries shadow system and
# export entries, NoDisplay/Hidden are dropped, and OnlyShowIn/NotShowIn are
# matched against XDG_CURRENT_DESKTOP.
#
# Display strings follow the system language: Name[lang_REGION] (and the
# GenericName/Comment/Keywords variants) are preferred over the untranslated
# values, using LC_ALL, LC_MESSAGES, then LANG.
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
    out = out "\"" jesc(local_values[i]) "\""
  }
  return out "]"
}

function json_search_names(name_lower, default_lower,   out, first, i, seen, alias) {
  out = "["
  first = 1
  delete seen
  if (name_lower != "") {
    out = out "\"" jesc(name_lower) "\""
    first = 0
    seen[name_lower] = 1
  }
  if (default_lower != "" && !(default_lower in seen)) {
    if (!first) out = out ","
    first = 0
    out = out "\"" jesc(default_lower) "\""
    seen[default_lower] = 1
  }
  for (i = 1; i <= local_count; i++) {
    alias = tolower(local_values[i])
    if (alias == "" || (alias in seen)) continue
    seen[alias] = 1
    out = out ",\"" jesc(alias) "\""
  }
  return out "]"
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

# Desktop-entry locales are POSIX-style: lang_COUNTRY.ENCODING@MODIFIER.
# Keep lang_COUNTRY@modifier so Name[zh_CN] and Name[sr@latin] both match.
function normalize_desktop_locale(raw,   base, mod, at, n, parts, lang, region, i) {
  raw = tolower(raw)
  sub(/\..*$/, "", raw)
  mod = ""
  at = index(raw, "@")
  if (at > 0) {
    mod = substr(raw, at + 1)
    raw = substr(raw, 1, at - 1)
  }
  gsub(/-/, "_", raw)
  n = split(raw, parts, "_")
  if (n < 1 || parts[1] == "") return ""
  lang = parts[1]
  region = ""
  for (i = 2; i <= n; i++) {
    if (parts[i] ~ /^[A-Za-z][A-Za-z]$/ || parts[i] ~ /^[0-9][0-9][0-9]$/) {
      region = toupper(parts[i])
      break
    }
  }
  base = lang
  if (region != "") base = base "_" region
  if (mod != "") base = base "@" mod
  return base
}

function add_locale(value,   n, parts, i) {
  if (value == "" || (value in locale_seen)) return
  locale_seen[value] = 1
  locale_pref[++locale_count] = value
}

function init_locales(   raw, c_locale, normalized, lang, region, mod, at, n, parts, i) {
  locale_count = 0
  delete locale_seen
  raw = ENVIRON["LC_ALL"]
  if (raw == "") raw = ENVIRON["LC_MESSAGES"]
  if (raw == "") raw = ENVIRON["LANG"]
  if (raw == "") return
  c_locale = tolower(raw)
  sub(/\..*$/, "", c_locale)
  sub(/@.*$/, "", c_locale)
  if (c_locale == "" || c_locale == "c" || c_locale == "posix") return

  normalized = normalize_desktop_locale(raw)
  if (normalized == "") return
  add_locale(normalized)

  lang = normalized
  region = ""
  mod = ""
  at = index(lang, "@")
  if (at > 0) {
    mod = substr(lang, at)
    lang = substr(lang, 1, at - 1)
  }
  n = split(lang, parts, "_")
  lang = parts[1]
  if (n > 1) region = "_" parts[2]

  if (mod != "") add_locale(lang mod)
  if (region != "") add_locale(lang region mod)
  if (region != "") add_locale(lang region)
  add_locale(lang)
}

function local_value(base, fallback,   i, key) {
  for (i = 1; i <= locale_count; i++) {
    key = base SUBSEP locale_pref[i]
    if (key in loc_values) return loc_values[key]
  }
  return fallback
}

function set_localized(base, raw_locale, raw_value,   locale, value) {
  locale = normalize_desktop_locale(raw_locale)
  if (locale == "") return
  value = decode(raw_value)
  if (value == "") return
  loc_values[base SUBSEP locale] = value
  if (base == "Name" && !(locale in name_locale_seen)) {
    name_locale_seen[locale] = 1
    local_values[++local_count] = value
  }
}

# True when Exec/TryExec starts a *.AppImage program.
function program_is_appimage(exec,   n, parts, i, prog, base) {
  exec = decode(exec)
  sub(/^[ \t]+/, "", exec)
  n = split(exec, parts, /[ \t]+/)
  if (n < 1) return 0
  i = 1
  prog = parts[i]
  gsub(/^"/, "", prog)
  gsub(/"$/, "", prog)
  if (prog == "env") {
    i = 2
    while (i <= n) {
      prog = parts[i]
      gsub(/^"/, "", prog)
      gsub(/"$/, "", prog)
      if (index(prog, "=") == 0) break
      i++
    }
    if (i > n) return 0
  }
  base = prog
  sub(/^.*\//, "", base)
  return tolower(base) ~ /\.appimage$/
}

function origin_of(path, appimage,   home, data_home, user_root) {
  if (index(path, "/flatpak/") && index(path, "/exports/share/applications/")) return "Flatpak"
  if (index(path, "/snap/") || index(path, "/snapd/desktop/applications/")) return "Snap"
  if (index(path, "/nix/store/")) return "Nix"
  if (appimage) return "AppImage"
  data_home = ENVIRON["XDG_DATA_HOME"]
  home = ENVIRON["HOME"]
  user_root = data_home != "" ? data_home : (home != "" ? home "/.local/share" : "")
  sub(/\/+$/, "", user_root)
  if (user_root != "" && index(path, user_root "/applications/") == 1) return "User"
  return "System"
}

function commit(   id, default_name, default_lower, name, name_lower, generic, generic_lower, keywords, keywords_lower, comment, appimage, integrate) {
  if (current == "") return
  if (tolower(type) != "application") return
  default_name = decode(t_name)
  if (default_name == "") return
  if (is_true(t_hidden) || is_true(t_nodisplay)) return
  if (!desktop_matches(t_only, t_not)) return

  id = current
  sub(/^.*\//, "", id)
  sub(/\.desktop$/, "", id)
  default_lower = tolower(default_name)
  name = local_value("Name", default_name)
  name_lower = tolower(name)
  generic = local_value("GenericName", decode(t_generic))
  generic_lower = tolower(generic)
  comment = local_value("Comment", decode(t_comment))
  keywords = local_value("Keywords", decode(t_keywords))
  keywords_lower = tolower(keywords)

  appimage = 0
  integrate = tolower(t_aiintegrate)
  if (integrate != "false" && integrate != "0" && integrate != "no") {
    if (t_aiversion != "" || program_is_appimage(t_tryexec) || program_is_appimage(t_exec)) appimage = 1
  }

  if (count > 0) printf ",\n"
  count++
  printf "{"
  printf "\"id\":\"%s\",", jesc(id)
  printf "\"path\":\"%s\",", jesc(current)
  printf "\"name\":\"%s\",", jesc(name)
  printf "\"nameLower\":\"%s\",", jesc(name_lower)
  printf "\"generic\":\"%s\",", jesc(generic)
  printf "\"genericLower\":\"%s\",", jesc(generic_lower)
  printf "\"comment\":\"%s\",", jesc(comment)
  printf "\"exec\":\"%s\",", jesc(decode(t_exec))
  printf "\"icon\":\"%s\",", jesc(decode(t_icon))
  printf "\"categories\":\"%s\",", jesc(decode(t_categories))
  printf "\"keywords\":\"%s\",", jesc(keywords)
  printf "\"keywordsLower\":\"%s\",", jesc(keywords_lower)
  printf "\"startupWmClass\":\"%s\",", jesc(decode(t_swc))
  printf "\"terminal\":%s,", is_true(t_terminal) ? "true" : "false"
  printf "\"origin\":\"%s\",", origin_of(current, appimage)
  printf "\"localizedNames\":%s,", json_localized()
  printf "\"searchNames\":%s,", json_search_names(name_lower, default_lower)
  printf "\"keywordsList\":%s,", json_list(keywords)
  printf "\"categoriesList\":%s", json_list(decode(t_categories))
  printf "}"
}

BEGIN {
  init_locales()
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
  delete local_values
  delete name_locale_seen
  delete loc_values
  type = ""; t_name = ""; t_generic = ""; t_comment = ""; t_exec = ""
  t_icon = ""; t_categories = ""; t_keywords = ""; t_swc = ""
  t_terminal = ""; t_hidden = ""; t_nodisplay = ""; t_only = ""; t_not = ""
  t_tryexec = ""; t_aiversion = ""; t_aiintegrate = ""
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
    raw_locale = ""
    sub(/\[.*/, "", base)
    raw_locale = k
    sub(/^[^[]+\[/, "", raw_locale)
    sub(/\]$/, "", raw_locale)
    set_localized(base, raw_locale, v)
    next
  }
  if (k == "Type") type = v
  else if (k == "Name") t_name = v
  else if (k == "GenericName") t_generic = v
  else if (k == "Comment") t_comment = v
  else if (k == "Exec") t_exec = v
  else if (k == "TryExec") t_tryexec = v
  else if (k == "Icon") t_icon = v
  else if (k == "Categories") t_categories = v
  else if (k == "Keywords") t_keywords = v
  else if (k == "StartupWMClass") t_swc = v
  else if (k == "Terminal") t_terminal = v
  else if (k == "Hidden") t_hidden = v
  else if (k == "NoDisplay") t_nodisplay = v
  else if (k == "OnlyShowIn") t_only = v
  else if (k == "NotShowIn") t_not = v
  else if (k == "X-AppImage-Version") t_aiversion = v
  else if (k == "X-AppImage-Integrate") t_aiintegrate = v
}

END {
  commit()
  printf "]\n"
}
' "${files[@]}" 2>/dev/null
