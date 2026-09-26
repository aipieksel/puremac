# Local build and installation

Run from the repository root on macOS with Command Line Tools, Python 3, and
network access for the first Sparkle download:

```sh
./script/build_and_run.sh --install
```

This compiles every production Swift source with optimization for the current
Mac's architecture and a macOS 13 deployment target. It bundles Sparkle 2.9.4,
checks the downloaded archive against the recorded SHA-256, copies translations,
generates the app icon, resolves Info.plist values from project.yml, signs the
app, and creates a ZIP. It does not invoke the upstream release publisher.

The script signs ad-hoc (`-`) unless `PUREMAC_SIGN_IDENTITY` is set to an
identity you supply. It does not search the keychain for a personal Apple
Development certificate. Keeping the same explicit identity and bundle ID
supports retaining macOS permissions across rebuilds; permission grants remain
controlled by macOS.

`--install` finishes building before stopping PureMac, preserves the previous
`/Applications/PureMac.app` in the build directory, installs the replacement,
and launches it. Settings and application data are not removed. To restore,
quit PureMac, move the replacement out of Applications, then copy the saved
`Previous-PureMac.app` back as `/Applications/PureMac.app`.

- `--build`: build and package without stopping or launching an app.
- `--verify` (default): build, stop the running PureMac, launch the workspace
  bundle, and check that the process remains running after three seconds.
- The Codex Run action uses `--verify`; it does not update Applications.

Outputs and build logs are under ignored `_work/local-app/build.*` directories.
`_work/local-app/latest-build.txt` identifies the latest successful package.
Each build records production source hashes in `source-hashes.json`.

This is a local Command Line Tools build, not an Xcode archive or notarized
distribution. The icon is generated with iconutil; the unused AccentColor
asset catalog is not compiled. A process check proves launch, not interactive
acceptance. Use the Xcode workflow for complete asset processing, XCTest, and
release distribution once Xcode is installed.
