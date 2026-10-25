#!/bin/bash
# Build the file window's editor page into Editor/dist/.
#
# dist/ is committed: `swift build` and scripts/package_app.sh must work without Node, so only a
# change to this page needs this script. Versions are pinned in package-lock.json and installed with
# `npm ci`, so the same lock builds the same bundle; BUILD.txt records what went into it.
set -euo pipefail
cd "$(dirname "$0")"

npm ci --ignore-scripts --no-audit --no-fund
mkdir -p dist
./node_modules/.bin/esbuild src/editor.js --bundle --minify --format=iife --target=safari16 \
  --legal-comments=none --outfile=dist/editor.js
cp src/index.html src/editor.css dist/

# The licences of what is bundled, beside it.
{
  for d in node_modules/@codemirror/* node_modules/@lezer/* node_modules/markdown-it node_modules/crelt \
           node_modules/style-mod node_modules/w3c-keyname node_modules/linkify-it node_modules/mdurl \
           node_modules/uc.micro node_modules/entities node_modules/punycode.js node_modules/argparse; do
    [ -f "$d/LICENSE" ] || continue
    echo "==== ${d#node_modules/} $(node -p "require('./$d/package.json').version")"
    cat "$d/LICENSE"
    echo
  done
} > dist/THIRD_PARTY_LICENSES.txt

{
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) with esbuild $(./node_modules/.bin/esbuild --version), node $(node --version)"
  node -e 'const l=require("./package-lock.json");for(const[k,v]of Object.entries(l.packages))if(k&&!v.dev)console.log(k.replace("node_modules/",""),v.version)'
  echo
  (cd dist && shasum -a 256 editor.js editor.css index.html)
} > dist/BUILD.txt

ls -l dist
