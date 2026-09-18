#!/usr/bin/env python3
"""App Store Connect setup for Pinny (bundle ID com.skyline.pinny).

Run by GitHub Actions (.github/workflows/asc-setup.yml and ios-testflight.yml);
see docs/TESTFLIGHT.md, Path A. Reads the API key from the environment:
ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (full .p8 text). Never prints them.

  setup [--tester-email EMAIL]
      Registers the bundle ID, enables its capabilities, reports registered
      devices and the App Store Connect app record. With --tester-email (and an
      existing app record) adds that person to the internal TestFlight group
      "Owner". Safe to run again: existing items are reused.

  family-link [--contact-phone N] [--contact-first-name X] [--contact-last-name Y] [--build VERSION]
      External TestFlight for the family in one go: external group "Family"
      with a public link, TestFlight test information (en-AU), Beta App Review
      contact + notes, then the newest processed build (or --build) gets its
      What to Test text, export compliance, the Family group and a Beta App
      Review submission. Prints the public link. Safe to run again.

  revoke-runner-certs
      CI clean-up. `xcodebuild archive -allowProvisioningUpdates` on a fresh
      runner creates a new Apple Development certificate whose private key only
      ever exists on that throwaway runner. Left alone they pile up until Apple's
      certificate limit blocks builds. This revokes only development
      certificates whose identity (certificate + private key) is in this runner's
      keychain. Refuses to run outside GitHub Actions.

API reference: https://developer.apple.com/documentation/appstoreconnectapi
"""

import argparse
import base64
import hashlib
import os
import re
import subprocess
import sys
import time

import jwt
import requests

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "com.skyline.pinny"
BUNDLE_NAME = "Pinny"
BETA_GROUP = "Owner"

# family-link: external TestFlight (docs/TESTFLIGHT.md, section D).
FAMILY_GROUP = "Family"
FEEDBACK_EMAIL = "tony810704@hotmail.com"
PRIVACY_URL = "https://pinny-family-4vea.web.app/privacy"
# Preferred locale first; an existing en-US localization (the app's primary
# language seed) is updated instead of creating a second one.
LOCALES = ("en-AU", "en-US")
# TestFlight "What to Test" (betaAppLocalizations.description), from docs/APP-STORE-LISTING.md.
BETA_DESCRIPTION = (
    "Pinny is a private map for your family. Please test: sign in (Apple, Google or email), "
    "create a family or join one with the invite code, open the map and tap Refresh or Check in "
    "to share your location, hold the SOS button, send a few family chat messages, save a Place "
    "such as Home or School, add a profile photo, and try Settings > Delete account on a throwaway "
    "account. Location is shared only while the app is open: there is no background tracking."
)
REVIEW_NOTES = (
    "Sign in with your own Google or Apple account. Creating a family needs the Family Pass "
    "in-app purchase; in TestFlight/sandbox this is free. Location is shared only while the app "
    "is open (open, Refresh/Check in, SOS): no background tracking. The emergency-call button "
    "shows your region's number."
)
WHATS_NEW = "Family map, SOS, chat and Places. Location is shared only while the app is open."

# (capabilityType, label, settings). Must match the entitlements in project.yml.
# USERNOTIFICATIONS_TIMESENSITIVE is accepted by the API (fastlane uses it) but
# is missing from Apple's published CapabilityType list.
CAPABILITIES = [
    ("PUSH_NOTIFICATIONS", "Push Notifications", []),
    (
        "APPLE_ID_AUTH",
        "Sign in with Apple",
        [{"key": "APPLE_ID_AUTH_APP_CONSENT", "options": [{"key": "PRIMARY_APP_CONSENT"}]}],
    ),
    ("USERNOTIFICATIONS_TIMESENSITIVE", "Time Sensitive Notifications", []),
]

DEV_CERT_TYPES = {"DEVELOPMENT", "IOS_DEVELOPMENT"}


class ApiError(Exception):
    def __init__(self, status, errors):
        self.status = status
        self.errors = errors
        parts = []
        for e in errors:
            parts.append(f"{e.get('code', '?')}: {e.get('detail') or e.get('title') or ''}".strip())
        super().__init__(f"HTTP {status} - " + ("; ".join(parts) or "no details"))


class Client:
    def __init__(self, key_id, issuer_id, private_key):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = private_key
        self._token = None
        self._token_exp = 0

    def token(self):
        now = int(time.time())
        if not self._token or now > self._token_exp - 60:
            # Apple rejects tokens that expire more than 20 minutes ahead.
            self._token_exp = now + 15 * 60
            self._token = jwt.encode(
                {"iss": self.issuer_id, "iat": now, "exp": self._token_exp, "aud": "appstoreconnect-v1"},
                self.private_key,
                algorithm="ES256",
                headers={"kid": self.key_id, "typ": "JWT"},
            )
        return self._token

    def request(self, method, path_or_url, params=None, body=None):
        url = path_or_url if path_or_url.startswith("http") else API + path_or_url
        r = requests.request(
            method,
            url,
            params=params,
            json=body,
            headers={"Authorization": f"Bearer {self.token()}"},
            timeout=60,
        )
        if r.status_code >= 400:
            try:
                errors = r.json().get("errors", [])
            except ValueError:
                errors = []
            raise ApiError(r.status_code, errors)
        return r.json() if r.content else {}

    def get_all(self, path, params=None):
        items = []
        page = self.request("GET", path, params=params)
        while True:
            items.extend(page.get("data", []))
            nxt = page.get("links", {}).get("next")
            if not nxt:
                return items
            page = self.request("GET", nxt)


def hint(err):
    if err.status == 401:
        return ("The key was rejected. Check ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_P8 "
                "all belong to the same active App Store Connect team key.")
    if err.status == 403:
        return "The API key's role is not allowed to do this. See docs/TESTFLIGHT.md, Path A troubleshooting."
    return ""


def fail_line(msg, err=None):
    print(f"::error::{msg}" + (f" ({err})" if err else ""))
    if err is not None and hint(err):
        print(f"    {hint(err)}")


def mask_email(email):
    local, _, domain = email.partition("@")
    return (local[:1] + "***@" + domain) if domain else "***"


def load_client():
    names = ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8"]
    missing = [n for n in names if not os.environ.get(n, "").strip()]
    if missing:
        print(f"::error::Missing GitHub secret(s): {', '.join(missing)}. See docs/TESTFLIGHT.md, Path A step 1.")
        sys.exit(2)
    p8 = os.environ["ASC_KEY_P8"].replace("\r\n", "\n").strip() + "\n"
    if "BEGIN PRIVATE KEY" not in p8:
        print("::error::ASC_KEY_P8 does not look like a .p8 file (no 'BEGIN PRIVATE KEY' line). "
              "Set it to the whole file text.")
        sys.exit(2)
    return Client(os.environ["ASC_KEY_ID"].strip(), os.environ["ASC_ISSUER_ID"].strip(), p8)


# ---------------------------------------------------------------- setup ----

def ensure_bundle_id(c):
    found = c.get_all("/v1/bundleIds", {"filter[identifier]": BUNDLE_ID, "limit": 200})
    for b in found:
        if b["attributes"].get("identifier") == BUNDLE_ID:
            print(f"Bundle ID {BUNDLE_ID}: already registered "
                  f"(name \"{b['attributes'].get('name')}\", platform {b['attributes'].get('platform')})")
            return b["id"]
    body = {"data": {"type": "bundleIds",
                     "attributes": {"identifier": BUNDLE_ID, "name": BUNDLE_NAME, "platform": "IOS"}}}
    created = c.request("POST", "/v1/bundleIds", body=body)
    print(f"Bundle ID {BUNDLE_ID}: registered now (name \"{BUNDLE_NAME}\", platform IOS)")
    return created["data"]["id"]


def ensure_capabilities(c, bundle_pk):
    # This relationship endpoint rejects paging parameters (PARAMETER_ERROR.ILLEGAL on "limit").
    existing = c.get_all(f"/v1/bundleIds/{bundle_pk}/bundleIdCapabilities")
    have = {x["attributes"].get("capabilityType") for x in existing}
    results = {}
    for cap_type, label, settings in CAPABILITIES:
        if cap_type in have:
            print(f"  {label}: already on")
            results[label] = "on"
            continue
        body = {"data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": cap_type, "settings": settings},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_pk}}},
        }}
        try:
            c.request("POST", "/v1/bundleIdCapabilities", body=body)
            print(f"  {label}: enabled now")
            results[label] = "on"
        except ApiError as e:
            if e.status == 409:
                print(f"  {label}: already on (409)")
                results[label] = "on"
            else:
                fail_line(f"Could not enable {label} ({cap_type}) on {BUNDLE_ID}", e)
                print("    Enable it by hand: developer.apple.com/account > Identifiers > "
                      f"{BUNDLE_ID} > tick it > Save.")
                results[label] = "FAILED"
    return results


def count_devices(c):
    devices = c.get_all("/v1/devices", {"filter[platform]": "IOS", "filter[status]": "ENABLED", "limit": 200})
    return len(devices)


def find_app(c):
    apps = c.get_all("/v1/apps", {"filter[bundleId]": BUNDLE_ID, "limit": 200})
    for a in apps:
        if a["attributes"].get("bundleId") == BUNDLE_ID:
            return a
    return None


def ensure_tester(c, app_id, email):
    groups = c.get_all("/v1/betaGroups", {"filter[app]": app_id, "filter[name]": BETA_GROUP, "limit": 200})
    group = next((g for g in groups if g["attributes"].get("name") == BETA_GROUP), None)
    if group and not group["attributes"].get("isInternalGroup"):
        fail_line(f"A beta group named \"{BETA_GROUP}\" exists but is an EXTERNAL group. "
                  "Rename or delete it in App Store Connect > TestFlight, then run again.")
        return "FAILED"
    if group:
        print(f"Beta group \"{BETA_GROUP}\": exists (internal, access to all builds: "
              f"{group['attributes'].get('hasAccessToAllBuilds')})")
    else:
        body = {"data": {
            "type": "betaGroups",
            "attributes": {"name": BETA_GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }}
        group = c.request("POST", "/v1/betaGroups", body=body)["data"]
        print(f"Beta group \"{BETA_GROUP}\": created (internal, access to all builds)")
    gid = group["id"]

    shown = mask_email(email)
    members = c.get_all(f"/v1/betaGroups/{gid}/betaTesters", {"limit": 200})
    if any((m["attributes"].get("email") or "").lower() == email.lower() for m in members):
        print(f"Tester {shown}: already in \"{BETA_GROUP}\"")
        return "in group"
    try:
        known = c.get_all("/v1/betaTesters", {"filter[email]": email, "limit": 200})
        tester = next((t for t in known if (t["attributes"].get("email") or "").lower() == email.lower()), None)
        if tester:
            c.request("POST", f"/v1/betaGroups/{gid}/relationships/betaTesters",
                      body={"data": [{"type": "betaTesters", "id": tester["id"]}]})
        else:
            c.request("POST", "/v1/betaTesters", body={"data": {
                "type": "betaTesters",
                "attributes": {"email": email},
                "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": gid}]}},
            }})
        print(f"Tester {shown}: added to \"{BETA_GROUP}\"")
        return "added"
    except ApiError as e:
        fail_line(f"Could not add tester {shown} to \"{BETA_GROUP}\"", e)
        print("    Internal testers must already be App Store Connect users of this team "
              "(Users and Access). Use the Apple ID email of that user.")
        try:
            users = c.get_all("/v1/users", {"limit": 200})
            print("    Team users (masked): " + ", ".join(
                f"{mask_email(u['attributes'].get('username') or '')} [{'/'.join(u['attributes'].get('roles') or [])}]"
                for u in users) or "none")
        except ApiError as e2:
            print(f"    (could not list team users: {e2})")
        return "FAILED"


# ---------------------------------------------------------- family-link ----
# Endpoints: https://developer.apple.com/documentation/appstoreconnectapi
#   POST/PATCH /v1/betaGroups, GET /v1/betaGroups (filter[app], filter[name]),
#   GET /v1/apps/{id}/betaAppLocalizations, POST/PATCH /v1/betaAppLocalizations,
#   GET /v1/apps/{id}/betaAppReviewDetail, PATCH /v1/betaAppReviewDetails/{id},
#   GET /v1/builds (filter[processingState], sort=-uploadedDate), PATCH /v1/builds/{id},
#   GET /v1/builds/{id}/betaBuildLocalizations, POST/PATCH /v1/betaBuildLocalizations,
#   POST /v1/betaGroups/{id}/relationships/builds (204),
#   POST /v1/betaAppReviewSubmissions, GET /v1/builds/{id}/betaAppReviewSubmission.

def ensure_family_group(c, app_id):
    """External group with a public link. Returns the group resource (attributes incl. publicLink)."""
    groups = c.get_all("/v1/betaGroups", {"filter[app]": app_id, "filter[name]": FAMILY_GROUP, "limit": 200})
    group = next((g for g in groups if g["attributes"].get("name") == FAMILY_GROUP), None)
    if group and group["attributes"].get("isInternalGroup"):
        raise ApiError(0, [{"code": "GROUP_IS_INTERNAL",
                            "detail": f"\"{FAMILY_GROUP}\" exists but is an INTERNAL group. Rename or delete it "
                                      "in App Store Connect > TestFlight, then run again."}])
    wanted = {"publicLinkEnabled": True, "publicLinkLimitEnabled": False, "feedbackEnabled": True}
    if not group:
        body = {"data": {
            "type": "betaGroups",
            "attributes": {"name": FAMILY_GROUP, "isInternalGroup": False, **wanted},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }}
        group = c.request("POST", "/v1/betaGroups", body=body)["data"]
        print(f"Beta group \"{FAMILY_GROUP}\": created (external, public link on)")
    elif any(group["attributes"].get(k) != v for k, v in wanted.items()):
        group = c.request("PATCH", f"/v1/betaGroups/{group['id']}",
                          body={"data": {"type": "betaGroups", "id": group["id"], "attributes": wanted}})["data"]
        print(f"Beta group \"{FAMILY_GROUP}\": exists, public link turned on")
    else:
        print(f"Beta group \"{FAMILY_GROUP}\": exists (external, public link on)")
    return group


def pick_locale(items):
    """Prefer en-AU, then en-US, among existing localization resources."""
    for loc in LOCALES:
        hit = next((x for x in items if x["attributes"].get("locale") == loc), None)
        if hit:
            return hit
    return None


def ensure_beta_app_localization(c, app_id):
    """TestFlight test information: description (what to test), feedback email, privacy URL."""
    attrs = {"description": BETA_DESCRIPTION, "feedbackEmail": FEEDBACK_EMAIL, "privacyPolicyUrl": PRIVACY_URL}
    existing = c.get_all(f"/v1/apps/{app_id}/betaAppLocalizations", {"limit": 200})
    target = pick_locale(existing)
    if target:
        c.request("PATCH", f"/v1/betaAppLocalizations/{target['id']}",
                  body={"data": {"type": "betaAppLocalizations", "id": target["id"], "attributes": attrs}})
        locale = target["attributes"].get("locale")
        print(f"Test information ({locale}): updated (feedback {mask_email(FEEDBACK_EMAIL)}, privacy URL set)")
    else:
        locale = LOCALES[0]
        c.request("POST", "/v1/betaAppLocalizations", body={"data": {
            "type": "betaAppLocalizations",
            "attributes": {"locale": locale, **attrs},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})
        print(f"Test information ({locale}): created (feedback {mask_email(FEEDBACK_EMAIL)}, privacy URL set)")
    # Beta App Review refuses to submit while any localization lacks a description.
    for other in existing:
        if other is target or other["attributes"].get("description"):
            continue
        c.request("PATCH", f"/v1/betaAppLocalizations/{other['id']}",
                  body={"data": {"type": "betaAppLocalizations", "id": other["id"],
                                 "attributes": {"description": BETA_DESCRIPTION}}})
        print(f"Test information ({other['attributes'].get('locale')}): description filled in")
    return locale


def ensure_review_detail(c, app_id, phone, first, last):
    """Beta App Review contact + notes. Singleton per app; empty inputs leave existing values alone."""
    detail = c.request("GET", f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]
    attrs = {"contactEmail": FEEDBACK_EMAIL, "demoAccountRequired": False, "notes": REVIEW_NOTES}
    for key, val in (("contactPhone", phone), ("contactFirstName", first), ("contactLastName", last)):
        if val:
            attrs[key] = val
    detail = c.request("PATCH", f"/v1/betaAppReviewDetails/{detail['id']}",
                       body={"data": {"type": "betaAppReviewDetails", "id": detail["id"], "attributes": attrs}})["data"]
    a = detail["attributes"]
    missing = [k for k in ("contactFirstName", "contactLastName", "contactPhone") if not a.get(k)]
    print(f"Beta App Review contact: {mask_email(a.get('contactEmail') or '')}, "
          f"name {'set' if not missing or 'contactFirstName' not in missing else 'MISSING'}, "
          f"phone {'set' if 'contactPhone' not in missing else 'MISSING'}; notes set")
    if missing:
        print(f"::warning::Beta App Review needs {', '.join(missing)}. Re-run with the contact_* inputs.")
    return not missing


def pick_build(c, app_id, version):
    params = {"filter[app]": app_id, "filter[processingState]": "VALID", "filter[expired]": "false",
              "sort": "-uploadedDate", "limit": 1}
    if version:
        params["filter[version]"] = version
    builds = c.get_all("/v1/builds", params)
    return builds[0] if builds else None


def ensure_whats_new(c, build_id):
    existing = c.get_all(f"/v1/builds/{build_id}/betaBuildLocalizations", {"limit": 200})
    target = pick_locale(existing)
    if target:
        c.request("PATCH", f"/v1/betaBuildLocalizations/{target['id']}",
                  body={"data": {"type": "betaBuildLocalizations", "id": target["id"],
                                 "attributes": {"whatsNew": WHATS_NEW}}})
        print(f"  What to Test ({target['attributes'].get('locale')}): updated")
    else:
        c.request("POST", "/v1/betaBuildLocalizations", body={"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": LOCALES[0], "whatsNew": WHATS_NEW},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }})
        print(f"  What to Test ({LOCALES[0]}): created")


def ensure_export_compliance(c, build):
    if build["attributes"].get("usesNonExemptEncryption") is None:
        c.request("PATCH", f"/v1/builds/{build['id']}",
                  body={"data": {"type": "builds", "id": build["id"],
                                 "attributes": {"usesNonExemptEncryption": False}}})
        print("  Export compliance: answered (usesNonExemptEncryption=false)")
    else:
        print(f"  Export compliance: already answered (usesNonExemptEncryption={build['attributes']['usesNonExemptEncryption']})")


def review_state(c, build_id):
    """betaReviewState of the build's submission, or None if never submitted."""
    try:
        sub = c.request("GET", f"/v1/builds/{build_id}/betaAppReviewSubmission")
    except ApiError as e:
        if e.status == 404:
            return None
        raise
    return (sub.get("data") or {}).get("attributes", {}).get("betaReviewState")


def submit_build(c, group_id, build_id):
    try:
        c.request("POST", f"/v1/betaGroups/{group_id}/relationships/builds",
                  body={"data": [{"type": "builds", "id": build_id}]})
        print(f"  Added to \"{FAMILY_GROUP}\"")
    except ApiError as e:
        if e.status != 409:
            raise
        print(f"  Already in \"{FAMILY_GROUP}\" (409)")
    state = review_state(c, build_id)
    if state in (None, "REJECTED"):
        try:
            c.request("POST", "/v1/betaAppReviewSubmissions", body={"data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }})
            print("  Submitted for Beta App Review")
        except ApiError as e:
            if e.status != 409:
                raise
            print(f"  Beta App Review submission not accepted (409: {e}); checking current state")
    else:
        print("  Already submitted for Beta App Review")
    return review_state(c, build_id) or "not submitted"


def cmd_family_link(args):
    c = load_client()
    ok = True
    rows = []
    app = find_app(c)
    if not app:
        print("::error::APP RECORD MISSING - create it in App Store Connect first (docs/TESTFLIGHT.md, A5).")
        return 1
    app_id = app["id"]
    print(f"App: {app['attributes'].get('name')} (Apple ID {app_id})")

    print("== External group ==")
    group = None
    try:
        group = ensure_family_group(c, app_id)
        link = group["attributes"].get("publicLink") or "(not issued yet)"
        print(f"PUBLIC LINK: {link}")
        rows.append(("Family group public link", link))
    except ApiError as e:
        fail_line(f"Could not set up beta group \"{FAMILY_GROUP}\"", e)
        rows.append(("Family group", "FAILED"))
        ok = False

    print("== Test information ==")
    try:
        loc = ensure_beta_app_localization(c, app_id)
        rows.append(("Test information", f"{loc}: description, feedback email, privacy URL"))
    except ApiError as e:
        fail_line("Could not write TestFlight test information", e)
        rows.append(("Test information", "FAILED"))
        ok = False

    print("== Beta App Review contact ==")
    try:
        complete = ensure_review_detail(c, app_id, args.contact_phone.strip(), args.contact_first_name.strip(),
                                        args.contact_last_name.strip())
        rows.append(("Beta App Review contact", "complete" if complete else "INCOMPLETE - pass contact_* inputs"))
    except ApiError as e:
        fail_line("Could not write Beta App Review contact/notes", e)
        rows.append(("Beta App Review contact", "FAILED"))
        ok = False

    print("== Build ==")
    build = None
    try:
        build = pick_build(c, app_id, args.build.strip())
    except ApiError as e:
        fail_line("Could not list builds", e)
        ok = False
    if not build:
        want = f"build {args.build.strip()}" if args.build.strip() else "a processed (VALID) build"
        print(f"::warning::No {want} found. Run ios-testflight.yml, wait for processing, then run family-link again.")
        rows.append(("Build", "none processed yet"))
        write_summary(rows, "TestFlight for the family")
        return 0 if ok else 1
    ba = build["attributes"]
    print(f"Build {ba.get('version')} (uploaded {ba.get('uploadedDate')})")
    state = "FAILED"
    try:
        ensure_whats_new(c, build["id"])
        ensure_export_compliance(c, build)
        if group:
            state = submit_build(c, group["id"], build["id"])
        else:
            state = review_state(c, build["id"]) or "not submitted"
            print("  Skipped group/submission because the Family group failed above")
    except ApiError as e:
        fail_line(f"Could not prepare or submit build {ba.get('version')}", e)
        ok = False
    print(f"BETA REVIEW STATE: {state}")
    rows.append((f"Build {ba.get('version')}", f"betaReviewState **{state}**"))

    write_summary(rows, "TestFlight for the family")
    print("== Done ==" if ok else "== Finished with errors (see ::error:: lines above) ==")
    return 0 if ok else 1


def write_summary(rows, title="App Store Connect setup"):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as f:
        f.write(f"### {title}\n\n| Item | Result |\n|---|---|\n")
        for k, v in rows:
            f.write(f"| {k} | {v} |\n")


def cmd_setup(args):
    c = load_client()
    ok = True
    rows = []
    print("== Bundle ID ==")
    try:
        bundle_pk = ensure_bundle_id(c)
        rows.append(("Bundle ID", f"`{BUNDLE_ID}` registered"))
        print("== Capabilities ==")
        caps = ensure_capabilities(c, bundle_pk)
        if "FAILED" in caps.values():
            ok = False
        rows.append(("Capabilities", ", ".join(f"{k}: {v}" for k, v in caps.items())))
    except ApiError as e:
        fail_line(f"Could not read or register bundle ID {BUNDLE_ID}", e)
        rows.append(("Bundle ID", "FAILED"))
        ok = False

    print("== Registered devices ==")
    try:
        n = count_devices(c)
        if n == 0:
            print("::warning::NO REGISTERED iOS DEVICES. `xcodebuild archive` signs with a development "
                  "profile, which Apple only issues when the team has at least one device. Register the "
                  "owner's iPhone (docs/TESTFLIGHT.md, Path A, sequence item 2).")
        else:
            print(f"{n} enabled iOS device(s) on the team (archive signing needs at least 1)")
        rows.append(("Registered iOS devices", str(n) + (" - register one before building" if n == 0 else "")))
    except ApiError as e:
        fail_line("Could not list devices", e)
        rows.append(("Registered iOS devices", "unknown"))

    print("== App Store Connect app record ==")
    app = None
    looked_up = False
    try:
        app = find_app(c)
        looked_up = True
    except ApiError as e:
        fail_line("Could not look up the app record", e)
        rows.append(("App record", "lookup FAILED"))
        ok = False
    if app:
        print(f"App record found: \"{app['attributes'].get('name')}\" (SKU {app['attributes'].get('sku')})")
        print(f"APPLE ID (numeric): {app['id']}")
        rows.append(("App record", f"\"{app['attributes'].get('name')}\", Apple ID **{app['id']}**"))
    elif looked_up:
        print("::warning::APP RECORD MISSING - create it in App Store Connect: Apps > + > New App, "
              f"iOS, name \"Pinny Family Map\", bundle ID {BUNDLE_ID}, SKU pinny-ios-1.")
        rows.append(("App record", "**MISSING** - create it in App Store Connect"))

    email = (args.tester_email or "").strip()
    if email:
        print("== TestFlight internal tester ==")
        if not app:
            print("::error::Tester not added: the app record does not exist yet.")
            rows.append(("Tester", "skipped - no app record"))
            ok = False
        else:
            try:
                result = ensure_tester(c, app["id"], email)
            except ApiError as e:
                fail_line(f"Could not set up beta group \"{BETA_GROUP}\"", e)
                result = "FAILED"
            rows.append(("Tester", f"{mask_email(email)}: {result}"))
            if result == "FAILED":
                ok = False

    write_summary(rows)
    print("== Done ==" if ok else "== Finished with errors (see ::error:: lines above) ==")
    return 0 if ok else 1


# ------------------------------------------------- revoke-runner-certs ----

def cmd_revoke_runner_certs(_args):
    if os.environ.get("GITHUB_ACTIONS") != "true":
        print("Refusing to run outside GitHub Actions: this revokes certificates whose key is in the local keychain.")
        return 2
    out = subprocess.run(["security", "find-identity", "-p", "codesigning"],
                         capture_output=True, text=True).stdout
    runner_hashes = set(re.findall(r"\b[0-9A-F]{40}\b", out))
    if not runner_hashes:
        print("No signing identities in this runner's keychain; nothing to revoke.")
        return 0
    c = load_client()
    try:
        certs = c.get_all("/v1/certificates", {
            "fields[certificates]": "certificateType,displayName,serialNumber,certificateContent,expirationDate",
            "limit": 200,
        })
    except ApiError as e:
        print(f"::warning::Could not list certificates to clean up ({e}). Revoke unused "
              "'Created via API' development certificates by hand in developer.apple.com > Certificates.")
        return 0
    revoked = 0
    for cert in certs:
        a = cert["attributes"]
        content = a.get("certificateContent")
        if not content:
            continue
        sha1 = hashlib.sha1(base64.b64decode(content)).hexdigest().upper()
        if sha1 not in runner_hashes:
            continue
        label = f"{a.get('certificateType')} \"{a.get('displayName')}\" serial {a.get('serialNumber')}"
        if a.get("certificateType") not in DEV_CERT_TYPES:
            print(f"::warning::Runner keychain holds {label}; not a development certificate, so it was left alone.")
            continue
        try:
            c.request("DELETE", f"/v1/certificates/{cert['id']}")
            print(f"Revoked this runner's throwaway {label}")
            revoked += 1
        except ApiError as e:
            print(f"::warning::Could not revoke {label} ({e}). Revoke it by hand in developer.apple.com > Certificates.")
    if revoked == 0:
        print("No development certificate from this runner was found on the team.")
    return 0


def cmd_status(_args):
    """Read-only: builds + processing state, TestFlight groups/testers, in-app purchases."""
    c = load_client()
    app = find_app(c)
    if not app:
        print("APP RECORD MISSING")
        return 1
    app_id = app["id"]
    print(f"App: {app['attributes'].get('name')} (Apple ID {app_id})")
    print("== Builds (newest first) ==")
    builds = c.get_all("/v1/builds", {"filter[app]": app_id, "sort": "-uploadedDate", "limit": 5})
    if not builds:
        print("  none uploaded yet")
    for b in builds:
        a = b["attributes"]
        print(f"  build {a.get('version')}: {a.get('processingState')} (uploaded {a.get('uploadedDate')}, expired={a.get('expired')})")
    if builds:
        try:
            print(f"  latest build betaReviewState: {review_state(c, builds[0]['id']) or 'not submitted'}")
        except ApiError as e:
            print(f"  could not read beta review state: {e}")
    print("== TestFlight groups ==")
    for g in c.get_all("/v1/betaGroups", {"filter[app]": app_id, "limit": 200}):
        ga = g["attributes"]
        testers = c.get_all(f"/v1/betaGroups/{g['id']}/betaTesters", {"limit": 200})
        names = ", ".join(mask_email(t["attributes"].get("email") or "") for t in testers) or "no testers"
        print(f"  {ga.get('name')} ({'internal' if ga.get('isInternalGroup') else 'external'}): {names}")
        if ga.get("name") == FAMILY_GROUP:
            print(f"    public link: {ga.get('publicLink') or '(off)'}")
    print("== In-app purchases ==")
    try:
        iaps = c.get_all(f"/v1/apps/{app_id}/inAppPurchasesV2", {"limit": 200})
        if not iaps:
            print("  none (create 'Family Pass', product id com.skyline.pinny.family.pass)")
        for i in iaps:
            ia = i["attributes"]
            print(f"  {ia.get('productId')}: {ia.get('inAppPurchaseType')} / {ia.get('state')}")
    except ApiError as e:
        print(f"  could not list in-app purchases: {e}")
    return 0


def cmd_invite_user(args):
    """Invite a family member to the team (Developer role, this app only) so they can be an internal tester."""
    c = load_client()
    email = (args.email or "").strip()
    if not email:
        print("::error::--email is required")
        return 1
    app = find_app(c)
    if not app:
        print("APP RECORD MISSING")
        return 1
    shown = mask_email(email)
    users = c.get_all("/v1/users", {"limit": 200})
    if any((u["attributes"].get("username") or "").lower() == email.lower() for u in users):
        print(f"{shown}: already a team user")
        return 0
    pending = c.get_all("/v1/userInvitations", {"limit": 200})
    if any((i["attributes"].get("email") or "").lower() == email.lower() for i in pending):
        print(f"{shown}: invitation already pending (they must accept the email from Apple)")
        return 0
    body = {"data": {
        "type": "userInvitations",
        "attributes": {
            "email": email,
            "firstName": args.first_name or "Pinny",
            "lastName": args.last_name or "Family",
            "roles": ["DEVELOPER"],
            "allAppsVisible": False,
            "provisioningAllowed": False,
        },
        "relationships": {"visibleApps": {"data": [{"type": "apps", "id": app["id"]}]}},
    }}
    try:
        c.request("POST", "/v1/userInvitations", body=body)
        print(f"{shown}: invited (Developer role, Pinny only). They accept the email from Apple, then get added to the Owner group.")
        return 0
    except ApiError as e:
        fail_line(f"Could not invite {shown}", e)
        return 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p_setup = sub.add_parser("setup", help="bundle ID, capabilities, devices, app record, optional tester")
    p_setup.add_argument("--tester-email", default="", help="Apple ID email of an App Store Connect user")
    p_setup.set_defaults(func=cmd_setup)
    p_revoke = sub.add_parser("revoke-runner-certs", help="CI only: revoke this runner's development certificate")
    p_revoke.set_defaults(func=cmd_revoke_runner_certs)
    p_status = sub.add_parser("status", help="read-only: builds, TestFlight groups, in-app purchases")
    p_status.set_defaults(func=cmd_status)
    p_family = sub.add_parser("family-link", help="external group 'Family' + public link, test info, review submission")
    p_family.add_argument("--contact-phone", default="", help="Beta App Review contact phone (never printed)")
    p_family.add_argument("--contact-first-name", default="")
    p_family.add_argument("--contact-last-name", default="")
    p_family.add_argument("--build", default="", help="build number to submit (default: newest processed build)")
    p_family.set_defaults(func=cmd_family_link)
    p_invite = sub.add_parser("invite-user", help="invite a family member to the team (Developer, this app only)")
    p_invite.add_argument("--email", default="")
    p_invite.add_argument("--first-name", default="")
    p_invite.add_argument("--last-name", default="")
    p_invite.set_defaults(func=cmd_invite_user)
    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
