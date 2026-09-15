# MLX Menu Package Distribution

The distributable is an Apple-silicon, macOS 14+ flat installer package. It installs one
application bundle at `/Applications/MLX Menu.app`. Python runtimes, model weights, user
settings, cached models, logs, and job artifacts are outside the payload.

## Build and verify locally

```bash
./scripts/build-package.sh
./scripts/verify-package.sh dist/MLX-Menu-3.1.1.5.pkg
(cd dist && shasum -a 256 -c MLX-Menu-3.1.1.5.pkg.sha256)
```

`build-package.sh` performs a release build, creates the bundle through
`build-app.sh`, builds a non-relocatable version-checked component, wraps it in a product
archive, expands the result, and verifies the architecture/OS gates, identifier,
resources, plist, versions, and nested code signature. The package has no install scripts
and only targets the local system domain.

`verify-package.sh` requires the payload's `CFBundleShortVersionString.CFBundleVersion` to
match the versions recorded in `PackageInfo` and the Distribution `pkg-ref`. Set
`EXPECTED_VERSION` to also pin the release being verified, which rejects a stale or
renamed package that is internally consistent:

```bash
EXPECTED_VERSION=3.1.1.5 ./scripts/verify-package.sh dist/MLX-Menu-3.1.1.5.pkg
```

An unsigned local package is a verification artifact, not a frictionless team release.
Another Mac will normally block it with Gatekeeper.

## One-time signing setup

A trusted team release requires both certificates in the login keychain:

- `Developer ID Application: …` for `MLX Menu.app`
- `Developer ID Installer: …` for the `.pkg`

Store App Store Connect notarization credentials without putting secrets in this repo:

```bash
xcrun notarytool store-credentials mlx-menu-notary \
  --apple-id '<apple-id>' \
  --team-id '<team-id>'
```

`notarytool` securely prompts for the app-specific password and stores the profile in
Keychain. Do not pass or commit credentials through package scripts, command arguments,
shell history, logs, or environment files.

## Signed and notarized release

```bash
CODESIGN_IDENTITY='Developer ID Application: …' \
INSTALLER_IDENTITY='Developer ID Installer: …' \
NOTARY_PROFILE='mlx-menu-notary' \
./scripts/build-package.sh
```

When `NOTARY_PROFILE` is set, the build fails closed unless both signing identities are
also supplied. It submits the final package with `notarytool --wait` and staples the
accepted ticket. Before sharing:

```bash
REQUIRE_SIGNED=1 EXPECTED_VERSION=3.1.1.5 ./scripts/verify-package.sh dist/MLX-Menu-3.1.1.5.pkg
spctl --assess --type install --verbose=4 dist/MLX-Menu-3.1.1.5.pkg
xcrun stapler validate dist/MLX-Menu-3.1.1.5.pkg
(cd dist && shasum -a 256 -c MLX-Menu-3.1.1.5.pkg.sha256)
```

Share the `.pkg` and its `.sha256` through the team's approved file channel.

## Recipient setup

The installer requests administrator authorization because it writes to `/Applications`.
It does not run scripts, start the app, add a login item, download models, or modify a
user's shell configuration.

Install the backends needed by the intended modalities:

```bash
uv tool install mlx-lm
uv tool install mlx-vlm
uv tool install 'mlx-audio[server]'
```

Then open MLX Menu from Applications. Add it in **System Settings → General → Login
Items** if launch at login is desired. Model downloads remain explicit in the app.

## Upgrade and rollback

The component is non-relocatable, has a strict identifier, asks Installer to close a
running copy before replacement, and uses version-checked upgrade semantics. The semantic
and build versions live in `packaging/version.env`; the receipt version combines both. Installing a newer package replaces `/Applications/MLX Menu.app`
without changing model caches or application support data. Do not install a package with
a lower `CFBundleShortVersionString` as a rollback; build the intended rollback source as
a new release version so Installer and persisted-data migrations stay monotonic.

The older source installer uses `~/Applications/MLX Menu.app`. Remove that copy and its
`~/Library/LaunchAgents/local.mccully.mlx-menu.plist` before adopting the system package
to avoid duplicate applications or login launches. `scripts/uninstall.sh` removes only
the older per-user installation.

## Clean-Mac acceptance checklist

Test the final signed artifact on a Mac that did not build it:

1. Confirm Apple silicon and macOS 14 or newer.
2. Verify the published SHA-256 checksum.
3. Double-click installation completes without a Gatekeeper override.
4. Confirm exactly one app at `/Applications/MLX Menu.app`.
5. Open the app and confirm no model or runtime is downloaded implicitly.
6. With `mlx-lm` installed and a compatible cached model, start Manual mode and verify
   `/health`, `/v1/models`, one non-streaming completion, and one SSE completion on
   `127.0.0.1:8081`.
7. Stop the server and confirm the worker exits and memory is released.
8. Install the same package again and then a newer version; confirm settings and caches
   survive and there is no duplicate app.
9. Confirm the package does not create a LaunchAgent or listener before the user opens it.

A local payload expansion is strong structural evidence, but it does not replace this
clean-Mac Gatekeeper, authorization, first-launch, and upgrade test.
