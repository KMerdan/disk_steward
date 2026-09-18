# Shared by install, uninstall and rollback: recoverable backups with a manifest.
#
# A backup directory holds copies of the files that were about to change plus
# manifest.json recording, per file, whether it existed, its hash before the
# change and its hash after. Restores are check-and-swap: a file is only put
# back when the current file is still the one the manifest says was written.
# Only backup directories created by these scripts are ever pruned.

sha256_of() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/cut -d' ' -f1
}

manifest_begin() {
  local dir=$1 operation=$2 client=$3 connector=$4
  {
    print "{"
    print "  \"schema\": \"disk-steward-client-backup-v1\","
    print "  \"operation\": \"$operation\","
    print "  \"client\": \"$client\","
    print "  \"connector\": \"${connector//\"/\\\"}\","
    print "  \"createdAt\": \"$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)\","
    print "  \"files\": {"
    print "  },"
    print "  \"plugin\": null,"
    print "  \"status\": \"in-progress\""
    print "}"
  } > "$dir/manifest.json"
  chmod 600 "$dir/manifest.json"
}

# Append a file record. The manifest is rewritten through Python's json module
# so that ordering, escaping and later updates stay well-formed.
manifest_file() {
  local dir=$1 name=$2 path=$3 presence=$4 hash=""
  [[ "$presence" == existed ]] && hash=$(sha256_of "$path")
  /usr/bin/python3 - "$dir/manifest.json" "$name" "$path" "$presence" "$hash" <<'PY'
import json, sys
manifest, name, path, presence, digest = sys.argv[1:]
data = json.load(open(manifest))
data["files"][name] = {"path": path, "existedBefore": presence == "existed", "sha256Before": digest or None, "sha256After": None, "existsAfter": None}
json.dump(data, open(manifest, "w"), indent=2, sort_keys=True)
PY
}

manifest_after() {
  local dir=$1 name=$2 path=$3 hash="" exists=false
  if [[ -f "$path" ]]; then hash=$(sha256_of "$path"); exists=true; fi
  /usr/bin/python3 - "$dir/manifest.json" "$name" "$hash" "$exists" <<'PY'
import json, sys
manifest, name, digest, exists = sys.argv[1:]
data = json.load(open(manifest))
data["files"][name]["sha256After"] = digest or None
data["files"][name]["existsAfter"] = exists == "true"
json.dump(data, open(manifest, "w"), indent=2, sort_keys=True)
PY
}

manifest_plugin() {
  local dir=$1 presence=$2
  /usr/bin/python3 - "$dir/manifest.json" "$presence" <<'PY'
import json, sys
manifest, presence = sys.argv[1:]
data = json.load(open(manifest))
data["plugin"] = {"existedBefore": presence == "existed", "backupName": "disk-steward-plugin" if presence == "existed" else None}
json.dump(data, open(manifest, "w"), indent=2, sort_keys=True)
PY
}

manifest_finish() {
  local dir=$1 outcome=$2
  /usr/bin/python3 - "$dir/manifest.json" "$outcome" <<'PY'
import json, sys
manifest, outcome = sys.argv[1:]
data = json.load(open(manifest))
data["status"] = outcome
data["finishedAt"] = __import__("time").strftime("%Y-%m-%dT%H:%M:%SZ", __import__("time").gmtime())
json.dump(data, open(manifest, "w"), indent=2, sort_keys=True)
PY
}

# True when the file at $2 still has the same bytes as the backup copy $1.
verify_unchanged() {
  local backup=$1 current=$2
  [[ -f "$current" ]] || return 1
  [[ "$(sha256_of "$backup")" == "$(sha256_of "$current")" ]]
}

# Atomically puts the backup copy back in place with private permissions.
restore_file() {
  local backup=$1 target=$2 temporary
  temporary=$(/usr/bin/mktemp "${target:h}/.${target:t}.disk-steward-restore.XXXXXX")
  /bin/cp "$backup" "$temporary"
  /bin/chmod 600 "$temporary"
  /bin/mv "$temporary" "$target"
}

# Owned backup directories are named <stamp>-<pid>, uninstalled-<stamp>-<pid>
# or rollback-<stamp>-<pid>. They are ordered by the embedded UTC stamp, never
# by the raw name, so the operation families interleave chronologically.
backup_sort_key() {
  local name=${1:t}
  name=${name#uninstalled-}
  name=${name#rollback-}
  print -r -- "$name"
}

# Prints the owned backup directories under $1, oldest first.
owned_backups_chronological() {
  local dir=$1
  local -a owned decorated
  owned=("$dir"/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9]*Z-*(N/) "$dir"/uninstalled-[0-9]*(N/) "$dir"/rollback-[0-9]*(N/))
  local entry
  for entry in "${owned[@]}"; do decorated+=("$(backup_sort_key "$entry")"$'\t'"$entry"); done
  local -a sorted
  sorted=(${(o)decorated})
  for entry in "${sorted[@]}"; do print -r -- "${entry#*$'\t'}"; done
}

# Keeps only the newest $2 owned backup directories (by stamp). Anything else
# in the directory is never touched.
prune_backups() {
  local dir=$1 keep=$2
  [[ -d "$dir" ]] || return 0
  local -a sorted
  sorted=("${(@f)$(owned_backups_chronological "$dir")}")
  local excess=$(( ${#sorted} - keep ))
  (( excess > 0 )) || return 0
  local index
  for (( index = 1; index <= excess; index++ )); do
    [[ -n "${sorted[index]}" ]] && /bin/rm -rf "${sorted[index]}"
  done
}
