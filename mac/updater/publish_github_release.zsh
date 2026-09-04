#!/bin/zsh
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
    print -u2 "usage: $0 OWNER/REPOSITORY RELEASE_TAG [publish-TAG.txt]"
    exit 64
fi

script_dir="${0:A:h}"
repo_dir="${script_dir:h:h}"
github_repository="$1"
release_tag="$2"
manifest="${3:-${repo_dir}/dist/updates/publish-${release_tag}.txt}"

if [[ "${github_repository}" != */* || "${release_tag}" == */* ]]; then
    print -u2 "Invalid repository or release tag."
    exit 64
fi
if [[ ! -f "${manifest}" ]]; then
    print -u2 "Publish manifest is missing: ${manifest}"
    exit 1
fi
if ! command -v gh >/dev/null; then
    print -u2 "GitHub CLI (gh) is required."
    exit 1
fi

visibility="$(gh repo view "${github_repository}" --json visibility --jq .visibility)"
if [[ "${visibility}" != PUBLIC ]]; then
    print -u2 "The updater feed must be hosted in a public GitHub repository."
    exit 1
fi

if gh release view "${release_tag}" --repo "${github_repository}" >/dev/null 2>&1; then
    is_draft="$(gh release view "${release_tag}" --repo "${github_repository}" \
        --json isDraft --jq .isDraft)"
    if [[ "${is_draft}" != true ]]; then
        print -u2 "Release ${release_tag} already exists and is not a draft; refusing partial publication."
        exit 1
    fi
else
    gh release create "${release_tag}" --repo "${github_repository}" \
        --draft --title "jgalbs cod4 ${release_tag}" --generate-notes
fi

typeset -a assets
while IFS= read -r asset; do
    [[ -n "${asset}" ]] || continue
    if [[ ! -f "${asset}" ]]; then
        print -u2 "Manifest asset is missing: ${asset}"
        exit 1
    fi
    assets+=("${asset}")
done <"${manifest}"

# Keep the release draft until all authenticated artifacts and the signed feed
# are present. This prevents releases/latest from exposing a partial update.
gh release upload "${release_tag}" "${assets[@]}" \
    --repo "${github_repository}" --clobber

remote_assets="$(gh release view "${release_tag}" --repo "${github_repository}" \
    --json assets --jq '.assets[].name')"
for asset in "${assets[@]}"; do
    if ! grep -Fxq "${asset:t}" <<<"${remote_assets}"; then
        print -u2 "GitHub did not report uploaded asset ${asset:t}."
        exit 1
    fi
done

print "Draft release is complete and verified:"
gh release view "${release_tag}" --repo "${github_repository}" --json url --jq .url
print "Publish only after installing from the signed feed in a release-candidate test."
print "Command: gh release edit ${release_tag} --repo ${github_repository} --draft=false --latest"
