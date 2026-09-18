# Apple root certificates (public)

Trust anchors for verifying App Store signed data offline (`src/pass.ts`,
`SignedDataVerifier` from `@apple/app-store-server-library`). These are
Apple's **public** root CA certificates in DER form — not secrets. Fetched
2026-09-18 from [Apple PKI](https://www.apple.com/certificateauthority/):

| File | Source | Expires |
|---|---|---|
| `AppleRootCA-G2.cer` | https://www.apple.com/certificateauthority/AppleRootCA-G2.cer | 2039-04-30 |
| `AppleRootCA-G3.cer` | https://www.apple.com/certificateauthority/AppleRootCA-G3.cer | 2039-04-30 |
| `AppleIncRootCertificate.cer` | https://www.apple.com/appleca/AppleIncRootCertificate.cer | 2035-02-09 |

Re-download (Git Bash):

```sh
cd firebase/functions/certs
curl -sSLO https://www.apple.com/certificateauthority/AppleRootCA-G2.cer
curl -sSLO https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
curl -sSLO https://www.apple.com/appleca/AppleIncRootCertificate.cer
openssl x509 -inform der -in AppleRootCA-G3.cer -noout -subject -enddate   # sanity check
```

The folder is deployed with the functions (`lib/pass.js` reads `../certs/*.cer` at first use).
