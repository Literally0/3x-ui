#!/usr/bin/env bash
# Drives sync-upstream.sh against throwaway upstream/fork repos.
set -euo pipefail

script=$(cd "$(dirname "$0")" && pwd)/sync-upstream.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_USER_NAME=test GIT_USER_EMAIL=test@example.invalid
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export UPSTREAM_URL="$tmp/up"
export GITHUB_STEP_SUMMARY="$tmp/summary"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_eq() { [[ "$1" == "$2" ]] || fail "$3: got '$1', want '$2'"; }

# Stub gh: records created issues; `issue list` reports the ones already filed.
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" << 'EOF'
#!/usr/bin/env bash
case "$2" in
    list) cat "$ISSUES" 2> /dev/null || true ;;
    create) shift 2; [[ $1 == --title ]] && echo "$2" >> "$ISSUES"; echo 1 >> "$ISSUES.numbers" ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export ISSUES="$tmp/issues" PATH="$tmp/bin:$PATH" GH_TOKEN=x

git init -q -b main "$tmp/up"
git -C "$tmp/up" config commit.gpgsign false
commit() { git -C "$1" add -A && git -C "$1" commit -qm "$2"; }
echo base > "$tmp/up/f"
commit "$tmp/up" base
git -C "$tmp/up" tag v1.0.0

git clone -q --bare "$tmp/up" "$tmp/fork.git"
git clone -q "$tmp/fork.git" "$tmp/w"
git -C "$tmp/w" config commit.gpgsign false
echo fork > "$tmp/w/f"
commit "$tmp/w" "fork edit"
git -C "$tmp/w" push -q origin main

echo a > "$tmp/up/a"; commit "$tmp/up" A
echo b > "$tmp/up/b"; commit "$tmp/up" B
git -C "$tmp/up" tag v1.0.1
echo upstream > "$tmp/up/f"; commit "$tmp/up" "C conflicts"
echo d > "$tmp/up/d"; commit "$tmp/up" D
git -C "$tmp/up" tag v1.0.2

cd "$tmp/w"
bash "$script" > /dev/null 2>&1

remote_tags=$(git --git-dir="$tmp/fork.git" tag | tr '\n' ' ')
expect_eq "$remote_tags" "v1.0.0 v1.0.1 " "tags on fork"
expect_eq "$(git --git-dir="$tmp/fork.git" show main:f)" "fork" "fork edit survives"
git --git-dir="$tmp/fork.git" cat-file -e main:b || fail "commit before conflict not merged"
git --git-dir="$tmp/fork.git" cat-file -e main:d 2> /dev/null && fail "commit after conflict was merged"
git merge-base --is-ancestor "$(git rev-parse upstream/main~2)" v1.0.1 || fail "v1.0.1 does not contain its upstream commit"
expect_eq "$(git rev-parse v1.0.1)" "$(git --git-dir="$tmp/fork.git" rev-parse main)" "v1.0.1 sits on the merge"
expect_eq "$(wc -l < "$ISSUES")" "1" "issues after first run"
grep -q "Upstream sync blocked at" "$ISSUES" || fail "issue title"

before=$(git --git-dir="$tmp/fork.git" rev-parse main)
bash "$script" > /dev/null 2>&1
expect_eq "$(git --git-dir="$tmp/fork.git" rev-parse main)" "$before" "rerun leaves main alone"
expect_eq "$(git --git-dir="$tmp/fork.git" tag | wc -l | tr -d ' ')" "2" "rerun adds no tags"

# Once the conflict is resolved by hand the next run follows upstream again.
git merge -q --no-edit upstream/main~1 > /dev/null 2>&1 || { echo fork > f; git add f; git commit -qm resolve; }
git push -q origin main
bash "$script" > /dev/null 2>&1
git --git-dir="$tmp/fork.git" cat-file -e main:d || fail "commit after resolved conflict not merged"
expect_eq "$(git --git-dir="$tmp/fork.git" tag | tr '\n' ' ')" "v1.0.0 v1.0.1 v1.0.2 " "tags after resolve"
echo "ok"
