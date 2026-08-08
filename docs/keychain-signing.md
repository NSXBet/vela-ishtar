# Keychain signing certificate — generation & custody

Why this file exists: `build.sh` signs the app with a **self-signed
code-signing certificate** instead of ad-hoc (`codesign --sign -`). Signing
with a cert pins the Keychain item's *designated requirement* to the
certificate, which stays identical across version bumps — so macOS stops
showing the "wants to use your confidential information" password dialog after
every update. Ad-hoc signing keys that requirement to a bare cdhash that shifts
on every version bump, which is exactly the re-prompt bug (#10).

This cert is the app's **stable identity**. Treat its private key like a
secret: losing it means generating a *new* cert, which is a *new* identity, and
every user re-grants Keychain access once (back to the old behavior until they
do).

## Where the cert lives

- In the **login keychain** of the build machine, under the name
  **`Vela Ishtar Code Signing`**, with its private key.
- `build.sh` finds it by NAME via
  `security find-certificate -c "Vela Ishtar Code Signing"` (any keychain on
  the search list). It deliberately does NOT use
  `security find-identity -v -p codesigning`, which filters on trust — a
  self-signed cert lacks that non-interactively and would wrongly fall back to
  ad-hoc. The verification step below still uses `find-identity`, since there
  you're confirming the cert+key pair is importable as a code-signing identity.
- If it's absent, `build.sh` prints a note and falls back to ad-hoc signing so
  a fresh clone still builds — but updates will re-prompt until the cert exists.

## Generate it (once per build machine, or once ever + import)

GUI (simplest):

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant →
   Create a Certificate…**
2. Name: `Vela Ishtar Code Signing`
3. Identity Type: **Self-Signed Root**
4. Certificate Type: **Code Signing**
5. Create. It lands in the login keychain with its private key.

CLI equivalent (no GUI), produces the same login-keychain identity:

```sh
# 2048-bit RSA self-signed code-signing cert, 10-year validity, into login keychain.
cat > /tmp/vela-csr.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
[ dn ]
CN = Vela Ishtar Code Signing
[ ext ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -keyout /tmp/vela-codesign.key \
  -out /tmp/vela-codesign.crt -days 3650 -nodes -config /tmp/vela-csr.cnf
openssl pkcs12 -export -out /tmp/vela-codesign.p12 \
  -inkey /tmp/vela-codesign.key -in /tmp/vela-codesign.crt \
  -passout pass:"$(read -s -p 'P12 export password: ' p; echo "$p")"
security import /tmp/vela-codesign.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "<the export password>" -T /usr/bin/codesign
# Verify it shows up as a code-signing identity:
security find-identity -v -p codesigning | grep "Vela Ishtar Code Signing"
# Clean up the loose key material:
rm -f /tmp/vela-codesign.key /tmp/vela-codesign.crt /tmp/vela-codesign.p12 /tmp/vela-csr.cnf
```

## Back it up (do this once, right after generating)

Export the cert **with its private key** to an encrypted `.p12` and store it
somewhere off the build machine (password manager attachment, encrypted
backup):

```sh
# GUI: Keychain Access → right-click the cert (the one with the key) →
#      Export → .p12 → set a strong password → save somewhere safe.
# CLI:
security export -k ~/Library/Keychains/login.keychain-db \
  -t identities -f pkcs12 \
  -o ~/Desktop/vela-ishtar-codesign-backup.p12 -P "<strong password>"
# Then move the .p12 off this machine and delete the Desktop copy.
```

Restore on a new/rebuilt machine: `security import <backup>.p12 -k
~/Library/Keychains/login.keychain-db -P "<password>" -T /usr/bin/codesign`.

## Notes / limits

- This cert is **not** Gatekeeper-trusted (it's self-signed), so the
  `xattr -cr` step in the README install instructions stays. That's unchanged
  from today. Developer ID + notarization (a paid account) is what removes
  that — tracked separately and out of scope here.
- The **first** update shipped under this cert still prompts **once**: the
  existing Keychain item's ACL is keyed to the old ad-hoc cdhashes, so the user
  clicks **Always Allow** one final time while the ACL re-anchors to the
  cert-based identity. Every update after that is silent.
- Do NOT commit the private key or the `.p12` to any repo.
