# Release signing configuration

Use your own Apple Developer credentials when preparing a signed release. No signing key, certificate password, team ID, App Store Connect issuer, or API key is distributed with this source.

The release workflow expects protected CI values for `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY`, and any configured Sparkle signing secret. Inspect the current workflow for its exact variable names before configuring it.

Export a certificate and its matching private key from your own developer account to a private temporary directory, set the corresponding CI secret through your repository settings, and securely remove the temporary export afterward. Keep `.p12`, `.p8`, `.pem`, passwords and key material outside Git. No credentials should be pasted into this document or a bug report.

Local build-only verification can use ad-hoc signing:

```sh
PUREMAC_SIGN_IDENTITY=- ./script/build_and_run.sh --build
```

This does not launch or install the app, notarize it, or publish a release. A signed distribution requires your own account and explicit release authorization. See [local build documentation](../docs/LOCAL-BUILD.md).

For the local release script, set `PUREMAC_TEAM_ID` and `PUREMAC_SIGN_IDENTITY`, and supply your own notary keychain profile. Optional tap updates use the repository variable `HOMEBREW_TAP_REPOSITORY` (`owner/homebrew-tap`) and its scoped `HOMEBREW_TAP_DEPLOY_KEY` secret. Without both values, the tap step is skipped. Release URLs follow the repository running the workflow. These release scripts contact Apple and can upload artifacts; they are separate from the local build-only command.
