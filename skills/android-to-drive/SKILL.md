---
name: android-to-drive
description: "Build the latest main as a signed Android APK and publish it as termio.apk in Google Drive's My Drive root. Use when asked to 'release the APK', 'publish the APK to Drive', or 'update termio.apk' in this repository."
---

# Publish Android APK to Google Drive

Build the latest fetched `origin/main`, sign with the existing release key, and
replace `termio.apk` in the user's Google Drive root. A request to publish with
this skill includes replacing that file. This workflow publishes through Drive;
GitHub releases and Google Play distribution are separate tasks.

If the user requests a specific already-built APK, verify and publish that file
instead of rebuilding `main`. Report its actual source, including local changes.

## 1. Locate the destination and signing key

- Use a user-specified Drive directory when provided. Otherwise discover
  `~/Library/CloudStorage/GoogleDrive-*/My Drive`. Require one existing root;
  ask which account to use if there are multiple. Do not create a missing mount.
- Find `.android-release-signing/` in the invoking checkout or the primary
  checkout listed by `git worktree list --porcelain`. It contains
  `termio-release.p12`, `store-password`, and `signing-cert.der`; the key alias
  is `termio`. Stop if these are missing rather than generating a different key.
- Keep the key and password local. Do not print them, enable shell tracing, or
  put passwords in command arguments. Pass the password through an environment
  variable used only by the signing subprocess.

## 2. Fetch and isolate the source

Run `git fetch origin main` and immediately capture `git rev-parse FETCH_HEAD`.
Create a temporary detached worktree at that exact commit, under an ignored
`.build/` directory. Preserve the invoking branch and its edits. Read the fetched
checkout's Android configuration and use its Gradle wrapper and
`.github/workflows/android-release.yml` as the build and verification reference.

Use full Git history for `git rev-list --count HEAD`; fetch missing history if
the repository is shallow. This count is `TERMIO_ANDROID_VERSION_CODE`. Set
`TERMIO_ANDROID_VERSION` to the configured Android version with
`-main.<short-commit>` appended. Do not edit tracked version files or create tags.

## 3. Build and check

Use Java 17 (`/usr/libexec/java_home -v 17`) and the installed Android SDK
(`ANDROID_HOME`, normally `~/Library/Android/sdk`). From the temporary worktree's
`android/` directory, with both version variables set, run:

```sh
./gradlew --no-daemon :app:assembleRelease :app:testDebugUnitTest :app:lintRelease
```

Stop on failure and leave the existing Drive APK intact.

## 4. Sign and verify

Use the SDK build-tools version from the release workflow (currently `36.0.0`).
Align `app/build/outputs/apk/release/app-release-unsigned.apk` with
`zipalign -P 16 -f 4`, then sign the aligned APK into a local temporary file:

```sh
TERMIO_APK_PASSWORD="$(cat "$signing_directory/store-password")" \
  "$build_tools/apksigner" sign \
  --ks "$signing_directory/termio-release.p12" --ks-key-alias termio \
  --ks-pass env:TERMIO_APK_PASSWORD --key-pass env:TERMIO_APK_PASSWORD \
  --v4-signing-enabled false --out "$signed_apk" "$aligned_apk"
```

Verify with `apksigner verify --verbose --print-certs` and
`zipalign -c -P 16 4`. Require the signer certificate SHA-256 to match
`shasum -a 256 "$signing_directory/signing-cert.der"`. Check the package
(`sh.termio.android`), stamped version/code, minimum SDK, non-debuggability,
and native architectures against the release workflow. Stop on any mismatch.

## 5. Copy to Drive and report

If Drive already contains `termio.apk`, inspect its version code and stop if
this build would be a downgrade. Stage the verified APK in the same Drive
directory, compare its SHA-256 to the local signed APK, then atomically replace
`termio.apk`. Verify the destination checksum. Preserve the previous APK until
the staged copy passes verification.

If macOS blocks access to the mounted folder and connected Drive tools are
available, use those tools to replace the cloud file directly. Find `termio.apk`
in My Drive's root; list the folder if search omits binary files. Download the
existing APK to check its version and signer before replacing its bytes.
Preserve its file ID, parents, name, and sharing settings. Download the completed
upload and require its SHA-256 to match the verified local APK. If the result of
an upload is uncertain, read the existing file back before retrying the write.
Without working folder access or connected tools, stop and report the blocker.

Remove only this run's temporary files and worktree afterward. Keep any worktree
that contains local changes used for an explicitly requested test APK.

Report the full destination path, source commit, version/build, SHA-256, and
build/test/lint/signature results. For folder copies, Drive for desktop handles
the upload. Confirm
remote upload when Drive tools or sync status provide evidence; otherwise say
“Copied to the Drive folder; cloud sync is unverified.” Do not claim the APK is
ready on the phone from local file verification alone.
