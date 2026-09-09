#!/usr/bin/env bash
#
# Builds the release zip. CI runs this too, so what is verified on every pull
# request is the same artifact that gets published.
#
# The zip contains a top-level vanish_logger/ directory, so a server owner can
# unzip it straight into resources/.
set -euo pipefail

out="${1:-dist}"
name="vanish_logger"
staging="$out/$name"

rm -rf "$out"
mkdir -p "$staging"

# Only tracked files ship. An untracked spool, editor file or local server.cfg
# therefore cannot end up in a release even if one is sitting in the checkout.
git ls-files -z | while IFS= read -r -d '' file; do
  case "$file" in
    .github/* | tests/* | .gitignore) continue ;;
  esac
  mkdir -p "$staging/$(dirname "$file")"
  cp "$file" "$staging/$file"
done

(cd "$out" && zip -qr "$name.zip" "$name")
echo "built $out/$name.zip"
