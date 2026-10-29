# OpenTubeX Arch repository

This repository publishes signed OpenTubeX packages for Arch Linux and Arch
Linux ARM at [arch.opentubex.org](https://arch.opentubex.org). It supports
`x86_64` and `aarch64` systems.

## Install OpenTubeX

Download the repository signing key and check its fingerprint:

```sh
wget -O opentubex.asc https://arch.opentubex.org/opentubex.asc
gpg --show-keys --fingerprint opentubex.asc
```

It must match:

```text
4A60 0616 2524 0FB5 6569  221B 4672 DA44 5C55 F193
```

Import and trust the key:

```sh
sudo pacman-key --add opentubex.asc
sudo pacman-key --lsign-key 4A60061625240FB56569221B4672DA445C55F193
```

Add the repository:

```sh
grep -qxF '[opentubex]' /etc/pacman.conf || sudo tee -a /etc/pacman.conf >/dev/null <<'REPO'

[opentubex]
SigLevel = Required DatabaseRequired
Server = https://arch.opentubex.org/$repo/$arch
REPO
```

Install OpenTubeX, or update it with the rest of your system:

```sh
sudo pacman -Syu opentubex
```

Development snapshots are available through the opt-in `[opentubex-nightly]`
repository. Use the same signing key and add it instead of `[opentubex]`.
Stable and nightly packages are indexed separately, and the nightly repository
also receives stable releases.

## How publishing works

After an OpenTubeX stable or nightly release finishes uploading its packages,
the application repository sends a repository dispatch containing the exact
release tag. The publish workflow then:

1. downloads the latest stable and nightly `amd64` and `arm64` `.deb` assets;
2. repackages them with `packaging/PKGBUILD` as `x86_64` and `aarch64` pacman
   packages, reusing packages already published at the same version;
3. signs the packages and creates signed `opentubex` and `opentubex-nightly`
   databases;
4. deploys the static repository to GitHub Pages.

Nightly packages use versions such as `0.37.0.nightly.2527` for tag
`v0.37.0-nightly-2527`. Nightlies are built after the release they are
numbered after, so pacman sorts them between `0.37.0` and `0.38.0`.

Published packages are reused so their files and signatures stay identical in
pacman caches. Increment `pkgrel` in `packaging/PKGBUILD` when a packaging
change must reach the current version.

Each run publishes the newest stable and nightly releases, so a replayed or
manual run cannot replace a newer package. The requested tag only matters when
the release list does not include it yet. A stable release replaces the nightly
package only when its version is newer than the release the nightly follows.
The workflow can also be run manually, with or without a release tag.

## Maintainer setup

1. Create a dedicated, passphrase-protected GPG key for this repository.
2. Add its ASCII-armored private key as the `ARCH_GPG_PRIVATE_KEY` repository
   secret and its passphrase as `ARCH_GPG_PASSPHRASE`.
3. In **Settings → Pages**, select **GitHub Actions** as the source and configure
   `arch.opentubex.org` as the custom domain.
4. Add a DNS `CNAME` record from `arch.opentubex.org` to
   `opentubex.github.io`.
5. Run the **Publish Arch repository** workflow once with a stable release tag.

The OpenTubeX application repository uses its existing `PUSH_TOKEN` secret to
send the cross-repository dispatch. That token needs write access to this
repository.

The signing key expires on 2029-10-28. Extend it before then and ask users to
repeat the `pacman-key --add` step. To rotate the signing key, publish the new
public key and fingerprint out-of-band before replacing the secrets. Existing
installations trust only the key they already signed locally.
