// Guards the Apple root CAs that redeemFamilyPass needs at runtime: they must be committed and parse.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { X509Certificate } from "node:crypto";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "certs");
const cers = readdirSync(dir).filter((f) => f.endsWith(".cer"));

test("three Apple root certificates are present", () => {
  assert.deepEqual(cers.sort(), ["AppleIncRootCertificate.cer", "AppleRootCA-G2.cer", "AppleRootCA-G3.cer"]);
});

for (const f of cers) {
  test(`${f} parses as an X.509 certificate issued by Apple`, () => {
    const cert = new X509Certificate(readFileSync(join(dir, f)));
    assert.match(cert.issuer, /Apple/);
    assert.ok(cert.ca, `${f} should be a CA certificate`);
  });
}
