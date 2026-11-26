#!/usr/bin/env bash
#
# setup-test-env.sh - sandbox for testing update-project-on-merge.yml
#
# Creates (in a throw-away repo, NOT in novaapp):
#   * 2 Projects V2 with an "Automation Status" single-select field
#     (In development / Ready for next beta / Test in beta / Done)
#   * the release branches (release-<Name>-YY.S) + a decoy branch
#   * issues sitting in every status / project combination
#   * a patched copy of the workflow (new project + field + option IDs)
#
# Commands:
#   setup      create everything
#   run        open + merge/close test PRs, wait for the workflow, then verify
#   verify     compare real Project statuses with the expected ones
#   teardown   delete the sandbox repo and both projects
#
# Requirements: gh (authenticated), jq, base64.
#   gh auth refresh -s project,workflow         (needed for setup / run)
#   gh auth refresh -s delete_repo              (needed only for teardown)
#
# Optional env vars:
#   REPO=owner/name          sandbox repo (default: <you>/novaapp-workflow-sandbox)
#   ALLOW_EXISTING_REPO=1    allow reusing a repo that already exists
#   WORKFLOW_FILE=path       workflow to test (default: auto-detected)
#   PROJECTS_TOKEN=...       PAT stored as the PROJECTS_TOKEN secret
#                            (default: your current `gh auth token`)

set -euo pipefail

STATE_DIR="${STATE_DIR:-.test-env}"
STATE_FILE="$STATE_DIR/state.env"

# Branches used by the tests. Format: release-<Name>-YY.S (year . sprint number).
BR_RAPTOR="release-Raptor-26.1"
BR_SERVICE="release-RaptorService-26.1"
BR_RAPTOR_NEW="release-Raptor-26.2"         # "new sprint" branch, created during `run`
BR_SERVICE_NEW="release-RaptorService-26.12" # new sprint branch with a 2-digit sprint number
BR_DECOY="release-Raptor-26.1.1"            # not a valid sprint branch: must NOT trigger

# Original IDs hard-coded in the workflow (replaced by the new ones).
OLD_RP_ID="PVT_kwHOECsPhs4BtFjj";  OLD_RP_FIELD="PVTSSF_lAHOECsPhs4BtFjjzhrQqEA"
OLD_RP_DEV="c39ef371"; OLD_RP_READY="7765758d"; OLD_RP_DONE="561b6537"
OLD_SP_ID="PVT_kwHOECsPhs4BtFjk";  OLD_SP_FIELD="PVTSSF_lAHOECsPhs4BtFjkzhrQqFA"
OLD_SP_DEV="965977d8"; OLD_SP_READY="8d28a959"; OLD_SP_DONE="7965d3be"

# key | status in RP project | status in SP project   (dev ready beta done none -)
#   '-' = not in that project, 'none' = in project but Automation Status empty
ISSUES='
r_dev1|dev|-
r_dev2|dev|-
r_ready|ready|-
r_beta|beta|-
r_done|done|-
r_nostatus|none|-
r_none|-|-
both_dev|dev|dev
s_only_dev|-|dev
r_closed|dev|-
r_decoy|dev|-
s_dev1|-|dev
s_done|-|done
s_direct|-|dev
r_sprint2|dev|-
s_sprint12|-|dev
'

# key | project | expected status AFTER the test run (independent oracle)
EXPECTED='
r_dev1|RP|Ready for next beta
r_dev2|RP|Ready for next beta
r_ready|RP|Ready for next beta
r_beta|RP|Test in beta
r_done|RP|Done
r_nostatus|RP|(no status)
r_none|RP|(not in project)
r_none|SP|(not in project)
both_dev|RP|Ready for next beta
both_dev|SP|In development
s_only_dev|RP|(not in project)
s_only_dev|SP|In development
r_closed|RP|In development
r_decoy|RP|In development
s_dev1|SP|Ready for next beta
s_done|SP|Done
s_direct|SP|In development
r_sprint2|RP|Ready for next beta
s_sprint12|SP|Ready for next beta
'

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

save() { printf '%s=%q\n' "$1" "$2" >> "$STATE_FILE"; }
load() { [ -f "$STATE_FILE" ] || die "No state found. Run: $0 setup"; . "$STATE_FILE"; }
var()  { eval "printf '%s' \"\${$1:-}\""; }          # indirect variable read
inum() { var "I_$1"; }                               # issue number by key

preflight() {
  command -v gh >/dev/null  || die "gh CLI not found"
  command -v jq >/dev/null  || die "jq not found"
  command -v base64 >/dev/null || die "base64 not found"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
  LOGIN=$(gh api user --jq .login)
  REPO="${REPO:-$LOGIN/novaapp-workflow-sandbox}"
  OWNER_ARG="$LOGIN"
}

# ---------------------------------------------------------------- helpers
put_file() { # branch path message text
  local branch="$1" path="$2" msg="$3" text="$4" sha b64
  local args
  b64=$(printf '%s\n' "$text" | base64 | tr -d '\n')
  sha=$(gh api "repos/$REPO/contents/$path?ref=$branch" --jq .sha 2>/dev/null || true)
  args=(-X PUT "repos/$REPO/contents/$path" -f "message=$msg" -f "content=$b64" -f "branch=$branch")
  [ -n "$sha" ] && args+=(-f "sha=$sha")
  gh api "${args[@]}" >/dev/null
}

branch_sha() { gh api "repos/$REPO/git/ref/heads/$1" --jq .object.sha; }

create_branch() { # name from_sha
  gh api "repos/$REPO/git/refs" -f "ref=refs/heads/$1" -f "sha=$2" >/dev/null 2>&1 \
    || info "branch $1 already exists (kept)"
}

# Creates "Automation Status" on a project; sets <P>_FIELD and <P>_OPT_* vars.
create_status_field() { # prefix project_node_id
  local p="$1" pid="$2" out
  out=$(gh api graphql -f query='
    mutation($pid: ID!) {
      createProjectV2Field(input: {
        projectId: $pid, dataType: SINGLE_SELECT, name: "Automation Status",
        singleSelectOptions: [
          {name: "In development",       color: BLUE,   description: "Work in progress"},
          {name: "Ready for next beta",  color: YELLOW, description: "Merged to release branch"},
          {name: "Test in beta",         color: ORANGE, description: "Being tested in beta"},
          {name: "Done",                 color: GREEN,  description: "Finished"}
        ]
      }) {
        projectV2Field { ... on ProjectV2SingleSelectField { id options { id name } } }
      }
    }' -f pid="$pid")
  local fid; fid=$(jq -r '.data.createProjectV2Field.projectV2Field.id' <<<"$out")
  [ -n "$fid" ] && [ "$fid" != null ] || die "Could not create field: $out"
  opt() { jq -r --arg n "$1" '.data.createProjectV2Field.projectV2Field.options[]|select(.name==$n)|.id' <<<"$out"; }
  printf -v "${p}_FIELD" '%s' "$fid"
  printf -v "${p}_OPT_DEV"   '%s' "$(opt 'In development')"
  printf -v "${p}_OPT_READY" '%s' "$(opt 'Ready for next beta')"
  printf -v "${p}_OPT_BETA"  '%s' "$(opt 'Test in beta')"
  printf -v "${p}_OPT_DONE"  '%s' "$(opt 'Done')"
}

create_project() { # prefix title
  local p="$1" title="$2" json num
  json=$(gh project create --owner "$OWNER_ARG" --title "$title" --format json)
  num=$(jq -r .number <<<"$json")
  [ "$num" != 10 ] || die "New project got number 10, which the workflow refuses to touch. Delete it and retry."
  printf -v "${p}_NUM" '%s' "$num"
  printf -v "${p}_ID"  '%s' "$(jq -r .id <<<"$json")"
  printf -v "${p}_TITLE" '%s' "$title"
  gh project link "$num" --owner "$OWNER_ARG" --repo "$REPO" >/dev/null 2>&1 || true
  create_status_field "$p" "$(var "${p}_ID")"
  info "$title -> project #$num"
  for k in NUM ID TITLE FIELD OPT_DEV OPT_READY OPT_BETA OPT_DONE; do save "${p}_$k" "$(var "${p}_$k")"; done
}

patch_workflow() { # src out
  local src="$1" out="$2"
  cp "$src" "$out"
  local sedargs=(
    -e "s|PROJECT_NUMBER=11\"|PROJECT_NUMBER=${RP_NUM}\"|"
    -e "s|PROJECT_NUMBER=12\"|PROJECT_NUMBER=${SP_NUM}\"|"
    -e "s|TEST - RaptorService Automation|${SP_TITLE}|"
    -e "s|TEST - Raptor Automation|${RP_TITLE}|"
    -e "s|$OLD_RP_ID|${RP_ID}|g"      -e "s|$OLD_RP_FIELD|${RP_FIELD}|g"
    -e "s|$OLD_RP_DEV|${RP_OPT_DEV}|g" -e "s|$OLD_RP_READY|${RP_OPT_READY}|g" -e "s|$OLD_RP_DONE|${RP_OPT_DONE}|g"
    -e "s|$OLD_SP_ID|${SP_ID}|g"      -e "s|$OLD_SP_FIELD|${SP_FIELD}|g"
    -e "s|$OLD_SP_DEV|${SP_OPT_DEV}|g" -e "s|$OLD_SP_READY|${SP_OPT_READY}|g" -e "s|$OLD_SP_DONE|${SP_OPT_DONE}|g"
  )
  sed -i.bak "${sedargs[@]}" "$out" && rm -f "$out.bak"
  local old
  for old in "$OLD_RP_ID" "$OLD_RP_FIELD" "$OLD_SP_ID" "$OLD_SP_FIELD" \
             "$OLD_RP_DEV" "$OLD_RP_READY" "$OLD_RP_DONE" "$OLD_SP_DEV" "$OLD_SP_READY" "$OLD_SP_DONE"; do
    ! grep -q "$old" "$out" || die "Patching failed: '$old' still present in $out"
  done
}

find_workflow() {
  local here; here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  local c
  for c in "${WORKFLOW_FILE:-}" ".github/workflows/update-project-on-merge.yml" \
           "$here/.github/workflows/update-project-on-merge.yml" "$here/update-project-on-merge.yml"; do
    [ -n "$c" ] && [ -f "$c" ] && { printf '%s' "$c"; return; }
  done
  die "Workflow file not found. Set WORKFLOW_FILE=path/to/update-project-on-merge.yml"
}

status_option() { # prefix status-word -> option id
  case "$2" in
    dev)   var "${1}_OPT_DEV" ;;
    ready) var "${1}_OPT_READY" ;;
    beta)  var "${1}_OPT_BETA" ;;
    done)  var "${1}_OPT_DONE" ;;
    *)     printf '' ;;
  esac
}

add_to_project() { # prefix issue_url status_word
  local p="$1" url="$2" st="$3" item opt
  [ "$st" = "-" ] && return 0
  item=$(gh project item-add "$(var "${p}_NUM")" --owner "$OWNER_ARG" --url "$url" --format json | jq -r .id)
  opt=$(status_option "$p" "$st")
  if [ -n "$opt" ]; then
    gh project item-edit --id "$item" --project-id "$(var "${p}_ID")" \
      --field-id "$(var "${p}_FIELD")" --single-select-option-id "$opt" >/dev/null
  fi
}

# ---------------------------------------------------------------- setup
cmd_setup() {
  preflight
  [ ! -f "$STATE_FILE" ] || die "State exists ($STATE_FILE). Run '$0 teardown' first."
  mkdir -p "$STATE_DIR"; : > "$STATE_FILE"
  local wf; wf=$(find_workflow)

  log "Repository $REPO"
  if gh repo view "$REPO" >/dev/null 2>&1; then
    [ "${ALLOW_EXISTING_REPO:-0}" = 1 ] || die "$REPO already exists. Set ALLOW_EXISTING_REPO=1 to reuse it (never use your real repo)."
    info "reusing existing repo"
  else
    gh repo create "$REPO" --private --add-readme >/dev/null
    info "created (private)"
  fi
  save REPO "$REPO"; save OWNER_ARG "$OWNER_ARG"
  DEFAULT_BRANCH=$(gh api "repos/$REPO" --jq .default_branch); save DEFAULT_BRANCH "$DEFAULT_BRANCH"

  log "Projects and Automation Status fields"
  create_project RP "SANDBOX - Raptor Automation"
  create_project SP "SANDBOX - RaptorService Automation"

  log "Patched workflow -> $DEFAULT_BRANCH"
  patch_workflow "$wf" "$STATE_DIR/update-project-on-merge.yml"
  put_file "$DEFAULT_BRANCH" ".github/workflows/update-project-on-merge.yml" \
    "Add workflow under test (sandbox IDs)" "$(cat "$STATE_DIR/update-project-on-merge.yml")"
  info "source: $wf"

  log "Secret PROJECTS_TOKEN"
  gh secret set PROJECTS_TOKEN --repo "$REPO" --body "${PROJECTS_TOKEN:-$(gh auth token)}" >/dev/null
  info "set (needs repo + project scopes)"

  log "Branches"
  local sha; sha=$(branch_sha "$DEFAULT_BRANCH")
  for b in "$BR_RAPTOR" "$BR_SERVICE" "$BR_DECOY"; do create_branch "$b" "$sha"; info "$b"; done

  log "Issues"
  local line key rp sp url num
  while IFS='|' read -r key rp sp; do
    [ -n "$key" ] || continue
    url=$(gh issue create --repo "$REPO" --title "[test] $key (RP:$rp SP:$sp)" \
            --body "Fixture for workflow test. RP=$rp SP=$sp")
    num=${url##*/}
    add_to_project RP "$url" "$rp"
    add_to_project SP "$url" "$sp"
    save "I_$key" "$num"
    info "#$num  $key  (Raptor: $rp, RaptorService: $sp)"
  done <<<"$ISSUES"

  log "Done"
  info "Repo:  https://github.com/$REPO"
  info "Next:  $0 run      (opens/merges the test PRs, waits, verifies)"
}

# ---------------------------------------------------------------- run
make_pr() { # name base_branch msg...   -> prints PR number
  local name="$1" base="$2"; shift 2
  local head="test/$name" i=0 msg url
  create_branch "$head" "$(branch_sha "$base")"
  for msg in "$@"; do
    i=$((i+1))
    put_file "$head" "tests/$name-$i.txt" "$msg" "$name commit $i"
  done
  url=$(gh pr create --repo "$REPO" --base "$base" --head "$head" \
          --title "Test $name -> $base" --body "Automated test PR")
  printf '%s' "${url##*/}"
}

merge_pr() {
  local n="$1" t
  for t in 1 2 3 4 5 6; do
    gh pr merge "$n" --repo "$REPO" --merge >/dev/null 2>&1 && return 0
    sleep 4
  done
  die "Could not merge PR #$n"
}

wait_runs() { # expected_count
  local want="$1" json total pending deadline=$((SECONDS+300))
  log "Waiting for $want workflow runs (up to 5 min)"
  while (( SECONDS < deadline )); do
    json=$(gh run list --repo "$REPO" --workflow update-project-on-merge.yml --limit 30 \
             --json status,conclusion,event,headBranch 2>/dev/null || echo '[]')
    total=$(jq length <<<"$json")
    pending=$(jq '[.[]|select(.status!="completed")]|length' <<<"$json")
    if (( total >= want && pending == 0 )); then break; fi
    sleep 8
  done
  jq -r '.[] | "    \(.event)  \(.headBranch)  status=\(.status)  conclusion=\(.conclusion)"' <<<"$json"
  info "(expected: pr-a, pr-b, pr-e, pr-f success; pr-c skipped; none for the decoy PR or direct push)"
}

cmd_run() {
  load
  local A B C D E F sha
  log "Simulating new sprints: creating $BR_RAPTOR_NEW and $BR_SERVICE_NEW"
  sha=$(branch_sha "$DEFAULT_BRANCH")
  create_branch "$BR_RAPTOR_NEW" "$sha"; create_branch "$BR_SERVICE_NEW" "$sha"

  log "Opening test PRs"
  A=$(make_pr pr-a "$BR_RAPTOR" \
        "Fix login validation #$(inum r_dev1)" \
        "Multiple refs: #$(inum r_dev2), #$(inum r_ready) #$(inum r_beta) #$(inum r_done) #$(inum r_nostatus) #$(inum r_none) #$(inum both_dev) #$(inum s_only_dev) and missing #9999" \
        "Duplicate ref again #$(inum r_dev1)")
  info "PR A #$A -> $BR_RAPTOR   (to be MERGED)"
  B=$(make_pr pr-b "$BR_SERVICE" \
        "Service fix #$(inum s_dev1) #$(inum s_done)")
  info "PR B #$B -> $BR_SERVICE   (to be MERGED)"
  C=$(make_pr pr-c "$BR_RAPTOR" "WIP #$(inum r_closed)")
  info "PR C #$C -> $BR_RAPTOR   (to be CLOSED without merge)"
  D=$(make_pr pr-d "$BR_DECOY" "Decoy branch #$(inum r_decoy)")
  info "PR D #$D -> $BR_DECOY   (to be MERGED, not a sprint branch)"
  E=$(make_pr pr-e "$BR_RAPTOR_NEW" "New sprint fix #$(inum r_sprint2)")
  info "PR E #$E -> $BR_RAPTOR_NEW   (to be MERGED, new sprint branch)"
  F=$(make_pr pr-f "$BR_SERVICE_NEW" "New sprint service fix #$(inum s_sprint12)")
  info "PR F #$F -> $BR_SERVICE_NEW   (to be MERGED, 2-digit sprint)"

  log "Merging / closing"
  merge_pr "$A"; info "merged #$A"
  merge_pr "$B"; info "merged #$B"
  gh pr close "$C" --repo "$REPO" >/dev/null; info "closed #$C"
  merge_pr "$D"; info "merged #$D"
  merge_pr "$E"; info "merged #$E"
  merge_pr "$F"; info "merged #$F"

  log "Direct push to $BR_SERVICE (must NOT trigger)"
  put_file "$BR_SERVICE" "tests/direct-push.txt" "Direct push #$(inum s_direct)" "direct push"

  wait_runs 5
  cmd_verify
}

# ---------------------------------------------------------------- verify
cmd_verify() {
  load
  log "Verifying Automation Status"
  local key proj exp resp num pid actual fails=0 total=0
  local query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){
      projectItems(first:20){nodes{project{id} fieldValueByName(name:"Automation Status"){
      ... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}'
  while IFS='|' read -r key proj exp; do
    [ -n "$key" ] || continue
    num=$(inum "$key"); pid=$(var "${proj}_ID")
    resp=$(gh api graphql -f query="$query" -f o="${REPO%%/*}" -f r="${REPO##*/}" -F n="$num")
    actual=$(jq -r --arg pid "$pid" '
      [.data.repository.issue.projectItems.nodes[]|select(.project.id==$pid)]
      | if length==0 then "(not in project)" else (.[0].fieldValueByName.name // "(no status)") end' <<<"$resp")
    total=$((total+1))
    if [ "$actual" = "$exp" ]; then
      printf '  PASS  #%-4s %-11s %s: %s\n' "$num" "$key" "$proj" "$actual"
    else
      printf '  FAIL  #%-4s %-11s %s: expected "%s", got "%s"\n' "$num" "$key" "$proj" "$exp" "$actual"
      fails=$((fails+1))
    fi
  done <<<"$EXPECTED"
  echo
  if [ "$fails" -eq 0 ]; then echo "ALL $total CHECKS PASSED"; else echo "$fails of $total CHECKS FAILED"; return 1; fi
}

# ---------------------------------------------------------------- teardown
cmd_teardown() {
  load
  if [ "${1:-}" != "--yes" ]; then
    printf 'Delete repo %s and projects #%s, #%s? [y/N] ' "$REPO" "$RP_NUM" "$SP_NUM"
    read -r ans; [ "$ans" = y ] || [ "$ans" = Y ] || die "aborted"
  fi
  gh project delete "$RP_NUM" --owner "$OWNER_ARG" >/dev/null && info "deleted project #$RP_NUM" || true
  gh project delete "$SP_NUM" --owner "$OWNER_ARG" >/dev/null && info "deleted project #$SP_NUM" || true
  gh repo delete "$REPO" --yes >/dev/null && info "deleted repo $REPO" \
    || info "repo not deleted (run: gh auth refresh -s delete_repo)"
  rm -rf "$STATE_DIR"
}

main() {
  case "${1:-}" in
    setup)    cmd_setup ;;
    run)      cmd_run ;;
    verify)   cmd_verify ;;
    teardown) shift; cmd_teardown "$@" ;;
    *) sed -n '3,22p' "$0"; exit 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
