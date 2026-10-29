#!/usr/bin/env bash

set -euo pipefail

stable_directory=${1:-release-files}
repository_directory=${2:-repository}
nightly_directory=${3:-}
# Reusing published packages keeps their bytes stable, so pacman caches and
# signatures stay valid when a version is republished.
published_url=${ARCH_PUBLISHED_URL:-}
packager=${ARCH_PACKAGER:-OpenTubeX contributors <info@opentubex.org>}

if [[ ! -d "$stable_directory" ]]; then
  printf 'Package directory does not exist: %s\n' "$stable_directory" >&2
  exit 1
fi

if [[ -z "$repository_directory" || "$repository_directory" == '/' || "$repository_directory" == '.' ]]; then
  printf 'Unsafe repository directory: %s\n' "$repository_directory" >&2
  exit 1
fi

: "${ARCH_GPG_KEY_ID:?ARCH_GPG_KEY_ID is required to sign the repository}"
: "${ARCH_GPG_PASSPHRASE:?ARCH_GPG_PASSPHRASE is required to sign the repository}"

project_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pkgrel=$(source "$project_directory/packaging/PKGBUILD" && printf '%s' "$pkgrel")
work_directory=$(mktemp -d)
trap 'rm -rf -- "$work_directory"' EXIT
declare -A built_packages=()

rm -rf -- "$repository_directory"
mkdir -p "$repository_directory"

sign() {
  gpg --batch --yes --pinentry-mode loopback \
    --passphrase "$ARCH_GPG_PASSPHRASE" \
    --local-user "$ARCH_GPG_KEY_ID" \
    --detach-sign --output "$1.sig" "$1"
}

download_published_package() {
  local url=$1
  local destination=$2

  [[ -n "$published_url" ]] || return 1
  if wget --quiet --output-document="$destination" "$url" \
    && wget --quiet --output-document="$destination.sig" "$url.sig" \
    && gpg --batch --quiet --verify "$destination.sig" "$destination" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$destination" "$destination.sig"
  return 1
}

build_package() {
  local deb=$1
  local pkgver=$2
  local architecture=$3
  local destination=$4
  local build_directory="$work_directory/$architecture-$pkgver"

  mkdir -p "$build_directory/out"
  cp "$project_directory/packaging/PKGBUILD" "$build_directory/"
  sed -i -E "s/^pkgver=.*/pkgver=$pkgver/" "$build_directory/PKGBUILD"
  cp "$deb" "$build_directory/opentubex.deb"
  sed -E "s/^CARCH=.*/CARCH=\"$architecture\"/" /etc/makepkg.conf > "$build_directory/makepkg.conf"
  # Smaller packages keep the Pages site and its bandwidth within limits.
  printf 'COMPRESSZST=(zstd -c -T0 -19 -)\n' >> "$build_directory/makepkg.conf"

  (
    cd "$build_directory"
    PKGDEST="$build_directory/out" PACKAGER="$packager" \
      makepkg --config "$build_directory/makepkg.conf" --nodeps --clean --noconfirm
  )
  mv "$build_directory/out/$(basename "$destination")" "$destination"
  rm -rf -- "$build_directory"
  sign "$destination"
}

publish_repository() {
  local source_directory=$1
  local repository=$2
  local deb control package_name deb_architecture version architecture pkgver
  local package_file destination target_directory link
  local -a debs target_directories

  mapfile -t debs < <(find "$source_directory" -maxdepth 1 -type f -name '*.deb' -print | sort)
  if (( ${#debs[@]} == 0 )); then
    printf 'No Debian packages found in %s\n' "$source_directory" >&2
    exit 1
  fi

  target_directories=()
  for deb in "${debs[@]}"; do
    control=$(bsdtar -xOf "$deb" 'control.tar.*' | bsdtar -xOf - ./control)
    package_name=$(awk -F ': ' '$1 == "Package" { print $2 }' <<< "$control")
    deb_architecture=$(awk -F ': ' '$1 == "Architecture" { print $2 }' <<< "$control")
    version=$(awk -F ': ' '$1 == "Version" { print $2 }' <<< "$control")

    if [[ "$package_name" != 'opentubex' ]]; then
      printf 'Unexpected package name %s in %s\n' "$package_name" "$deb" >&2
      exit 1
    fi

    case "$deb_architecture" in
      amd64) architecture=x86_64 ;;
      arm64) architecture=aarch64 ;;
      *)
        printf 'Unsupported Debian architecture %s in %s\n' "$deb_architecture" "$deb" >&2
        exit 1
        ;;
    esac

    # Nightlies follow the release they are numbered after, and pacman sorts
    # 0.37.0.nightly.2527 between the 0.37.0 and 0.38.0 releases.
    if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(~nightly~([0-9]+))?$ ]]; then
      pkgver="${BASH_REMATCH[1]}${BASH_REMATCH[3]:+.nightly.${BASH_REMATCH[3]}}"
    else
      printf 'Unexpected package version %s in %s\n' "$version" "$deb" >&2
      exit 1
    fi

    package_file="opentubex-$pkgver-$pkgrel-$architecture.pkg.tar.zst"
    target_directory="$repository_directory/$repository/$architecture"
    destination="$target_directory/$package_file"
    mkdir -p "$target_directory"
    target_directories+=("$target_directory")

    if [[ -n "${built_packages[$package_file]:-}" ]]; then
      cp "${built_packages[$package_file]}" "${built_packages[$package_file]}.sig" "$target_directory/"
    elif download_published_package "$published_url/$repository/$architecture/$package_file" "$destination"; then
      printf 'Reusing published %s\n' "$package_file"
    else
      build_package "$deb" "$pkgver" "$architecture" "$destination"
    fi
    built_packages[$package_file]=$destination

    repo-add --quiet "$target_directory/$repository.db.tar.gz" "$destination"
  done

  mapfile -t target_directories < <(printf '%s\n' "${target_directories[@]}" | sort -u)
  for target_directory in "${target_directories[@]}"; do
    rm -f -- "$target_directory"/*.old
    # GitHub Pages cannot serve symbolic links.
    for link in "$target_directory/$repository.db" "$target_directory/$repository.files"; do
      cp --remove-destination "$link.tar.gz" "$link"
      sign "$link"
      sign "$link.tar.gz"
    done
  done
}

publish_repository "$stable_directory" opentubex
if [[ -n "$nightly_directory" && -d "$nightly_directory" ]]; then
  publish_repository "$nightly_directory" opentubex-nightly
fi

gpg --batch --armor --export "$ARCH_GPG_KEY_ID" > "$repository_directory/opentubex.asc"
cp \
  "$project_directory/static/CNAME" \
  "$project_directory/static/code-blocks.js" \
  "$project_directory/static/favicon.ico" \
  "$project_directory/static/favicon.svg" \
  "$project_directory/static/index.html" \
  "$project_directory/static/og.png" \
  "$project_directory/static/style.css" \
  "$repository_directory/"
touch "$repository_directory/.nojekyll"
