# Installing, signing and releasing SuperNotch

This guide is for the **repository owner**. End users only need the one-liner in the [README](../README.md).

Contents: [1. Why a certificate](#1-why-a-certificate) - [2. Create it](#2-create-the-certificate-once-on-your-mac) -
[3. Store the secrets](#3-store-it-in-github) - [4. Verify](#4-verify-that-ci-uses-it) -
[5. Release](#5-publish-a-release) - [6. Installing as a user](#6-installing-as-a-user) -
[7. Local builds](#7-local-builds) - [8. Rotating or losing the certificate](#8-rotating-or-losing-the-certificate) -
[9. Troubleshooting](#9-troubleshooting)

## 1. Why a certificate

There is no paid Apple Developer account, so the app is never notarized and Gatekeeper always asks on the first
launch (see [section 6](#6-installing-as-a-user)). That cannot be fixed with a self-signed certificate.

What a **stable self-signed certificate** does fix: macOS ties the Automation (Spotify) and Accessibility grants
to the app's *designated requirement*.

| Signature | Designated requirement | After an update |
|---|---|---|
| ad-hoc (`-`, the fallback) | `cdhash H"..."` (changes with every build) | grants silently reset |
| stable certificate | `identifier "io.github.snakez3101.supernotch" and certificate leaf = H"..."` | grants survive |

So: create one certificate, keep it in GitHub secrets, and every CI build and release is signed with it.
Without the secrets CI still works and signs ad-hoc.

## 2. Create the certificate (once, on your Mac)

```bash
git clone https://github.com/snakez3101/supernotch.git && cd supernotch
Scripts/make_selfsigned_cert.sh
```

The script (needs only `openssl`, present on macOS):

- creates a 10-year self-signed certificate "SuperNotch Self-Signed" with the *Code Signing* extended key usage;
- exports a PKCS12 (`.p12`) that macOS `security import` can read (legacy encryption; OpenSSL 3's default AES
  PKCS12 is rejected by macOS);
- writes everything to `./supernotch-signing/` (mode 700): `SuperNotch-Self-Signed.p12`, `p12.base64`,
  `p12.password`, `identity.name`, `cert.pem`;
- prints the exact commands for the next step, with the generated password filled in.

Options: `--import` (also import it into your login keychain and trust it for code signing; only needed if you
want to sign local builds with it), `--name`, `--days`, `--out`, `--password`, `--repo`, `--force`. Run
`Scripts/make_selfsigned_cert.sh --help`.

**Back up `supernotch-signing/`** in a password manager. It contains your signing key. Never commit it (it is
git-ignored) and delete the folder from disk once the secrets are stored and backed up.

## 3. Store it in GitHub

Three repository secrets (Actions secrets, **not** variables):

| Secret | Content |
|---|---|
| `SIGNING_P12_BASE64` | the content of `p12.base64` (the `.p12`, base64, one line) |
| `SIGNING_P12_PASSWORD` | the content of `p12.password` |
| `SIGNING_IDENTITY` | `SuperNotch Self-Signed` (content of `identity.name`; optional, used to pick the identity if the `.p12` holds several) |

**With the GitHub CLI** (`gh auth login` first):

```bash
gh secret set SIGNING_P12_BASE64   --repo snakez3101/supernotch < supernotch-signing/p12.base64
gh secret set SIGNING_P12_PASSWORD --repo snakez3101/supernotch < supernotch-signing/p12.password
gh secret set SIGNING_IDENTITY     --repo snakez3101/supernotch < supernotch-signing/identity.name
```

**Or in the browser:**

1. Open <https://github.com/snakez3101/supernotch/settings/secrets/actions>.
2. Click **New repository secret**.
3. Name `SIGNING_P12_BASE64`; value: paste the output of `pbcopy < supernotch-signing/p12.base64` (or open the
   file and copy the single line). **Add secret.**
4. Repeat for `SIGNING_P12_PASSWORD` (the password printed by the script) and `SIGNING_IDENTITY`.

Pull requests from forks never see these secrets, so they are built ad-hoc; that is expected.

## 4. Verify that CI uses it

Push any commit (or run the *CI* workflow manually: Actions > CI > *Run workflow*). In the **macOS** job:

- The step *Import signing certificate (optional)* ends with
  `Stable signing identity ready.` and the run summary lists
  `Signing: stable self-signed identity SuperNotch Self-Signed`.
- The step *Package (sign, zip, dmg) and smoke test* prints
  `designated requirement: identifier "io.github.snakez3101.supernotch" and certificate leaf = H"..."` and
  `ok stable identity: grants survive updates`. A `cdhash` there means the build fell back to ad-hoc; the import
  step then printed a `::warning::` with the reason.

The CI artifact is the `SuperNotch-<version>-arm64.zip` of the run (Actions > run > *Artifacts*).

## 5. Publish a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The *Release* workflow (`.github/workflows/release.yml`) builds on `macos-26`, runs the tests, signs (a
configured-but-broken certificate **fails** the release instead of silently shipping ad-hoc), runs the smoke
test, and creates the GitHub release with `SuperNotch-1.0.0-arm64.zip`, `SuperNotch-1.0.0.dmg`,
`SHA256SUMS.txt` and generated release notes. Tags with a suffix (`v1.1.0-rc.1`) become pre-releases.
Re-pushing a tag whose release exists replaces the assets.

`Scripts/install.sh` (the one-liner) always installs the latest non-pre-release. The repository must be
**public** for the one-liner and the release downloads to work without authentication (it also gives free,
unlimited macOS runner minutes).

## 6. Installing as a user

**One-liner** (no Gatekeeper prompt, because files downloaded with `curl` carry no quarantine flag and the
script clears it anyway):

```bash
curl -fsSL https://raw.githubusercontent.com/snakez3101/supernotch/main/Scripts/install.sh | bash
```

**DMG / zip from a browser** (quarantined, so Gatekeeper blocks the first launch):

1. Drag SuperNotch to Applications and open it. macOS says it cannot verify the app: click **Done**.
2. **System Settings > Privacy & Security**, scroll down to **Security**, click **Open Anyway** next to
   "SuperNotch was blocked", authenticate.
3. Or run `xattr -dr com.apple.quarantine /Applications/SuperNotch.app` once.

Right-click > Open no longer works on macOS 15 and later. Keep the app in `/Applications`: TCC grants are keyed
on the bundle id **and** the path.

## 7. Local builds

```bash
Scripts/package_app.sh                       # ad-hoc signed, dist/SuperNotch.app + zip + dmg
Scripts/package_app.sh --smoke-test          # plus a headless launch check
VERSION=1.0.0-local Scripts/package_app.sh   # choose the version string
```

To sign local builds with the stable identity, import it into your login keychain (the certificate script does it
with `--import`; or manually):

```bash
security import supernotch-signing/SuperNotch-Self-Signed.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "$(cat supernotch-signing/p12.password)" -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db supernotch-signing/cert.pem
security find-identity -v -p codesigning        # "SuperNotch Self-Signed" must be listed
SIGN_IDENTITY="SuperNotch Self-Signed" Scripts/package_app.sh
```

Check what a build is signed with: `codesign -d -r- dist/SuperNotch.app`.

## 8. Rotating or losing the certificate

A new certificate has a different leaf hash, so users have to grant Automation/Accessibility once more after the
first update signed with it. Reset stale entries so macOS asks again:

```bash
tccutil reset AppleEvents io.github.snakez3101.supernotch
tccutil reset Accessibility io.github.snakez3101.supernotch
```

Create a new certificate with `Scripts/make_selfsigned_cert.sh --force`, update the three secrets, and mention it
in the release notes. The certificate is valid for 10 years by default.

## 9. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| CI summary says `Signing: ad-hoc (no SIGNING_P12_BASE64 secret)` | The secrets are not set (or the run is from a fork). Do [section 3](#3-store-it-in-github). |
| `security import failed` in the import step | Wrong `SIGNING_P12_PASSWORD`, or the `.p12` was created with OpenSSL 3 without `-legacy`. Recreate it with `Scripts/make_selfsigned_cert.sh`, which handles this. |
| `the imported identity ... cannot sign on this runner` | An untrusted self-signed identity refused to sign headlessly even after the trust step. CI falls back to ad-hoc (releases fail). Open an issue with the step log. |
| `no identity found` locally | The certificate is not trusted for code signing. `security add-trusted-cert ...` from [section 7](#7-local-builds), or Keychain Access > the certificate > Trust > Code Signing: Always Trust. |
| macOS says the app is "damaged" or "can't be opened" | It is quarantined and not notarized: use the one-liner, or `xattr -dr com.apple.quarantine`, or **Open Anyway**. |
| Smoke test step fails | The app crashed at start-up or hung for more than 30 s. The step log has the output; run `dist/SuperNotch.app/Contents/MacOS/SuperNotch --smoke-test` locally. |
| macOS job fails at *Build* | The job summary lists the first 50 compiler errors and adds annotations; the full `build.log` is uploaded as the `macos-logs` artifact. |
| Xcode step fails: "No stable Xcode 26.x found" | The job is not running on `macos-26`, or the image dropped Xcode 26. |
| Grants (Spotify, Accessibility) reset after every update | The build was ad-hoc signed (`cdhash` in the log). Configure the certificate. |
| Hooks not firing | Settings > Claude shows the hook status. The helper lives at `~/Library/Application Support/SuperNotch/bin/supernotch-hook`; run it with `--version`. Set `SUPERNOTCH_HOOK_DEBUG=1` to log to `~/Library/Logs/SuperNotch/hook.log`. |
