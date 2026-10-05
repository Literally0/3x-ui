#!/usr/bin/env bash
# Merges upstream main into this fork up to the first conflicting commit and
# mirrors new upstream v*.*.* tags onto the merge commit that first contains them.
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/MHSanaei/3x-ui.git}"
BRANCH="${BRANCH:-main}"
TAG_GLOB="${TAG_GLOB:-v*.*.*}"

git config user.name "${GIT_USER_NAME:-github-actions[bot]}"
git config user.email "${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

git remote get-url upstream > /dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
git fetch --quiet --no-tags upstream "+refs/heads/${BRANCH}:refs/remotes/upstream/${BRANCH}"
git fetch --quiet --no-tags upstream "+refs/tags/*:refs/upstream-tags/*"

start=$(git rev-parse HEAD)
conflict_sha=""
new_tags=()

# Only tags newer than the fork point are followed; older upstream history stays untagged.
declare -A pending
while read -r ref; do
    tag=${ref#refs/upstream-tags/}
    [[ $tag == $TAG_GLOB ]] || continue
    git rev-parse -q --verify "refs/tags/${tag}" > /dev/null && continue
    sha=$(git rev-parse "${ref}^{commit}")
    git merge-base --is-ancestor "$sha" "$start" && continue
    pending[$tag]=$sha
done < <(git for-each-ref --format='%(refname)' refs/upstream-tags)

mapfile -t chain < <(git rev-list --reverse --first-parent "HEAD..upstream/${BRANCH}")
if [[ ${#chain[@]} -eq 0 ]]; then
    echo "Already up to date with upstream/${BRANCH}"
    exit 0
fi

# Tag-bearing commits (and the tip) are merge targets so each tag lands on a
# merge commit that contains its commit; everything else merges in one step.
declare -A boundary
unassigned=("${!pending[@]}")
for c in "${chain[@]}"; do
    remaining=()
    for t in "${unassigned[@]}"; do
        if git merge-base --is-ancestor "${pending[$t]}" "$c"; then
            boundary[$c]=1
        else
            remaining+=("$t")
        fi
    done
    unassigned=("${remaining[@]}")
done
boundary[${chain[-1]}]=1

tag_merged() {
    local t
    for t in "${!pending[@]}"; do
        git rev-parse -q --verify "refs/tags/${t}" > /dev/null && continue
        if git merge-base --is-ancestor "${pending[$t]}" HEAD; then
            git tag "$t" HEAD
            new_tags+=("$t")
        fi
    done
}

merge_one() {
    git merge --no-ff --no-edit -m "chore(sync): merge upstream ${1:0:8}" "$1" > /dev/null 2>&1
}

abort_with_conflict() {
    conflict_sha=$1
    conflict_files=$(git diff --name-only --diff-filter=U)
    git merge --abort
}

merge_to() {
    local target=$1 c
    if merge_one "$target"; then
        tag_merged
        return 0
    fi
    git merge --abort
    for c in $(git rev-list --reverse --first-parent "HEAD..${target}"); do
        if ! merge_one "$c"; then
            abort_with_conflict "$c"
            return 1
        fi
        tag_merged
    done
}

for c in "${chain[@]}"; do
    [[ -n ${boundary[$c]:-} ]] || continue
    merge_to "$c" || break
done

if [[ -n "$conflict_sha" ]]; then
    subject=$(git log -1 --format=%s "$conflict_sha")
    title="Upstream sync blocked at ${conflict_sha:0:8}"
    body=$(printf 'Upstream commit %s (%s) conflicts with this fork.\n\nConflicting files:\n\n%s\n\nResolve by merging it locally: `git merge %s`, then push.' \
        "$conflict_sha" "$subject" "$(sed 's/^/- /' <<< "$conflict_files")" "$conflict_sha")
    echo "::warning::${title}: ${subject}"
    {
        echo "### ${title}"
        echo "$body"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    if [[ -n "${GH_TOKEN:-}" ]] && command -v gh > /dev/null; then
        if [[ -z "$(gh issue list --state open --search "\"${title}\" in:title" --json number -q '.[].number')" ]]; then
            gh issue create --title "$title" --body "$body" > /dev/null
        fi
    fi
fi

if [[ "$(git rev-parse HEAD)" == "$start" ]]; then
    echo "Nothing merged"
    exit 0
fi

refs=("HEAD:refs/heads/${BRANCH}")
for t in "${new_tags[@]}"; do refs+=("refs/tags/${t}:refs/tags/${t}"); done
git push --atomic origin "${refs[@]}"
echo "Pushed ${BRANCH} to $(git rev-parse --short HEAD); new tags: ${new_tags[*]:-none}"
