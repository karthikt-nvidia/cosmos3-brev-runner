#!/bin/bash
# Recommended thin Brev launchable setup script (paste into the launchable's setup script).
# Clones a public repo at a pinned ref and runs ONE repo-owned bootstrap command.
# Change behaviour by pushing to the repo and relaunching with --param REF=<sha>, not by editing the launchable.
#
# Launchable text parameters (all optional, defaults below):
#   REPO       public git URL
#   REF        40-char commit sha (branches/tags only if ALLOW_UNPINNED=1)
#   BOOTSTRAP  repo-relative path of the bootstrap script
set -uo pipefail

REPO="${REPO:-https://github.com/OWNER/cosmos3-brev-runner.git}"
REF="${REF:-0000000000000000000000000000000000000000}"
BOOTSTRAP="${BOOTSTRAP:-scripts/brev-bootstrap.sh}"
ALLOW_UNPINNED="${ALLOW_UNPINNED:-0}"
DIR=/opt/app/src

log() { echo "[launchable] $(date -u +%FT%TZ) $*"; }
fail() { log "RESULT=FAIL reason=$*"; exit 1; }

log "repo=$REPO ref=$REF bootstrap=$BOOTSTRAP"
if ! [[ "$REF" =~ ^[0-9a-f]{40}$ ]] && [ "$ALLOW_UNPINNED" != "1" ]; then
  fail "ref-not-pinned (set REF to a 40-char sha, or ALLOW_UNPINNED=1)"
fi
case "$BOOTSTRAP" in /*|*..*) fail "bootstrap-path-must-be-repo-relative" ;; esac

sudo mkdir -p "$(dirname "$DIR")" && sudo chown "$(id -u):$(id -g)" "$(dirname "$DIR")"
rm -rf "$DIR"
git init -q "$DIR" \
  && git -C "$DIR" remote add origin "$REPO" \
  && git -C "$DIR" fetch -q --depth 1 origin "$REF" \
  && git -C "$DIR" checkout -q FETCH_HEAD \
  || fail "fetch-failed"
log "commit=$(git -C "$DIR" rev-parse HEAD)"

[ -f "$DIR/$BOOTSTRAP" ] || fail "bootstrap-missing path=$BOOTSTRAP"
cd "$DIR" || fail "cd-failed"
exec bash "$DIR/$BOOTSTRAP"
