#!/usr/bin/env bash
# Publishes a build's folder (named after its tag, with the IPA, manifest.plist, index.html and
# build.json) to GitHub Pages, served from the gh-pages branch.
#
# The branch is rewritten as a single orphan commit every time, so the IPAs don't pile up in its
# history. It keeps every version from main and the last $KEEP_BRANCH_BUILDS branch builds. If another
# build publishes at the same time, the push is refused (--force-with-lease) and everything is redone
# on top of what that build published.
#
# Usage: GH_TOKEN=… GITHUB_REPOSITORY=owner/repo scripts/publish-pages.sh <build folder>
# PAGES_REMOTE overrides the remote (a local path, to try it out).
set -euo pipefail

folder=${1:?Usage: publish-pages.sh <build folder>}
[ -f "$folder/build.json" ] || { echo "::error::$folder has no build.json" >&2; exit 1; }
folder=$(cd "$folder" && pwd)
tag=$(basename "$folder")
scripts=$(cd "$(dirname "$0")" && pwd)
remote=${PAGES_REMOTE:-"https://x-access-token:${GH_TOKEN:?GH_TOKEN is not set}@github.com/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}.git"}
keep=${KEEP_BRANCH_BUILDS:-20}
title=${APP_NAME:-Leonera Chat}
attempts=5

for attempt in $(seq 1 "$attempts"); do
    work=$(mktemp -d)
    mkdir -p "$work/current" "$work/site"

    # What gh-pages holds now, if it exists: it is kept, and it is what the push expects to replace.
    lease=""
    status=0
    git ls-remote --exit-code --heads "$remote" gh-pages > "$work/head" || status=$?
    if [ "$status" -eq 0 ]; then
        git init -q "$work/fetch"
        git -C "$work/fetch" fetch -q --depth=1 "$remote" refs/heads/gh-pages
        lease=$(git -C "$work/fetch" rev-parse FETCH_HEAD)
        git -C "$work/fetch" archive FETCH_HEAD | tar -x -C "$work/current"
    elif [ "$status" -ne 2 ]; then
        echo "::error::Could not read the gh-pages branch." >&2
        exit 1
    fi

    # Only the folders of earlier builds: the branch may have been created from the code.
    for dir in "$work/current"/*/; do
        [ -d "$dir" ] || continue
        name=$(basename "$dir")
        if [ -f "$dir/build.json" ] && [ "$name" != "$tag" ]; then
            cp -R "$work/current/$name" "$work/site/$name"
        fi
    done
    cp -R "$folder" "$work/site/$tag"

    python3 "$scripts/pages.py" index --site "$work/site" --title "$title" --keep-branch-builds "$keep"

    git -C "$work/site" init -q
    git -C "$work/site" symbolic-ref HEAD refs/heads/gh-pages
    # --force: a global .gitignore with *.ipa would otherwise leave the IPAs out.
    git -C "$work/site" add -A --force
    git -C "$work/site" \
        -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -q -m "Publish $tag"

    if git -C "$work/site" push -q --force-with-lease="refs/heads/gh-pages:$lease" "$remote" HEAD:refs/heads/gh-pages; then
        echo "Published $tag to gh-pages ($(git -C "$work/site" rev-parse --short HEAD))."
        rm -rf "$work"
        exit 0
    fi

    rm -rf "$work"
    if [ "$attempt" -lt "$attempts" ]; then
        delay=$((attempt * 5 + RANDOM % 5))
        echo "gh-pages changed while publishing (another build?): trying again in ${delay}s." >&2
        sleep "$delay"
    fi
done

echo "::error::Could not publish to gh-pages after $attempts attempts." >&2
exit 1
