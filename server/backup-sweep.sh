#!/bin/bash
# backup-sweep.sh — common box change-control + backup sweep contract.
#
# Command:  backup-sweep.sh            run the sweep (agent or cron)
# Output:   $OUT (conf) — bundles/archives land here; MANIFEST.json indexes all.
#           Names: <item>-<UTC ts>-<hash>.bundle|.tar.gz  (ts sorts, hash dedupes)
#           Unchanged items produce no new archive; nothing is overwritten.
# Retention: keep newest $RETENTION per item, older pruned.
# Security:  $OUT is mode 700 root-only (contains secrets); download via ssh rsync.
#
# Rollback law: before a risky change, in the item's repo run
#   git tag pre-<change>          # then make the change
#   git revert <sha>              # rollback is a revert commit, 60s limit
set -euo pipefail
umask 077

CONF="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/backup-sweep.conf"
[ -r "$CONF" ] || { echo "FATAL: missing $CONF" >&2; exit 1; }
# shellcheck source=backup-sweep.conf
source "$CONF"
SWEEP_VERSION=1

mkdir -p "$OUT/repos" "$OUT/files" "$OUT/stores"
chmod 700 "$OUT"
exec 9>/run/lock/backup-sweep.lock
flock -n 9 || { echo "FATAL: another sweep is running" >&2; exit 1; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"
MANIFEST_TMP="$OUT/.MANIFEST.json.$$"
FAILURES=0
JSON_REPOS="" JSON_FILES="" JSON_STORES=""

newest_existing() { # dir prefix -> newest matching filename or ""
  ls -1 "$1" 2>/dev/null | grep "^$2" | sort | tail -1 || true
}

prune() { # dir prefix: keep newest $RETENTION, delete older
  local dir=$1 prefix=$2 f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n+1))
    if [ "$n" -gt "$RETENTION" ]; then
      rm -f -- "$dir/$f"
      echo "  pruned (retention $RETENTION): $f"
    fi
  done < <(ls -1 "$dir"/"$prefix" 2>/dev/null | sort -r)
}

jq_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---- repos ----
sweep_repo() { # name|path|autocommit
  IFS='|' read -r name path autocommit <<<"$1"
  local dir="$OUT/repos/$name"
  mkdir -p "$dir"
  if [ ! -d "$path/.git" ]; then echo "WARN: $name: no .git at $path, skipped" >&2; FAILURES=1; return; fi
  local dirty=0 autocommitted=0 head h8
  [ -n "$(git -C "$path" status --porcelain)" ] && dirty=1
  if [ "$autocommit" = 1 ] && [ "$dirty" = 1 ]; then
    git -C "$path" add -A
    git -C "$path" diff --cached --quiet || { git -C "$path" commit -q -m "sweep auto-commit $TS"; autocommitted=1; }
  fi
  if ! git -C "$path" rev-parse --verify -q HEAD >/dev/null; then
    echo "repo $name: no commits yet, nothing to bundle"; JSON_REPOS+="{\"name\":\"$(jq_esc "$name")\",\"path\":\"$(jq_esc "$path")\",\"head\":null,\"bundle\":null,\"dirty\":$dirty,\"autocommitted\":$autocommitted},"
    return
  fi
  head="$(git -C "$path" rev-parse HEAD)"
  h8="$(git -C "$path" rev-parse --short HEAD)"
  local last bundle
  last="$(newest_existing "$dir" "$name-")"
  bundle="$name-$TS-$h8.bundle"
  if echo "$last" | grep -q -- "-$h8\.bundle$"; then
    echo "repo $name: unchanged at $h8, bundle kept: $last"
  else
    local tmp="$dir/.$bundle.part"
    rm -f "$tmp"
    git -C "$path" bundle create --quiet "$tmp" --all
    mv -f "$tmp" "$dir/$bundle"
    echo "repo $name: bundled $h8 -> $bundle"
  fi
  prune "$dir" "$name-"
  JSON_REPOS+="{\"name\":\"$(jq_esc "$name")\",\"path\":\"$(jq_esc "$path")\",\"head\":\"$head\",\"bundle\":\"$(newest_existing "$dir" "$name-")\",\"dirty\":$dirty,\"autocommitted\":$autocommitted},"
}

# ---- filesets ----
sweep_files() { # name|paths (comma sep)
  IFS='|' read -r name paths <<<"$1"
  local dir="$OUT/files/$name"
  mkdir -p "$dir"
  local missing=0 p
  IFS=',' read -ra plist <<<"$paths"
  for p in "${plist[@]}"; do [ -e "$p" ] || { echo "WARN: fileset $name: missing path $p" >&2; missing=1; }; done
  [ $missing = 1 ] && { FAILURES=1; return; }
  local tmp="$dir/.set.part" h8 last arch
  # deterministic tar: stable bytes for identical trees -> stable hash
  tar --sort=name --numeric-owner --owner=0 --group=0 --mtime=@0 \
      --exclude=.git -cf - -C / "${plist[@]}" | gzip -n > "$tmp"
  h8="$(sha256sum "$tmp" | cut -c1-8)"
  last="$(newest_existing "$dir" "$name-")"
  if echo "$last" | grep -q -- "-$h8\.tar\.gz$"; then
    rm -f "$tmp"
    echo "fileset $name: unchanged ($h8), kept: $last"
  else
    arch="$name-$TS-$h8.tar.gz"
    mv -f "$tmp" "$dir/$arch"
    echo "fileset $name: changed -> $arch (previous moved aside by retention)"
  fi
  prune "$dir" "$name-"
  JSON_FILES+="{\"set\":\"$(jq_esc "$name")\",\"sha256_8\":\"$h8\",\"archive\":\"$(newest_existing "$dir" "$name-")\"},"
}

# ---- stores (non-git: gix/graphlite; copied+gzipped, no deletes) ----
sweep_store() { # name|path
  IFS='|' read -r name path <<<"$1"
  [ -e "$path" ] || { echo "store $name: absent, skipped"; return; }
  local dir="$OUT/stores/$name"
  mkdir -p "$dir"
  local tmp="$dir/.set.part" h8 last arch
  tar --sort=name --numeric-owner --owner=0 --group=0 --mtime=@0 \
      --exclude=.git -cf - -C / "$path" | gzip -n > "$tmp"
  h8="$(sha256sum "$tmp" | cut -c1-8)"
  last="$(newest_existing "$dir" "$name-")"
  if echo "$last" | grep -q -- "-$h8\.tar\.gz$"; then
    rm -f "$tmp"; echo "store $name: unchanged ($h8), kept: $last"
  else
    arch="$name-$TS-$h8.tar.gz"
    mv -f "$tmp" "$dir/$arch"; echo "store $name: changed -> $arch"
  fi
  prune "$dir" "$name-"
  JSON_STORES+="{\"store\":\"$(jq_esc "$name")\",\"sha256_8\":\"$h8\",\"archive\":\"$(newest_existing "$dir" "$name-")\"},"
}

echo "== backup sweep $TS (out=$OUT retention=$RETENTION) =="
for r in "${REPOS[@]}";   do sweep_repo   "$r"; done
for f in "${FILESETS[@]}"; do sweep_files "$f"; done
for s in "${STORES[@]}";  do sweep_store "$s"; done

# ---- manifest (atomic replace) ----
{
  printf '{\n'
  printf '  "generated": "%s",\n' "$TS"
  printf '  "version": %s,\n' "$SWEEP_VERSION"
  printf '  "out": "%s",\n  "retention": %s,\n' "$(jq_esc "$OUT")" "$RETENTION"
  printf '  "repos": [%s],\n' "${JSON_REPOS%,}"
  printf '  "filesets": [%s],\n' "${JSON_FILES%,}"
  printf '  "stores": [%s]\n' "${JSON_STORES%,}"
  printf '}\n'
} > "$MANIFEST_TMP"
mv -f "$MANIFEST_TMP" "$OUT/MANIFEST.json"
echo "== manifest: $OUT/MANIFEST.json =="
[ $FAILURES = 0 ] || { echo "sweep completed with WARNINGS" >&2; exit 2; }
exit 0
