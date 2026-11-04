# SyncMe update manifest signing

Official feeds at `https://www.syncme.co.za/updates/latest.json` must include an RSA signature.

- **Public key (shipped):** `Modules/UpdatePublicKey.xml`
- **Private key (never commit):** `Tools/syncme-update-private.xml` (gitignored) or path in `SYNCME_UPDATE_KEY_XML`

`Build-SyncMeSetup.ps1` signs `dist/uploads/latest.json` automatically when the private key is present.

Keep a secure offline backup of the private key. Rotating keys requires shipping a new public key in a SyncMe release first.
