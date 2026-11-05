# Prepare a macOS release

The packager builds self-contained ZIP and DMG assets, an exact committed source
snapshot, a manifest and SHA-256 checksums. It never replaces an existing output
directory, installs over an app, or includes runtime memory/model caches.

## Local candidate

From this checkout with full Xcode selected:

```sh
python3 release/package.py --mode candidate
python3 -m unittest discover -s release -p 'test_*.py' -v
```

Candidates are ad-hoc signed and explicitly labelled **not notarized / local QA
only**. They are not public installers. Inspect the manifest and verify the
checksums with `shasum -a 256 -c SHA256SUMS` inside the asset directory.

The packager verifies code signatures, architectures, bundled resources and
dynamic library paths. It extracts the ZIP and mounts the actual DMG read-only,
compares every payload file and checks its Applications link.

## Signed distribution

This requires Apple Developer Program membership, a valid **Developer ID
Application** identity with its private key, and an existing `notarytool`
Keychain profile. Apple Development is not a distribution identity. Configure
credentials through Apple's tools; never put passwords, keys or certificates
in this repository or GitHub assets.

After committing the reviewed source and passing acceptance:

```sh
python3 release/package.py --mode release \
  --identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile 'your-existing-keychain-profile'
```

Release mode signs inner code and the app with hardened runtime and timestamp,
requires notarization status `Accepted`, staples and validates the app ticket,
and runs Gatekeeper assessment. It then signs/notarizes/staples the DMG and
checks both final containers before emitting assets. An invalid/missing identity,
failed notarization or failed verification aborts; no release assets are emitted.
Failure receipts stay under ignored `artifacts/release-failures/`.

## Publication acceptance

1. Build from a clean committed checkout and run the product's tests.
2. Confirm the manifest's source commit and payload/checksum correspondence.
3. Exercise a fresh synthetic workspace/library through the packaged executable,
   including saving, relaunch and any bundled helper. Preserve personal data.
4. Download the **notarized** package on a clean physical Mac without developer
   tools. Open the DMG, drag to Applications, launch, save and reopen a note.
   Verify supported architectures/OS versions separately; a universal Mach-O is
   not execution proof on an Intel Mac.
5. Attach final assets to a GitHub draft release targeting that exact commit.
   Replace local candidate assets with the verified signed assets before publishing.

Candidate checks do not establish Gatekeeper acceptance after a real download.
No instructions here disable Gatekeeper or remove quarantine. Use the product's
`INSTALL.txt` and `NOTES.md` for the release description. Keep a release draft
while signature/notarization or required first-install acceptance is incomplete.

Apple references: [Developer ID](https://developer.apple.com/developer-id/) and
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
