#!/usr/bin/env bash
# 发布 libfx Swift 包：重编 CFx.xcframework，上传到 GitHub Release，把地址和校验和写进 Package.swift 并打 tag。
# 用法：swift/scripts/release.sh 0.4.5-swift.2
set -euo pipefail
version="${1:?usage: release.sh <version>, e.g. 0.4.5-swift.2}"
tag="v$version"
repo="what1f/fx"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean" >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists" >&2
  exit 1
fi
branch="$(git branch --show-current)"

swift/scripts/build-xcframework.sh

task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
zip_path="$task_tmp/CFx.xcframework.zip"
(cd swift/Artifacts && ditto -c -k --keepParent CFx.xcframework "$zip_path")
checksum="$(swift package compute-checksum "$zip_path")"
url="https://github.com/$repo/releases/download/$tag/CFx.xcframework.zip"

sed -i '' -E "s#^let cfxReleaseURL = \".*\"#let cfxReleaseURL = \"$url\"#; s#^let cfxReleaseChecksum = \".*\"#let cfxReleaseChecksum = \"$checksum\"#" Package.swift
git add Package.swift
git commit -m "发布 libfx Swift $version"
git tag "$tag"
git push origin "$branch" "$tag"
gh release create "$tag" "$zip_path" --repo "$repo" --title "libfx Swift $version" --notes "CFx.xcframework for SwiftPM binary target. checksum: $checksum"
echo "Released $tag"
