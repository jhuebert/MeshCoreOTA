# Releasing MeshCoreRepeaterManager

The release pipeline mirrors MeshChameleon's: manual dispatch, build number
reserved from a repository variable, everything else reproducible. Installs
are sideloaded APKs from GitHub Releases — there is no Play track yet.

## One-time setup

1. **Repository variable** `BUILD_NUMBER` — the shared version-code counter.
   Create it above any build you have installed (e.g. `1`). The release and
   test-build workflows reserve `+1` from it per run; never set it lower.

2. **App signing keystore** (PKCS12) — create one to sign what users install
   from GitHub Releases:

   ```sh
   keytool -genkeypair -v \
     -keystore meshcorepeatermanager-app-signing.p12 -storetype PKCS12 \
     -keyalg RSA -keysize 4096 -validity 10000 \
     -alias app-signing -storepass 'STORE_PASSWORD'
   ```

   Record the certificate fingerprint:

   ```sh
   keytool -list -v -keystore meshcorepeatermanager-app-signing.p12 -alias app-signing \
     | awk -F': ' '/SHA256:/ { print tolower($2); exit }'
   ```

   It must be stable for the app's lifetime — Android uses it to verify
   in-place updates. Keep the keystore file and its passwords outside the
   repository and back them up: losing them means existing installs can no
   longer be updated in place.

3. **`release` environment** — create it in repo settings → Environments;
   optionally require a reviewer. Add these **environment secrets**:

   | Secret | Notes |
   |---|---|
   | `APP_SIGNING_KEYSTORE_BASE64` | `base64 -w0 meshcorepeatermanager-app-signing.p12` |
   | `APP_SIGNING_KEYSTORE_PASSWORD` | store password |
   | `APP_SIGNING_KEY_ALIAS` | e.g. `app-signing` |
   | `APP_SIGNING_KEY_PASSWORD` | key password |

4. **Repository variable** `EXPECTED_APP_SIGNING_SHA256` — the certificate
   fingerprint from step 2 (lowercase hex, no colons). Used by the test-build
   workflow to verify it decoded the right key.

5. **`REPO_AUTOMATION_TOKEN` secret** (repo-level) — a token that can push
   `main` and create tags (Contents: write). The release workflow uses it to
   fast-forward `main` and tag; protect `main` with a ruleset that requires
   the CI `check` status — the token belongs to an admin and bypasses it.

6. **`BUILD_NUMBER` and `EXPECTED_APP_SIGNING_SHA256` must exist** before the
   first release; the workflows fail fast with explicit errors otherwise.

## Cutting a release (GitHub UI)

Actions → **Release** → Run workflow from `main`:

- `version` — `1.0.0` (no leading `v`)
- `release_notes` — markdown for the GitHub Release and the CHANGELOG entry
- `dry_run` — build and verify everything, upload artifacts, but do not
  commit, tag, push, or publish. Use this for the first run of a new pipeline.

The workflow: reserves the build number → bumps `app/pubspec.yaml` +
`CHANGELOG.md` on a `release/vX.Y.Z` branch → runs the full check suite →
builds universal + per-ABI release APKs → re-signs all four with the app
signing key → verifies signatures, zip alignment, and version codes →
fast-forwards `main`, tags `vX.Y.Z` → creates the GitHub Release with the
APKs, `SHA256SUMS.txt`, `build-metadata.txt`, and the notes.

After the APK release is published, a desktop matrix builds from the tag and
attaches Linux (`linux-x64.tar.gz`), Windows (`windows-x64.zip`) and macOS
(`macos.zip`) bundles to the same release. The desktop builds are **not
signed or notarized**; Windows SmartScreen and macOS Gatekeeper require the
user to confirm the first launch. If one platform fails, re-run only that
failed job from the Actions UI — the published APK release is untouched.

Version codes: the universal APK uses `BUILD_NUMBER`; split APKs get the
Flutter ABI offsets (+1000 v7a, +2000 arm64, +4000 x86_64) — Android update
semantics, matches MeshChameleon's handling.

## Signed test build (no release)

Actions → **Test build** → Run workflow: pick `ref` (branch/tag/SHA to
validate). Reserves a build number, builds the same signed APKs (release
environment, reviewer required), and uploads them as a workflow artifact.
Linux, macOS and Windows bundles are attached to the same run as separate
artifacts. Nothing is tagged, pushed, or published; artifacts expire in 14
days.

## Local release-adjacent builds

```sh
./scripts/build_test_apk.sh --install --keystore /path/to/app-signing.p12
```

Builds a universal APK signed with the app signing key so it can replace an
installed GitHub release build, or installs it onto one attached device.
Set `MESHCORE_REPEATER_MANAGER_APP_SIGNING_SHA256` to verify the fingerprint.

## CI

`.github/workflows/ci.yml` runs on every push/PR to `main`: format, analyze,
all package + app tests, the coverage gate (`scripts/coverage.sh`,
`coverage_baseline.json`), the lockfile check, and debug + release APK builds
(release uses the debug key — no secrets — and exercises the R8 path).

The coverage baseline was generated against this repo; it only ratchets
downward per-file (`scripts/coverage.sh` enforces it). Regenerate with
`./scripts/coverage.sh --write-baseline` after landing real coverage gains.
