# Desktop updates

The desktop updater checks the latest stable GitHub release from
`sion3951/task_master`. Release builds embed their package version, so a freshly
installed release does not offer itself as an update. Prerelease tags remain
prereleases and are excluded from the stable update channel.

Every update release includes `update.json` and `update.json.sig`, alongside
the installers and remote helpers. The manifest lists the version, download
URL, byte size and SHA-256 of each supported asset, with its OS, architecture
and kind (`collector`, `sensors`, or installer format). Its raw UTF-8 bytes are
signed with Ed25519; `update.json.sig` contains the raw 64-byte signature. The app verifies
that signature against the public key embedded from
`assets/update-public-key.hex` before trusting the manifest, then verifies the
downloaded installer against its signed size and SHA-256.

The supported release assets are Debian and AppImage packages for Linux x64
and ARM64, macOS installer packages for Intel and Apple Silicon, and the
native Windows x64 and ARM64 installers.

Each installer contains only the payloads for its own OS and architecture.
Remote Install / fix fetches missing collectors and Windows sensor runtimes
from the signed manifest for the installed desktop's exact release version.
Downloaded helpers are checked against the signed size and SHA-256, and
cached for reuse. The first use of an uncached helper needs internet access;
matching cached helpers can be used offline. A development build needs a
published matching release before it can download remote helpers.

Collector release assets use `task_master-collector-<os>-<arch>`, with `os`
`linux`, `darwin`, or `windows`, and `arch` `amd64` or `arm64`. Windows sensor
assets are `task_master-windows-sensors-amd64.zip` and
`task_master-windows-sensors-arm64.zip`; each contains just its native runtime
at the archive root. Only the amd64 archive includes the pinned official PawnIO
driver installer. These names are stable inside each versioned GitHub release
directory.

The header's **Updates** button opens the update dialog, showing the installed
version and current status. **Automatic downloads** is enabled by default;
the setting is saved when changed. Automatic checking starts ten seconds
after launch and repeats every six hours while the app is running. **Check
now** checks immediately and downloads a verified newer release. **Update and
restart** installs the ready package and relaunches the app as the ordinary
user. **Close** or Escape dismisses the dialog.

To inspect the installed version or check and verify the latest signed update
without opening the desktop window:

```sh
task_master --version
task_master --check-updates
```

`--check-updates` reports the result and exits with a nonzero status on error.
It does not install the package; its temporary download is cleaned up on exit.
System-wide installations request administrator authorization through the
platform's normal installer or elevation prompt.
Development builds and manual installations cannot automatically determine
their package format; install a release package to enable the updater.

Windows downloads use the built-in Windows PowerShell/.NET HTTPS client;
curl is not required, including for uncached remote helper downloads. The
client uses Windows certificate trust and proxy settings, streams downloads
to disk with byte and time limits, and follows only HTTPS redirects. The
signed manifest and package checksum checks still apply before installation.

Linux AppImages include a native curl executable and its private runtime
libraries; the updater uses that copy instead of requiring curl to be
installed on the host. HTTPS certificate verification uses the host's trusted
CA certificate store, which must be present and current. Debian packages
declare curl and CA certificates as runtime dependencies.

## Release signing setup

A dedicated update-signing key was generated for this repository. Its private
PEM is stored locally at `.update-signing/private.pem` with restricted
permissions and is excluded from Git. Keep a secure backup of this key;
normal build cleanup leaves it intact. The public key is checked in; the
private key must never be committed, attached to a release, or included in
a desktop package.

Before the first updater-enabled release, set the GitHub repository Actions
secret `TASK_MASTER_UPDATE_PRIVATE_KEY` to the complete contents of that PEM
file, including its header, footer and actual newlines. With the GitHub CLI,
an authorized maintainer can set it without printing the key:

```sh
gh secret set TASK_MASTER_UPDATE_PRIVATE_KEY < .update-signing/private.pem
```

The release workflow fails if the secret is absent or if its public key does
not match the checked-in public key. All eight installers, six collectors
and two sensor archives must be present before the workflow signs the manifest. It creates or resumes a draft, uploads
all installers, helpers, checksums and signed metadata, then publishes the
release.
An upload failure leaves the release as a draft, so clients cannot discover
an incomplete update. A retry can resume that draft; an already published
release is never overwritten by the workflow. Stable tags become the latest
release; prerelease tags do not replace the latest stable release.

Tagged updater releases use SemVer, for example `v1.2.3` or
`v1.3.0-beta.1`. Updating `VERSION` keeps local builds at the intended version;
CI embeds the version resolved for its package build. For a local Linux build
of a different version, use `make release PACKAGE_VERSION=1.2.3`.

To sign an already built set of release installers and helpers locally:

```sh
python3 scripts/update-manifest.py --tag v1.2.3 --packages build/packages \
  --private-key .update-signing/private.pem
```

This command verifies the signing key, verifies its generated signature, and
writes both metadata assets only after the complete installer and helper set
is validated.

## Key rotation

Keep the same signing key across releases. Replacing the checked-in public
key without a migration would prevent installed copies from accepting newer
updates. A rotation needs a release signed by the old key that teaches the
client to trust the replacement key before switching release signing.
