#!/usr/bin/env bash
# orchestrate-steer.sh - WARN-level PreToolUse steering (advisory), SEPARATE from the hard-deny
# floor (orchestrate-guard.sh). Exit 0 ALWAYS - it NEVER blocks; it only emits a one-line steer to
# stderr when a rule matches, so Claude sees the nudge but the action still proceeds. Keeping it a
# distinct script preserves the floor's integrity (the guard stays pure hard-deny) and lets the
# steering be disabled (`configure --no-steer`) without touching deny logic.
#
# Rules (#95, #159, #226, #231, #284):
#   (1) MID-RUN CANONICAL EDIT (marker-gated): an Edit/Write whose target resolves to a canonical
#       file while THIS session's orchestrate marker is fresh -> WARN: log feedback to the mailbox,
#       do not edit mid-run. CANONICAL = SKILL.md, templates/*, orchestrate-guard.sh,
#       orchestrate-steer.sh, PLUS (#284) the Option-A-DEPLOYED helpers (HELPER_NAMES), the rest of
#       the floor fileset (orchestrate-authorize-merge.sh) and commands/*.md - their omission left a
#       mid-run safe-push.sh edit SILENT, which is the exact miss (#283) that motivated this rule. Enforces [[orchestrate-no-mid-run-canonical-edits]].
#       ACCEPTED FP (do not "fix" by weakening the rule): a TEAMMATE legitimately implementing an
#       assigned change to one of these files in its OWN worktree may ALSO see this WARN, because
#       tmux panes of one session share $TMUX and therefore see the same marker. Advisory-only, so the
#       cost is a nudge on legitimate work, never a block; #284 widened the file set, which widens this
#       FP too. (An earlier version of this header asserted a teammate has "a different $TMUX key, so
#       no marker" - that is NOT established and is probably false; the honest statement is here.)
#       ACCEPTED FP (2): the `*/commands/*.md` glob matches ANY repo's commands/ dir, so a
#       marker-active lead editing a TARGET repo's own commands/*.md draws a spurious nudge. Advisory;
#       tightening it to known basenames would miss a newly-added command - accepted.
#       Gated OFF
#       for a `Read` tool call (a Read carries a file_path too) so wiring the hook for Read never
#       turns reading a canonical file into a spurious "do not edit" nag.
#   (2) RAW GH-API MUTATION -> WRAPPER: a shell clause invoking `gh api` NOT via a gh-* wrapper,
#       with a REST mutation flag (-X/--method, -f/-F/--field/--raw-field/--input) or, for `gh api
#       graphql`, a query document that is a `mutation` operation (a GraphQL READ is silent) -> WARN:
#       use the gh-* wrapper. Marker-independent (steer every session).
#   (3) RAW GH PR comment/create -> CANONICAL PATH: a clause that IS a `gh pr comment`/`gh pr create`
#       invocation (gh at command position, subcommand as the next non-flag word after `pr`) -> WARN
#       toward reply-comment.sh/gh-comment.sh / /prep-pr. Reads never warn. Marker-independent (#159).
#   (4) REDUNDANT RE-READ -> WARN (#226): a 2nd+ `Read` of a path already read THIS session with an
#       unchanged mtime+size -> WARN: the content is already in context, skip the Read. Stateful
#       (per-session, keyed on the stdin session_id), marker-independent, advisory only. The valid
#       exception (post-compaction re-read) is why this is a WARN and never a deny.
#   (5) FOREGROUND-AGENT CONTAINMENT (marker-gated, #231): an `Agent` spawned with an EXPLICIT
#       run_in_background:false -> WARN: name it AND omit the flag (both halves), because a foreground Agent
#       BLOCKS the lead console for its entire run. Type-EXACT (absent != false; see
#       is_foreground_agent) and marker-gated. THREE accepted limitations are documented at the rule.
#
# These COMPLEMENT the guard's denies; they NEVER duplicate or weaken them (all WARN, exit 0). The
# guard already DENIES push-to-main, bare force, --no-verify, gh --admin, and marker-gated merge;
# this script touches none of those paths. Fails SILENT-OPEN (exit 0, no warn) on any internal error
# - it is advisory only, so a broken steer must never block a tool call.
set -u

FLOOR_DIR="${ORCHESTRATE_FLOOR_DIR:-$HOME/.claude/orchestrate-floor.d}"
TTL_HOURS="${ORCHESTRATE_FLOOR_TTL_HOURS:-72}"
# Reject a non-positive-integer TTL (mirrors the guard) so a typo'd override cannot silently
# disarm the marker gate; fall back to the 72h default.
case "$TTL_HOURS" in ''|*[!0-9]*) TTL_HOURS=72 ;; esac
[ "$TTL_HOURS" -ge 1 ] 2>/dev/null || TTL_HOURS=72

emit_warn() {
  printf 'STEER: %s\n' "$1" >&2
  exit 0
}

# --- self-test: feed the marker-INDEPENDENT command rules and assert each emits a WARN at exit 0.
# Used by setup/doctor to catch a silently broken steer. Prints PASS/FAIL.
if [ "${1:-}" = "--self-test" ]; then
  st_fail=""
  # (2) raw gh-api mutation must WARN at exit 0.
  st_out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh api -X PATCH repos/o/r/issues/1"}}' \
    | "$0" 2>&1); st_rc=$?
  { [ "$st_rc" -eq 0 ] && printf '%s' "$st_out" | grep -q 'STEER'; } \
    || st_fail="gh-api rule (rc=$st_rc out=$st_out)"
  # (3a) raw gh pr comment mutation must WARN at exit 0.
  if [ -z "$st_fail" ]; then
    st_out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr comment 5 -b hi"}}' \
      | "$0" 2>&1); st_rc=$?
    { [ "$st_rc" -eq 0 ] && printf '%s' "$st_out" | grep -q 'STEER'; } \
      || st_fail="gh-pr rule (comment) (rc=$st_rc out=$st_out)"
  fi
  # (3b) raw gh pr create mutation must WARN at exit 0 (so the PASS message's "create" claim is real).
  if [ -z "$st_fail" ]; then
    st_out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}' \
      | "$0" 2>&1); st_rc=$?
    { [ "$st_rc" -eq 0 ] && printf '%s' "$st_out" | grep -q 'STEER'; } \
      || st_fail="gh-pr rule (create) (rc=$st_rc out=$st_out)"
  fi
  # (2r)/(3r) the two READ shapes that used to false-positive must stay SILENT at exit 0: a GraphQL
  # read, and a gh pr read compounded with a standalone `create` word.
  for st_cmd in "gh api graphql -f query='{viewer{login}}'" "gh pr view 943 && echo create"; do
    [ -n "$st_fail" ] && break
    st_payload=$(jq -cn --arg c "$st_cmd" '{tool_name:"Bash",tool_input:{command:$c}}' 2>/dev/null) \
      || { st_fail="read-silence (jq unavailable)"; break; }
    st_out=$(printf '%s' "$st_payload" | "$0" 2>&1); st_rc=$?
    { [ "$st_rc" -eq 0 ] && ! printf '%s' "$st_out" | grep -q 'STEER'; } \
      || st_fail="read-silence '$st_cmd' (rc=$st_rc out=$st_out)"
  done
  # (4) read-dedup: a 2nd Read of an unchanged path (same session) must WARN at exit 0; the 1st is
  # silent. Uses an isolated temp state dir + file so the self-test never touches real read state.
  if [ -z "$st_fail" ]; then
    st_tmp=$(mktemp -d 2>/dev/null) || st_tmp=""
    if [ -n "$st_tmp" ]; then
      st_f="$st_tmp/f"; : > "$st_f"
      st_payload='{"tool_name":"Read","session_id":"selftest","tool_input":{"file_path":"'"$st_f"'"}}'
      # 1st read MUST be silent (asserted, not discarded - else a "1st read warns" regression would
      # slip through and the PASS message would be misleading).
      st_out1=$(printf '%s' "$st_payload" | ORCHESTRATE_READ_STATE_DIR="$st_tmp/state" "$0" 2>&1); st_rc1=$?
      { [ "$st_rc1" -eq 0 ] && ! printf '%s' "$st_out1" | grep -q 'STEER'; } \
        || st_fail="read-dedup rule 1st-read-not-silent (rc=$st_rc1 out=$st_out1)"
      # 2nd read of the unchanged path MUST warn at exit 0.
      if [ -z "$st_fail" ]; then
        st_out=$(printf '%s' "$st_payload" | ORCHESTRATE_READ_STATE_DIR="$st_tmp/state" "$0" 2>&1); st_rc=$?
        { [ "$st_rc" -eq 0 ] && printf '%s' "$st_out" | grep -q 'STEER'; } \
          || st_fail="read-dedup rule (rc=$st_rc out=$st_out)"
      fi
      rm -rf "$st_tmp" 2>/dev/null
    else
      # mktemp failed: do NOT let the PASS line falsely claim the read-dedup sub-check ran.
      st_fail="read-dedup rule (mktemp -d failed; sub-check could not run)"
    fi
  fi
  if [ -z "$st_fail" ]; then
    echo "orchestrate-steer self-test PASS (raw gh-api + raw gh pr comment/create mutations + read-dedup warned, graphql read + gh pr read silent, exit 0)"
    exit 0
  fi
  echo "orchestrate-steer self-test FAIL: expected a STEER warn at exit 0, got $st_fail" >&2
  exit 1
fi

# --- read the payload: stdin JSON first, then $TOOL_INPUT env, else fail OPEN (exit 0, no warn) ---
tool_input_json=""
stdin_json=""
if [ ! -t 0 ]; then
  stdin_json=$(cat 2>/dev/null)
fi
# tool_name + session_id live at the stdin TOP LEVEL (not inside tool_input), so they are available
# only via the real PreToolUse stdin payload - the $TOOL_INPUT env fallback carries neither, which is
# fine: the read-dedup rule (which needs both) simply cannot fire on that channel (fail-open).
tool_name=""
session_id=""
if [ -n "$stdin_json" ]; then
  tool_input_json=$(printf '%s' "$stdin_json" | jq -c '.tool_input // empty' 2>/dev/null)
  tool_name=$(printf '%s' "$stdin_json" | jq -r '.tool_name // empty' 2>/dev/null)
  session_id=$(printf '%s' "$stdin_json" | jq -r '.session_id // empty' 2>/dev/null)
fi
if [ -z "$tool_input_json" ] && [ -n "${TOOL_INPUT:-}" ]; then
  tool_input_json="$TOOL_INPUT"
fi
[ -z "$tool_input_json" ] && exit 0

file_path=$(printf '%s' "$tool_input_json" | jq -r '.file_path // empty' 2>/dev/null)
cmd=$(printf '%s' "$tool_input_json" | jq -r '.command // empty' 2>/dev/null)

# --- rule helpers ----------------------------------------------------------
# A canonical file: the skill playbook, any per-role template, or a floor/steer hook script. Resolve
# symlinks first (readlink -f) so both the repo path and a legacy ~/.claude/skills symlink match.
is_canonical_path() {
  local p resolved base
  p="$1"
  resolved=$(readlink -f -- "$p" 2>/dev/null || printf '%s' "$p")
  base=$(basename -- "$resolved")
  case "$base" in
    orchestrate-guard.sh|orchestrate-steer.sh) return 0 ;;
  esac
  case "$resolved" in
    */skills/orchestrate/SKILL.md) return 0 ;;
    */skills/orchestrate/templates/*) return 0 ;;
  esac
  # (#284) The Option-A-DEPLOYED helpers and the slash commands are canonical-source files by the
  # SAME argument as the guard: the repo is the source, they are deployed to a stable path, and a
  # mid-run edit of the working copy silently mutates canonical source while racing the in-flight PR.
  # Reproduced before this fix: a marker-active edit of safe-push.sh was SILENT, so the ONE mechanism
  # whose purpose is to say "log feedback, do not edit mid-run" missed the exact file that motivated
  # the rule (a lead edited safe-push.sh mid-run instead of filing the idea; #283).
  # Matched under a `scripts/` or `commands/` PARENT, so a same-named file elsewhere is not swallowed.
  #
  # Checked against BOTH the raw path AND the readlink-resolved path: a LEGACY claude-kit SYMLINK
  # (repo `scripts/safe-push.sh` -> `~/kit/safe-push.sh`) resolves AWAY from any `scripts/` parent, so
  # a resolved-only test goes silent on exactly the symlink layout readlink -f exists to handle. The
  # guard/steer entries above dodge this by matching on BASENAME; these are parent-anchored, so they
  # need both candidates.
  #
  # The helper list is LOCKSTEPPED to orchestrate-setup.py's HELPER_NAMES (the Option-A deployed set)
  # by a test-orchestrate-steer.py regression case. Do NOT hand-extend one without the other: this
  # list initially drifted 4 helpers behind that set, leaving a mid-run `issue-watch.sh` edit silent -
  # the very bug (#283/#284) this rule closes, for a different file.
  # The set is a SUPERSET of orchestrate-setup.py's HELPER_NAMES (the 15 Option-A-deployed helpers),
  # and deliberately so - be precise about which, because an earlier comment here over-claimed
  # "exactly HELPER_NAMES" and was wrong:
  #   - every HELPER_NAMES entry (a lockstep test pins this; adding a helper without adding it here
  #     is a test failure, which is how the first cut of this list drifted 4 helpers behind),
  #   - the deployed hook/CLI scripts (guard + steer match by BASENAME above; context-meter + setup),
  #   - orchestrate-authorize-merge.sh - on the FLOOR-FILESET ground, NOT the deployed ground. It is
  #     NOT in HELPER_NAMES and has no stable-path copy (a round-6 review caught an earlier version of
  #     this comment falsely calling it "deployed"). It is in because it ARMS the merge-auth token the
  #     deterministic FLOOR trusts to allow a merge - the repo's own floor fileset (the adversarial-prep
  #     charter) is guard + steer + authorize-merge - which makes it the most security-relevant non-guard
  #     script here. Backstopping pr-read-comments.sh while leaving THIS out was backwards.
  #   - the WHOLE `gh-*.sh` / `pr-*.sh` wrapper families, not just the deployed ones. Intentional: they
  #     are canonical plugin source by the same argument, and a future `pr-foo.sh` is covered on day 1,
  #   - `commands/*.md`.
  # THE MEMBERSHIP RULE, stated honestly. A file is canonical if a mid-run edit of it would mutate
  # CANONICAL PLUGIN SOURCE the live session depends on. That is THREE categories, not one - be exact,
  # because two earlier versions of this comment were WRONG (one claimed "exactly HELPER_NAMES", the
  # next claimed "the DEPLOYED set", and neither described the actual set):
  #   (i)   the Option-A-DEPLOYED set: HELPER_NAMES (15) + the deployed hook/CLI scripts;
  #   (ii)  the FLOOR fileset: guard + steer + authorize-merge (authorize-merge is NOT deployed - it is
  #         in on floor grounds alone, because it arms the merge-auth token the floor trusts);
  #   (iii) the remaining canonical PLUGIN SOURCE surfaces the session loads: the WHOLE `gh-*.sh` /
  #         `pr-*.sh` wrapper families (not just the deployed ones) and `commands/*.md`.
  # NOT canonical: an ordinary repo script that is in NONE of the three (an existing harness case pins
  # orchestrate-resources.py that way, and it is right).
  # First arm = the named HELPER_NAMES entries not already covered by the pr-*/gh-* globs, plus the
  # deployed hook/CLI scripts (guard + steer match by basename above). Second arm = the pr-*/gh-*
  # families (pr-watch, pr-unreplied-comments, pr-read-comments, pr-codeql-autofixes, gh-react, ...).
  # NOTE: no inline comments inside the pattern list - a `#` inside a continued case pattern is a
  # bash SYNTAX ERROR (shellcheck SC1009), which shellcheck caught here.
  local cand
  for cand in "$p" "$resolved"; do
    case "$cand" in
      */scripts/reply-comment.sh|*/scripts/resolve-threads.sh|*/scripts/cleanup-worktree.sh|\
      */scripts/patch-coverage.sh|*/scripts/safe-push.sh|*/scripts/gate-runner.py|\
      */scripts/pre-push-hook.sh|*/scripts/prefs-coverage.py|*/scripts/issue-watch.sh|\
      */scripts/ship-gate-preflight.sh|*/scripts/orchestrate-context-meter.sh|\
      */scripts/orchestrate-setup.py|*/scripts/orchestrate-authorize-merge.sh|\
      */scripts/run-paths.sh|*/scripts/base-freshness.sh|*/scripts/cr-quota-watch.sh|*/scripts/elmer-enqueue.sh|*/scripts/elmer-triage.sh|*/scripts/elmer-tick.sh|\
      */scripts/orchestrate-status.sh|*/scripts/orchestrate-feedback.sh)
        return 0 ;;
      */scripts/pr-*.sh|*/scripts/gh-*.sh) return 0 ;;
      */commands/*.md) return 0 ;;
    esac
  done
  return 1
}

# (#231) An EXPLICIT foreground Agent spawn. Keyed on the exact shape, never on falsiness.
#
# THE TRAP (from the #221 spike's 45 captured live payloads): `run_in_background` is ABSENT, not
# `false`, when the caller omits it - and an Agent DEFAULTS TO BACKGROUND. Of those 45 spawns, 13
# omitted the field entirely while running backgrounded and legal. So a naive `if not
# run_in_background` check would warn on 28 of 45 spawns and be WRONG on 13 of them. Demand the
# EXACT shape (a literal `false`); anything else - absent, true, malformed, non-Agent - is SILENT.
# This is the floor-matcher lesson applied to an advisory rule: deny-on-doubt becomes silent-on-doubt.
is_foreground_agent() {
  # TYPE-EXACT by construction: `== false` matches ONLY a JSON boolean false. An absent key is null
  # (not false), the string "false" is not false, 0 is not false, and a non-object input makes jq -e
  # exit nonzero. So absent / true / "false" / 0 / malformed / missing-jq all fall to SILENT, and only
  # the one sanctioned shape warns.
  #
  # NOTE the trap this avoids: `// empty` is UNUSABLE here (jq's alternative operator treats a literal
  # `false` as empty and would erase the very value we test for), and a shell falsy check would be
  # WORSE - `run_in_background` is ABSENT, not false, when omitted, and an Agent DEFAULTS TO BACKGROUND,
  # so 13 of the 45 live spawns the #221 spike captured were legal background agents with no field at
  # all. A falsy check would have warned on all of them.
  printf '%s' "$1" | jq -e '.run_in_background == false' >/dev/null 2>&1
}

# --- shared command scanner for rules (2) and (3) -------------------------------
# HISTORY. The base (pre-0.97.2) grepped the WHOLE command line for independent words, so a gh READ
# plus a stray word (`gh pr view 943 && echo create`) or any GraphQL read (`gh api graphql -f
# query='{...}'`) drew a nudge. The first per-clause rewrite fixed those but (a) required `gh` at the
# clause's command position, so `URL=$(gh pr create)`, `sudo gh pr create`, `timeout 30 gh pr comment`,
# `xargs gh pr comment`, `bash -c 'gh pr create'` went SILENT, (b) split clauses quote-blind, so a `|`
# inside a quoted --jq split a REST call from its -f field, and (c) forked 2-4 greps PER CLAUSE (a
# 300-clause command went from 0.04s to 4.6s). This scanner replaces all of that with ONE awk pass.
#
# THE SCAN (_steer_scan, one awk process, no per-clause forks). It walks the command once with a small
# frame stack and produces two things:
#   - a MASKED copy of the command, byte-aligned with the original, in which PROSE is overwritten with
#     `Q`: the contents (and delimiters) of '...', "...", $'...', a heredoc body, and a `#` comment.
#     CODE stays visible: the unquoted text, $(...) and `...` (even inside "..."), and a quote that is
#     the script argument of `sh/bash/zsh/dash/ksh -c` or of `eval` (its delimiters become spaces).
#     A quoted token therefore stays ONE non-space word, so a quoted flag value (`-H 'X-A: 1'`,
#     `--repo 'o/r'`) still reads as a single flag value.
#   - CLAUSE boundaries: an UNQUOTED (code-frame) `&&`, `||`, `;`, `|`, newline, or a LONE `&` (not
#     part of `&&`, `>&`, `<&`, `&>`). A separator inside prose quotes never splits, so a multi-line
#     GraphQL document stays with its `gh api graphql` while separate command lines split. A heredoc
#     body stays in the clause of the command that owns it. Backslash-newline continuations are joined
#     first.
# RULE 2 (raw gh api mutation) is judged PER CLAUSE: the masked clause must contain the `gh` and `api`
# words; if `api` [flag groups] `graphql` is the endpoint, it warns only when the RAW clause carries a
# `mutation` operation (right after `query=`, optionally `$'`/quoted; at the start of a document line;
# or after the `}` closing a preceding fragment) or a -X PATCH/PUT/DELETE; otherwise (REST) it warns on
# an explicit -X/--method or any -f/-F/--field/--raw-field/--input, exactly as the base did.
# RULE 3 (raw gh pr create/comment) is a WORD SEQUENCE anywhere in the masked command:
# `gh` [flag groups] `pr` [flag groups] `create|comment`, where `gh` is a standalone word (a path
# prefix like /opt/homebrew/bin/gh counts; gh-comment.sh does not). A read differs in the SUBCOMMAND
# word, not its position, so `gh pr view 5 && echo create` stays silent while `sudo gh pr create`,
# `URL=$(gh pr create)`, `xargs gh pr comment` and `bash -c 'gh pr create'` warn. Prose is masked, so
# `echo "run gh pr create later"` and `git commit -m "... gh pr create"` are silent.
#
# _FLAGS mirrors orchestrate-guard.sh's flag-group regex (inside `is_pr_merge`): zero or more
# `-flag [value]` groups, a value being a token that does not itself start with `-`.
_FLAGS='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'

# PREFILTER (#perf): a no-fork bash test that a command COULD match rule 2 or 3. Must be a strict
# SUPERSET of what _steer_scan can flag: rule 3 needs a `gh` word, a `pr` word and create|comment;
# rule 2 needs `gh`, `api` and one of the mutation flags (a GraphQL mutation always carries its query
# via -f/-F/--field/--raw-field). Everything else (the overwhelming majority of Bash calls, and the
# 300-clause read chains) costs what it did on base: no awk, no grep.
_steer_prefilter() {
  local c="$1" re_gh re_pr re_sub re_api re_flag
  re_gh='(^|[^[:alnum:]_-])gh[[:space:]]'
  re_pr='(^|[^[:alnum:]_-])pr[[:space:]]'
  re_sub='(create|comment)'
  re_api='(^|[[:space:]])api([[:space:]]|$)'
  re_flag='(-[XfF]|--method|--input)'
  [[ $c =~ $re_gh ]] || return 1
  [[ $c =~ $re_pr && $c =~ $re_sub ]] && return 0
  [[ $c =~ $re_api && $c =~ $re_flag ]] && return 0
  return 1
}

# Print `api` (rule 2 fires), `pr` (rule 3 fires) or nothing. LC_ALL=C so the walk is bytewise.
# Known residuals (advisory, all rare): a GraphQL document opening with a `#` comment line is
# recognized only because `mutation` then starts a line; a `query=` field whose VALUE is a search
# string beginning `mutation <word>` warns; a quote passed to a shell other than sh/bash/zsh/dash/ksh
# -c or eval (e.g. `ssh host 'gh pr create'`) is prose and silent; a GraphQL document not on the
# command line (-F query=@file, --input, -f query="$Q") cannot be classified and is SILENT-ON-DOUBT.
_steer_scan() {
  printf '%s' "$1" | LC_ALL=C awk -v FL="$_FLAGS" '
    # qs(len): a run of len `Q`s, sliced from a cache grown by doubling. NOT gsub(/./,"Q",s): that
    # is super-linear in BWK awk (a 2MB quoted argument took 37s through it; this path is linear).
    function qs(len) { while (length(QQ) < len) QQ = QQ QQ; return substr(QQ, 1, len) }
    function flush(upto) {
      if (upto <= seg) return
      M = M (masked ? qs(upto - seg) : substr(T, seg, upto - seg)); seg = upto
    }
    function setmode() { masked = (fc[d] ? 0 : 1) }
    function push(t, code, dl, rep) {
      flush(j); M = M rep; seg = j + dl
      d++; ft[d] = t; fc[d] = code; fp[d] = 0; setmode()
    }
    function pop(dl, rep) {
      flush(j); M = M rep; seg = j + dl
      d--; setmode()
    }
    function cut(len) { ncl++; cs[ncl] = cst; ce[ncl] = j; cst = j + len }
    function codeq(   t) {
      t = substr(T, (j > 48 ? j - 48 : 1), (j > 48 ? 48 : j - 1))
      return (t ~ /(^|[^[:alnum:]_.-])(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+$/ \
           || t ~ /(^|[^[:alnum:]_.-])eval[[:space:]]+$/)
    }
    function heredoc(   k, w, q, strip, ch) {
      k = j + 2; strip = 0
      if (a[k] == "-") { strip = 1; k++ }
      while (a[k] == " " || a[k] == "\t") k++
      w = ""
      while (k <= n && a[k] !~ /[[:space:];&|<>()]/) {
        ch = a[k]
        if (ch != SQ && ch != "\"" && ch != "\\") w = w ch
        k++
      }
      if (w != "") { nhd++; hd[nhd] = w; hs[nhd] = strip }
      return k - 1
    }
    function body(   h, k, e, line, cmp) {
      # j is at a code-frame newline with pending heredocs: skip each body up to its delimiter line.
      flush(j + 1); k = j + 1
      for (h = 1; h <= nhd; h++) {
        while (k <= n) {
          e = index(substr(T, k), "\n"); e = (e ? k + e - 1 : n + 1)
          line = substr(T, k, e - k); cmp = line
          if (hs[h]) sub(/^\t+/, "", cmp)
          k = e + 1
          if (cmp == hd[h]) break
        }
      }
      nhd = 0
      e = (k - 1 <= n ? k - 1 : n + 1)
      M = M qs(e - seg); seg = e
      return e
    }
    { T = (NR == 1 ? $0 : T "\n" $0) }
    END {
      SQ = sprintf("%c", 39); QQ = "Q"
      gsub(/\\\n/, "", T)
      n = split(T, a, "")
      d = 1; ft[1] = "U"; fc[1] = 1; masked = 0; seg = 1; M = ""; cst = 1; ncl = 0; nhd = 0
      for (j = 1; j <= n; j++) {
        c = a[j]; t = ft[d]
        if (t == "S") { if (c == SQ) pop(1, fc[d] ? " " : "Q"); continue }
        if (t == "E") { if (c == "\\") j++; else if (c == SQ) pop(1, "Q"); continue }
        if (t == "K") { if (c != "\n") continue; flush(j); d--; setmode(); t = ft[d] }
        if (t == "D") {
          if (c == "\\") j++
          else if (c == "\"") pop(1, fc[d] ? " " : "Q")
          else if (c == "$" && a[j+1] == "(") { push("P", 1, 0, ""); j++ }
          else if (c == "`") push("B", 1, 0, "")
          continue
        }
        # a code frame: U (top level), P ($(...)), B (`...`), or a -c/eval code quote (S/D with fc=1)
        if (c == "\\") { j++; continue }
        if (c == SQ) { q = codeq(); push("S", q, 1, q ? " " : "Q"); continue }
        if (c == "\"") { q = codeq(); push("D", q, 1, q ? " " : "Q"); continue }
        if (c == "$" && a[j+1] == SQ) { push("E", 0, 2, "QQ"); j++; continue }
        if (c == "$" && a[j+1] == "(") { push("P", 1, 0, ""); j++; continue }
        if (c == "`") { if (t == "B") pop(0, ""); else push("B", 1, 0, ""); continue }
        if (t == "P" && c == "(") { fp[d]++; continue }
        if (t == "P" && c == ")") { if (fp[d] > 0) fp[d]--; else { flush(j + 1); d--; setmode() } ; continue }
        if (c == "#" && (t == "U" || t == "P" || t == "B") && (j == 1 || a[j-1] ~ /[[:space:];&|(]/)) { push("K", 0, 0, ""); continue }
        if (c == "<" && a[j+1] == "<" && a[j+2] != "<" && (j == 1 || a[j-1] != "<")) { j = heredoc(); continue }
        if (c == "\n") { if (nhd > 0) j = body(); cut(1); continue }
        if (c == ";") { cut(1); continue }
        if (c == "|") { if (a[j+1] == "|") { cut(2); j++ } else cut(1); continue }
        if (c == "&") {
          if (a[j+1] == "&") { cut(2); j++ }
          else if (!(j > 1 && (a[j-1] == ">" || a[j-1] == "<")) && a[j+1] != ">") cut(1)
          continue
        }
      }
      j = n + 1; flush(j); cut(0)
      GH = "(^|[^[:alnum:]_-])gh([[:space:]]|$)"
      API = "(^|[[:space:]])api([[:space:]]|$)"
      GQL = "(^|[[:space:]])api" FL "[[:space:]]+graphql([[:space:]]|$)"
      MUT = "(query=[$]?[\"" SQ "]?[[:space:]]*|(^|\n)[[:space:]]*|[}][[:space:]]*)mutation([[:space:]]*[({]|[[:space:]]+[A-Za-z_]|[[:space:]]*$)"
      GQLM = "(--method[[:space:]=]+|-X[[:space:]=]*)(PATCH|PUT|DELETE)"
      RM = "(--method[[:space:]=]|-X[[:space:]=]?[A-Za-z])"
      RF = "(^|[[:space:]])(--(field|input|raw-field)[[:space:]=]|-[fF][[:space:]=]?[^[:space:]])"
      PR = "(^|[^[:alnum:]_.-])gh" FL "[[:space:]]+pr" FL "[[:space:]]+(create|comment)([^[:alnum:]_-]|$)"
      for (k = 1; k <= ncl; k++) {
        m = substr(M, cs[k], ce[k] - cs[k])
        if (m !~ GH || m !~ API) continue
        if (m ~ GQL) {
          r = substr(T, cs[k], ce[k] - cs[k])
          if (r ~ MUT || m ~ GQLM) { print "api"; exit }
        } else if (m ~ RM || m ~ RF) { print "api"; exit }
      }
      if (M ~ PR) print "pr"
    }'
}

# Which command rule (if any) fires: prints api | pr | nothing. Prefilter first (no fork on a miss).
_command_rule() {
  _steer_prefilter "$1" || return 0
  _steer_scan "$1"
}

# #312: EVERY key this session could have armed under, first-precedence first. Mirrors the guard's
# _session_keys() exactly. See the DERIVATION REGISTRY in orchestrate-guard.sh: SIX live copies of
# this derivation exist and must move together.
_sanitize_key() {
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9' '_'
}

_session_keys() {
  local key found=0
  if [ -n "${TMUX:-}" ]; then
    key=$(_sanitize_key "$TMUX") || return 1
    if [ -n "$key" ]; then printf '%s\n' "$key"; found=1; fi
  fi
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    key=$(_sanitize_key "$CLAUDE_CODE_SESSION_ID") || return 1
    if [ -n "$key" ]; then printf 'ccsid_%s\n' "$key"; found=1; fi
  fi
  [ "$found" -eq 1 ]
}

# THIS session's marker present AND fresh. Mirrors the guard's marker_active so the two sides never
# drift (GNU stat then BSD). #312: the session key is the sanitized $TMUX when set, AND/OR
# `ccsid_` + the sanitized $CLAUDE_CODE_SESSION_ID - tmux is NOT required for a gated session, so
# checking only $TMUX made every steer rule silently NO-OP for the whole non-tmux mode (rules 1 and 5
# are marker-gated). Like the guard, match ANY candidate key: an arm-side/check-side scheme
# disagreement must not silently drop the nudge. Only a session with NEITHER identifier is unkeyed.
marker_active() {
  local key marker mtime now age_h
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    marker="$FLOOR_DIR/$key"
    [ -f "$marker" ] || continue
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    now=$(date +%s) || return 1
    age_h=$(( (now - mtime) / 3600 ))
    if [ "$age_h" -lt "$TTL_HOURS" ]; then
      return 0
    fi
  done <<EOF
$(_session_keys)
EOF
  return 1
}

# A redundant re-Read: a 2nd+ Read of a path already read THIS session whose mtime+size are unchanged
# (so the content is already in-context; the harness itself prints "file state is current"). Stateful,
# per-session, keyed on the stdin session_id - a different mechanism than the stateless command grep.
# Returns 0 (warn) ONLY on an unchanged repeat; records the fingerprint every time. Cheap by design:
# mtime+size, never a content hash (hashing every read file on the hot path would add per-call latency
# for no dedup gain - an mtime bump already means the content changed). Fails-open (silent) on any
# missing input, a stat failure (nonexistent/unreadable path), or a state-write failure.
READ_STATE_DIR="${ORCHESTRATE_READ_STATE_DIR:-${TMPDIR:-/tmp}/orchestrate-read-state}"
is_redundant_reread() {
  local p="$1" sid="$2" fp sess_key sess_dir key rec prior
  [ -n "$p" ] && [ -n "$sid" ] || return 1
  # Fingerprint = "mtime size"; a stat failure (missing/unreadable) means we cannot dedup -> silent.
  # ACCEPTED LIMITATION (F30-class, fail-SAFE): stat mtime is 1-second granular on both GNU (%Y) and
  # BSD (%m), so a file MODIFIED within the same wall-clock second as a prior read - then re-read -
  # keeps an unchanged fingerprint and draws a SPURIOUS advisory WARN. Harmless (a nudge, never a
  # deny, never data loss) and vanishingly rare (real edits/rebuilds land seconds later); sub-second
  # precision is not portable across GNU/BSD, so this is documented rather than chased.
  fp=$(stat -c '%Y %s' -- "$p" 2>/dev/null || stat -f '%m %z' -- "$p" 2>/dev/null) || return 1
  [ -n "$fp" ] || return 1
  # Per-session dir keyed on a sanitized session_id; per-path file keyed on a cksum of the path
  # (collision-tolerant: a rare clash only ever mutes/mis-fires an ADVISORY warn).
  sess_key=$(printf '%s' "$sid" | LC_ALL=C tr -c 'A-Za-z0-9' '_')
  sess_dir="$READ_STATE_DIR/$sess_key"
  # No in-hook prune (hostile-review #1): the state store carries NO recursive-delete path. Each
  # entry is a ~15-byte fingerprint file under a per-session dir in ${TMPDIR:-/tmp}, which the OS
  # reaps; active pruning of sibling dirs would be a destructive footgun (a mis-pointed
  # ORCHESTRATE_READ_STATE_DIR could delete unrelated files) that buys negligible hygiene for a
  # tiny, tmp-resident, self-limiting store. So we only ever create our own session dir, never
  # delete anything.
  # PREDICTABLE-TEMP-PATH HARDENING (CR): the default lives under the world-writable shared /tmp, so
  # create each level owner-only (-m 700) and REFUSE to write into a dir we do not own (-O) - defends
  # against a local attacker pre-creating or symlinking `orchestrate-read-state` to redirect the
  # fingerprint writes. `-m` is applied per level (not `-p -m`, which SC2174-flags as ignoring
  # intermediates); a custom deep ORCHESTRATE_READ_STATE_DIR with missing parents simply fails open
  # (no dedup) rather than creating loose-permissioned intermediates. Fail-open (return 1 -> silent).
  # `-m 700` only applies on CREATE; a PRE-EXISTING dir we own could still be group/other-writable
  # (created earlier under a permissive umask), which -O would not catch and which lets a group member
  # symlink/clobber inside. So after verifying ownership, ENFORCE 700 with chmod on every level (CR/
  # Codoki review-round: never operate in a group/other-writable state dir). All steps fail-open.
  mkdir -m 700 "$READ_STATE_DIR" 2>/dev/null
  [ -d "$READ_STATE_DIR" ] && [ -O "$READ_STATE_DIR" ] && chmod 700 "$READ_STATE_DIR" 2>/dev/null || return 1
  mkdir -m 700 "$sess_dir" 2>/dev/null
  [ -d "$sess_dir" ] && [ -O "$sess_dir" ] && chmod 700 "$sess_dir" 2>/dev/null || return 1
  key=$(printf '%s' "$p" | cksum | cut -d' ' -f1)
  rec="$sess_dir/$key"
  prior=""
  [ -f "$rec" ] && prior=$(cat -- "$rec" 2>/dev/null)
  # Record the current fingerprint for next time (idempotent; identical write on a repeat).
  printf '%s' "$fp" > "$rec" 2>/dev/null || return 1
  # Warn only when this exact fingerprint was already on record (a prior unchanged read this session).
  [ -n "$prior" ] && [ "$prior" = "$fp" ]
}

# --- dispatch (at most one rule fires; a tool call carries a file_path XOR a command) -------------
# (4) read-dedup WARN: only a `Read` tool call, marker-independent. Evaluated before the canonical-edit
# rule so a Read never falls through to it (and the canonical rule is itself gated off for Read below).
if [ "$tool_name" = "Read" ] && [ -n "$file_path" ] && is_redundant_reread "$file_path" "$session_id"; then
  emit_warn "Redundant re-Read: '$file_path' is unchanged since you read it this session - skip it (a post-compaction re-read is the valid exception)."
fi

# (1) canonical-edit WARN: marker-gated. tool_name=='Read' is excluded so wiring the hook for Read
# does not turn a canonical-file READ into a spurious "do not edit mid-run" nag (an empty tool_name -
# the $TOOL_INPUT env channel - is NOT "Read", so the existing env-channel behavior is preserved).
if [ "$tool_name" != "Read" ] && [ -n "$file_path" ] && is_canonical_path "$file_path" && marker_active; then
  emit_warn "Canonical symlinked file - log skill/charter/guard feedback via orchestrate-feedback.sh add (~/.claude/orchestrate-feedback/) and triage via PR; do not edit mid-run."
fi

# (5) foreground-Agent containment WARN (#231): marker-gated, Agent-only. In an ORCHESTRATE session a
# foreground Agent BLOCKS the lead console end-to-end for its whole duration, freezing the lead's
# ability to drive the team. Only an EXPLICIT run_in_background=false trips it (is_foreground_agent is
# type-exact; absent means background). Advisory - it never blocks the spawn.
#
# It fires on a NAMED foreground agent too, deliberately: the override's rationale is ANTI-BLOCKING
# ("the anti-blocking requirement beats the naming-overhead concern"), and a named foreground agent
# blocks the console exactly as hard as an unnamed one (12 of the 45 spiked spawns were named AND
# foreground). The remedy must therefore be stated as BOTH halves - NAME IT **AND** OMIT THE FLAG:
#   - "name it" ALONE is causally FALSE: a name does NOT make an agent async, and `name` +
#     run_in_background:false still blocks the console (this is the named-foreground case above);
#   - "drop the flag" ALONE is UNSAFE on privileged work: it yields an UNNAMED BACKGROUNDED agent,
#     which the standing background-agent ban forbids and which STALLS SILENTLY on the first
#     permission prompt (it cannot answer one). Bare background is for a provably-0%-prompt
#     read-only pass and nothing else.
# Earlier drafts of this rule shipped each half alone; both were wrong, in opposite directions.
#
# THREE ACCEPTED LIMITATIONS, stated so nobody mistakes this for full enforcement:
#  (a) NUDGE, NOT A GUARANTEE. (#312 CLOSED the old "~15% blind" gap: marker_active() used to be
#      $TMUX-keyed, so it silently no-opped on the 7-of-45 live spawns the #221 spike captured
#      where $TMUX was ABSENT - exactly the in-process spawn case this rule most wants to catch.
#      The key now falls back to $CLAUDE_CODE_SESSION_ID, so those spawns ARE covered.) It remains
#      a nudge: an UNKEYED session (neither identifier) is still never gated, and this is advisory
#      either way.
#  (b) OVER-APPROXIMATES "team is live". The CLAUDE.md override forbids a foreground agent when the
#      lead has LIVE NAMED TEAMMATES, and re-sanctions the foreground one-shot when SOLO. A marker is
#      the closest proxy the hook can see, but it has a 72h TTL - so a lead who tore the team down and
#      is working solo in the same tmux pane can still be nagged for the SANCTIONED pattern. The
#      message therefore says so outright, so a correct spawn is not made to feel like a violation.
#  (c) NESTED SPAWNS. PreToolUse fires for a TEAMMATE's tool calls too, so a teammate spawning its own
#      foreground Agent also sees this WARN, where "blocks the LEAD console" is imprecise (it blocks
#      that teammate). Deliberately NOT special-cased: a nesting check would add a fragile inference
#      for an advisory nudge whose advice ("do not block yourself on a foreground agent") still holds.
if [ "$tool_name" = "Agent" ] && is_foreground_agent "$tool_input_json" && marker_active; then
  # ONE LINE, and deliberately so (#406). This fires on EVERY foreground spawn in a marker
  # session and blocks nothing, so its body is re-read by someone who has already seen it.
  # The full argument -- why BOTH halves are required, the nested-spawn imprecision, the
  # solo-in-a-stale-marker-pane exception -- is in the comment block directly above, which is
  # where a reader who needs convincing will look. A nudge states the fix; the file states
  # the case.
  emit_warn "Foreground Agent blocks the lead console for its whole run: give it a 'name' AND omit run_in_background:false (both halves). Sanctioned if you are solo."
fi

# (2)/(3) command rules, marker-independent (#159; advisory only). ONE scan decides both; the
# prefilter inside _command_rule keeps a command with no gh api/pr shape fork-free.
if [ -n "$cmd" ]; then
  cmd_rule=$(_command_rule "$cmd" 2>/dev/null)
  # (2) raw gh-api mutation WARN.
  if [ "$cmd_rule" = "api" ]; then
    emit_warn "Use the gh-* wrapper (gh-api-get.sh / gh-comment.sh / gh-codeql-dismiss.sh / gh-codeql-autofix.sh / gh-resolve-thread.sh / gh-delete-branch.sh) instead of raw gh api."
  fi
  # (3) raw gh pr comment/create -> canonical path WARN.
  if [ "$cmd_rule" = "pr" ]; then
    emit_warn "Canonical path: 'gh pr comment' -> reply-comment.sh / gh-comment.sh; 'gh pr create' -> /prep-pr (the required gate)."
  fi
fi

exit 0
