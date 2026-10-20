#!/usr/bin/env bash
# Keep the shared default-branch ruleset (rulesets/default-branch.json) on
# every repo listed in rulesets/repos.txt.
#
#   rulesets/ruleset.sh check   # read-only: report missing or drifted rulesets, exit 1 on drift
#   rulesets/ruleset.sh apply   # create or update the ruleset on each repo
#
# check needs a token with Administration: read on the repos (the drift
# workflow uses a GitHub App token). apply needs Administration: write and is
# meant to run locally with your own `gh` login, so no write credential lives
# in CI. Requires gh and jq.
set -euo pipefail

mode="${1:-}"
case "$mode" in
  check | apply) ;;
  *)
    echo "usage: $0 check|apply" >&2
    exit 2
    ;;
esac

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
owner=zendern
want="$(cat "$dir/default-branch.json")"
name="$(jq -r .name <<<"$want")"
# Earlier name of the same ruleset (chezmoi-dotfiles had one called "main").
# apply renames it rather than leaving a duplicate; check reports it as drift.
legacy_name=main

want_norm="$(jq -S '.rules |= sort_by(.type)' <<<"$want")"

# Comparable form: only the fields default-branch.json sets, rules sorted by
# type, and each wanted rule's parameters reduced to the keys the file defines
# (the API adds defaults such as require_extra_approval_for_unattributed_changes).
# A rule the file doesn't have is kept whole, so it shows up as drift.
normalize() {
  jq -S --argjson want "$want" '
    {
      name, target, enforcement,
      bypass_actors: (.bypass_actors // []),
      conditions,
      rules: [
        .rules[] as $r
        | ([$want.rules[] | select(.type == $r.type)] | first) as $w
        | if $w == null then $r
          elif ($w.parameters // null) == null then {type: $r.type}
          else {type: $r.type,
                parameters: ($r.parameters
                  | with_entries(select(.key as $k | $w.parameters | has($k))))}
          end
      ] | sort_by(.type)
    }'
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ruleset.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

drift=0
summary=()

while read -r repo; do
  [[ -z "$repo" || "$repo" == \#* ]] && continue
  # The current name wins; fall back to the legacy one.
  id="$(gh api "repos/$owner/$repo/rulesets" --jq "
    [.[] | select(.source_type == \"Repository\")] as \$rs
    | ([\$rs[] | select(.name == \"$name\")] + [\$rs[] | select(.name == \"$legacy_name\")])
    | first | .id // empty")"

  if [[ -z "$id" ]]; then
    if [[ "$mode" == apply ]]; then
      gh api -X POST "repos/$owner/$repo/rulesets" --input - <<<"$want" >/dev/null
      summary+=("$repo: created")
    else
      summary+=("$repo: MISSING ruleset \"$name\"")
      drift=1
    fi
    continue
  fi

  have_norm="$(gh api "repos/$owner/$repo/rulesets/$id" | normalize)"
  if [[ "$have_norm" == "$want_norm" ]]; then
    summary+=("$repo: ok")
    continue
  fi

  if [[ "$mode" == apply ]]; then
    gh api -X PUT "repos/$owner/$repo/rulesets/$id" --input - <<<"$want" >/dev/null
    summary+=("$repo: updated")
  else
    summary+=("$repo: DRIFT")
    echo "--- $repo: wanted vs current"
    jq . <<<"$want_norm" >"$tmp/want.json"
    jq . <<<"$have_norm" >"$tmp/have.json"
    diff "$tmp/want.json" "$tmp/have.json" || true
    drift=1
  fi
done <"$dir/repos.txt"

printf '%s\n' "${summary[@]}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Ruleset \`$name\` ($mode)"
    printf -- '- %s\n' "${summary[@]}"
  } >>"$GITHUB_STEP_SUMMARY"
fi
exit "$drift"
