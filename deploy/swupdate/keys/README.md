# SWUpdate signing keys

Private keys are deliberately not committed. Set these absolute paths in the
protected build environment:

```text
HFT_SWUPDATE_SIGNING = "1"
HFT_SWUPDATE_PRIVATE_KEY = "/secure/swupdate-signing-key.pem"
HFT_SWUPDATE_CERTIFICATE = "/secure/swupdate-signing-cert.pem"
HFT_SWUPDATE_PUBLIC_CERT = "/secure/swupdate-signing-cert.pem"
```

For local development, generate a disposable certificate outside the checkout:

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 30 \
  -subj "/CN=hft-toy-development/" \
  -keyout /tmp/hft-swupdate-key.pem \
  -out /tmp/hft-swupdate-cert.pem
```

Only the certificate is installed on the target. Production signing belongs in
an HSM or protected CI environment with audited key rotation.
