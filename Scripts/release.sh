#!/bin/bash
# Publishes a release and points the Homebrew cask at it.
#   GH_TOKEN=$(gh auth token --user scr2em) Scripts/release.sh 0.2.0
#
# Builds a universal, ad-hoc signed app, commits the version bump and cask update, tags, pushes,
# and uploads the zip to GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version>}"
TAG="v$VERSION"
REPO="scr2em/screenshotter"
ZIP="build/Screenshotter-$VERSION-universal.zip"
CASK="Casks/screenshotter.rb"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Commit or stash your changes first." >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    Resources/Info.plist

# Ad-hoc signed: the release must not carry anyone's personal signing certificate.
SIGN_IDENTITY=- Scripts/build_app.sh --universal

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Screenshotter.app "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"

perl -pi -e "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" "$CASK"

git add Resources/Info.plist "$CASK"
git commit -m "Release $TAG"
git tag "$TAG"
git push origin HEAD "$TAG"

gh release create "$TAG" "$ZIP" \
    --repo "$REPO" \
    --title "Screenshotter $VERSION" \
    --notes "Install with Homebrew:

\`\`\`sh
brew tap scr2em/screenshotter https://github.com/scr2em/screenshotter
brew install --cask screenshotter
\`\`\`

The app is not notarized by Apple. See the README for the one-time approval step."

echo "Released $TAG ($SHA256)"
