#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @file
# Builds a Hugo site hosted on a Cloudflare Worker.
#
# The Cloudflare Worker automatically installs Node.js dependencies.
#
# Photos are not stored in this repo. Before the Hugo build runs, this
# script syncs them down from a Cloudflare R2 bucket into content/ and
# assets/images/, mirroring the same relative paths those folders would
# otherwise have held. Requires four environment variables to be set on
# the Worker's build configuration (Settings > Build > Environment
# variables, not wrangler.toml, since these are secrets):
#
#   CF_R2_ACCOUNT_ID
#   CF_R2_ACCESS_KEY_ID
#   CF_R2_SECRET_ACCESS_KEY
#   CF_R2_BUCKET
#
# If those aren't set (e.g. a future local run of this script), the sync
# step is skipped and the build proceeds against whatever is already on
# disk.
#------------------------------------------------------------------------------

# Exit on error, undefined variables, or pipe failures
set -euo pipefail

build_temp_dir=""

# Perform cleanup
cleanup() {
  if [[ -n "${build_temp_dir:-}" && -d "${build_temp_dir}" ]]; then
    rm -rf "${build_temp_dir}"
  fi
}

# Register the cleanup trap
trap cleanup EXIT SIGINT SIGTERM

main() {
  # Define tool versions
  DART_SASS_VERSION=1.99.0
  GO_VERSION=1.26.2
  HUGO_VERSION=0.161.1
  NODE_VERSION=24.15.0
  RCLONE_VERSION=1.74.1

  # Set the build timezone
  export TZ=Europe/Oslo

  # Create and move into a temporary directory for downloads
  build_temp_dir=$(mktemp -d)
  pushd "${build_temp_dir}" > /dev/null

  # Create the local tools directory
  mkdir -p "${HOME}/.local"

  # Install Dart Sass
  echo "Installing Dart Sass ${DART_SASS_VERSION}..."
  curl -sLJO "https://github.com/sass/dart-sass/releases/download/${DART_SASS_VERSION}/dart-sass-${DART_SASS_VERSION}-linux-x64.tar.gz"
  tar -C "${HOME}/.local" -xf "dart-sass-${DART_SASS_VERSION}-linux-x64.tar.gz"
  export PATH="${HOME}/.local/dart-sass:${PATH}"

  # Install Go
  echo "Installing Go ${GO_VERSION}..."
  curl -sLJO "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  tar -C "${HOME}/.local" -xf "go${GO_VERSION}.linux-amd64.tar.gz"
  export PATH="${HOME}/.local/go/bin:${PATH}"

  # Install Hugo
  echo "Installing Hugo ${HUGO_VERSION}..."
  curl -sLJO "https://github.com/gohugoio/hugo/releases/download/v${HUGO_VERSION}/hugo_${HUGO_VERSION}_linux-amd64.tar.gz"
  mkdir -p "${HOME}/.local/hugo"
  tar -C "${HOME}/.local/hugo" -xf "hugo_${HUGO_VERSION}_linux-amd64.tar.gz"
  export PATH="${HOME}/.local/hugo:${PATH}"

  # Install Node.js
  echo "Installing Node.js ${NODE_VERSION}..."
  curl -sLJO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
  tar -C "${HOME}/.local" -xf "node-v${NODE_VERSION}-linux-x64.tar.xz"
  export PATH="${HOME}/.local/node-v${NODE_VERSION}-linux-x64/bin:${PATH}"

  # Install rclone (built from source via Go, so no zip/unzip dependency
  # on the build image — we already have Go on PATH for Hugo modules)
  echo "Installing rclone v${RCLONE_VERSION}..."
  GOBIN="${HOME}/.local/rclone" go install "github.com/rclone/rclone@v${RCLONE_VERSION}"
  export PATH="${HOME}/.local/rclone:${PATH}"

  # Return to the project root
  popd > /dev/null

  # Verify installations
  echo "Verifying installations..."
  echo Dart Sass: "$(sass --version)"
  echo Go: "$(go version)"
  echo Hugo: "$(hugo version)"
  echo Node.js: "$(node --version)"
  echo rclone: "$(rclone version | head -1)"

  # Configure Git
  echo "Configuring Git..."
  git config core.quotepath false
  if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    git fetch --unshallow
  fi

  # Sync photos down from R2 (source of truth for image binaries, so
  # they never live in this git repo). Skips cleanly if credentials
  # aren't configured, so local/manual runs of this script don't fail.
  if [[ -n "${CF_R2_ACCOUNT_ID:-}" && -n "${CF_R2_ACCESS_KEY_ID:-}" && -n "${CF_R2_SECRET_ACCESS_KEY:-}" && -n "${CF_R2_BUCKET:-}" ]]; then
    echo "Syncing photos from R2 bucket ${CF_R2_BUCKET}..."
    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${CF_R2_ACCESS_KEY_ID}"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${CF_R2_SECRET_ACCESS_KEY}"
    export RCLONE_CONFIG_R2_ENDPOINT="https://${CF_R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    export RCLONE_CONFIG_R2_ACL=private

    # "copy" (not "sync") so nothing already on disk — index.md, style.css,
    # shortcode calls — is ever deleted; this only ever adds/updates files
    # that exist in the bucket, at the same relative path they'd have had
    # if they were still committed to the repo.
    rclone copy "r2:${CF_R2_BUCKET}/content" content --create-empty-src-dirs
    rclone copy "r2:${CF_R2_BUCKET}/assets/images" assets/images --create-empty-src-dirs
  else
    echo "R2 credentials not set, skipping photo sync."
  fi

  # Build the site
  echo "Building the site..."
  hugo build --gc --minify
}

main "$@"