// End-to-end check against a deployed Worker (staging) or `wrangler dev`.
//
//   API_BASE_URL=https://boulderme-api-staging.runsit.ca \
//   E2E_IDENTITY_KEY=<same value as the Worker secret> APPLE_BUNDLE_ID=<staging bundle id> \
//   node e2e/staging-check.mjs
//
// Three test climbers sign in through the staging-only test login (src/auth/e2e.ts), walk
// invite → accept → chat → block, and probe the isolation and failure paths. Every account it
// creates is deleted at the end, pass or fail. Prints one line per check; exits 1 on any failure.

import { SignJWT } from "jose";
import { createHash, randomUUID } from "node:crypto";

const BASE = (process.env.API_BASE_URL ?? "").replace(/\/$/, "");
const KEY = process.env.E2E_IDENTITY_KEY;
const AUD = process.env.APPLE_BUNDLE_ID;
if (!BASE || !KEY || !AUD) {
  console.error("Set API_BASE_URL, E2E_IDENTITY_KEY and APPLE_BUNDLE_ID.");
  process.exit(2);
}

let failures = 0;
const created = [];

function check(name, ok, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${!ok && detail ? `  (${detail})` : ""}`);
  if (!ok) failures++;
  return ok;
}

async function call(method, path, { token, body, idempotent, installation } = {}) {
  const headers = { "x-client-installation-id": installation ?? randomUUID() };
  if (token) headers.authorization = `Bearer ${token}`;
  if (idempotent) headers["idempotency-key"] = randomUUID();
  if (body !== undefined) headers["content-type"] = "application/json";
  const res = await fetch(`${BASE}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = { raw: text.slice(0, 200) }; }
  return { status: res.status, body: json };
}

const code = (r) => r.body?.error?.code ?? `HTTP ${r.status}`;
const sha256 = (s) => createHash("sha256").update(s).digest("hex");

async function identityToken(sub, nonce, overrides = {}) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ nonce: sha256(nonce) })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuer(overrides.iss ?? "boulderme-e2e")
    .setAudience(AUD)
    .setSubject(sub)
    .setIssuedAt(now)
    .setExpirationTime(now + 300)
    .sign(new TextEncoder().encode(overrides.key ?? KEY));
}

async function nonce(installation) {
  const r = await call("POST", "/v1/auth/nonce", { installation });
  if (r.status !== 201) throw new Error(`nonce: ${code(r)}`);
  return r.body.nonce;
}

async function signIn(label, sub = `e2e-${label}-${randomUUID()}`) {
  const installation = randomUUID();
  const n = await nonce(installation);
  const r = await call("POST", "/v1/auth/apple", {
    installation,
    body: { identity_token: await identityToken(sub, n), authorization_code: `e2e-${randomUUID()}`, nonce: n, client_installation_id: installation },
  });
  if (r.status !== 200) throw new Error(`sign-in ${label}: ${code(r)}`);
  const s = { ...r.body, label, installation, sub };
  if (!created.some((x) => x.account_id === s.account_id)) created.push(s);
  return s;
}

async function setUp(s, name, gymId, grades) {
  const steps = [
    await call("PUT", "/v1/me/profile", {
      token: s.access_token,
      body: { revision: 0, display_name: name, grade_min: grades[0], grade_max: grades[1], styles: ["slab"], intro: "Automated staging check", adult_confirmed: true, discovery_explained: true },
    }),
    await call("PUT", `/v1/me/gyms/${gymId}`, { token: s.access_token, body: { access_type: "membership" } }),
    await call("POST", "/v1/me/availability", {
      token: s.access_token, idempotent: true,
      body: { weekday: 6, start_minute: 600, end_minute: 720, time_zone: "America/Toronto", gym_id: gymId },
    }),
    await call("PUT", "/v1/me/discovery", { token: s.access_token, body: { discoverable: true } }),
  ];
  return steps.every((r) => r.status === 200 || r.status === 201) ? null : steps.map((r) => r.status).join(",");
}

async function run() {
  // Service
  const health = await call("GET", "/v1/health");
  check("health is ok with the database reachable", health.status === 200 && health.body?.status === "ok" && health.body?.database === "ok", JSON.stringify(health.body));

  // Signed-out requests
  check("signed-out request is refused", code(await call("GET", "/v1/me")) === "unauthorized");
  check("garbage bearer token is refused", code(await call("GET", "/v1/me", { token: "not-a-token" })) === "unauthorized");

  // Sign-in failure paths
  {
    const installation = randomUUID();
    const n = await nonce(installation);
    const forged = await identityToken(`e2e-forged-${randomUUID()}`, n, { key: "wrong-key-wrong-key-wrong-key-00" });
    const r = await call("POST", "/v1/auth/apple", { installation, body: { identity_token: forged, authorization_code: "e2e-x", nonce: n } });
    check("token signed with the wrong key is refused", code(r) === "apple_token_invalid", code(r));
    const sub = `e2e-nonce-${randomUUID()}`;
    const ok = await call("POST", "/v1/auth/apple", { installation, body: { identity_token: await identityToken(sub, n), authorization_code: "e2e-x", nonce: n } });
    if (ok.status === 200) created.push({ ...ok.body, label: "nonce", sub });
    const replay = await call("POST", "/v1/auth/apple", { installation, body: { identity_token: await identityToken(sub, n), authorization_code: "e2e-x", nonce: n } });
    check("a used nonce cannot sign in again", ok.status === 200 && code(replay) === "nonce_invalid", `${code(ok)} then ${code(replay)}`);
  }

  // Three climbers at one seeded gym
  const gyms = await call("GET", "/v1/gyms?limit=1", { token: (await signIn("probe")).access_token });
  const gym = gyms.body?.items?.[0];
  if (!check("seeded gyms are listed", gyms.status === 200 && !!gym, code(gyms))) return;
  const [a, b, c] = [await signIn("a"), await signIn("b"), await signIn("c")];
  for (const [s, name, grades] of [[a, "E2E Alex", [3, 5]], [b, "E2E Blair", [4, 6]], [c, "E2E Casey", [2, 4]]]) {
    const err = await setUp(s, name, gym.gym_id, grades);
    check(`${name} sets up a profile, gym and availability`, err === null, err ?? "");
  }

  // Discovery and profiles
  const found = await call("GET", `/v1/discovery?gym_id=${gym.gym_id}&grade_min=4&grade_max=5&limit=50`, { token: a.access_token });
  const ids = (found.body?.items ?? []).map((p) => p.account_id);
  check("discovery finds a matching climber", ids.includes(b.account_id), code(found));
  check("discovery never lists yourself", !ids.includes(a.account_id));
  check("a profile can be opened", (await call("GET", `/v1/profiles/${b.account_id}`, { token: a.access_token })).status === 200);

  // Invitation → chat
  const start = new Date(Date.now() + 3 * 86_400_000).toISOString();
  const inv = await call("POST", "/v1/invitations", {
    token: a.access_token, idempotent: true,
    body: { recipient_account_id: b.account_id, gym_id: gym.gym_id, proposed_start_at: start, note: "Automated staging check" },
  });
  if (!check("an invitation can be sent", inv.status === 201, code(inv))) return;
  const invId = inv.body.invitation_id;
  const incoming = await call("GET", "/v1/invitations?box=incoming", { token: b.access_token });
  check("the recipient sees it", (incoming.body?.items ?? []).some((i) => i.invitation_id === invId));
  check("an outsider cannot read the invitation", code(await call("GET", `/v1/invitations/${invId}`, { token: c.access_token })) === "not_found");
  check("an outsider cannot accept it", code(await call("POST", `/v1/invitations/${invId}/accept`, { token: c.access_token })) === "not_found");
  check("no chat exists before acceptance", ((await call("GET", "/v1/chats", { token: a.access_token })).body?.items ?? []).length === 0);
  const dup = await call("POST", "/v1/invitations", {
    token: a.access_token, idempotent: true, body: { recipient_account_id: b.account_id, gym_id: gym.gym_id, proposed_start_at: start },
  });
  check("only one open invitation per pair", code(dup) === "invitation_already_open", code(dup));

  const accepted = await call("POST", `/v1/invitations/${invId}/accept`, { token: b.access_token });
  if (!check("the recipient accepts and a chat opens", accepted.status === 200 && !!accepted.body?.chat_id, code(accepted))) return;
  const chatId = accepted.body.chat_id;
  const sent = await call("POST", `/v1/chats/${chatId}/messages`, { token: a.access_token, idempotent: true, body: { body: "See you Saturday?" } });
  check("a message can be sent", sent.status === 201, code(sent));
  const msgs = await call("GET", `/v1/chats/${chatId}/messages`, { token: b.access_token });
  check("the other climber receives it", (msgs.body?.items ?? []).some((m) => m.body === "See you Saturday?"), code(msgs));
  check("an outsider cannot read the chat", code(await call("GET", `/v1/chats/${chatId}/messages`, { token: c.access_token })) === "not_found");
  check("an outsider cannot post to the chat", code(await call("POST", `/v1/chats/${chatId}/messages`, { token: c.access_token, idempotent: true, body: { body: "hi" } })) === "not_found");
  check("an empty message is refused", code(await call("POST", `/v1/chats/${chatId}/messages`, { token: a.access_token, idempotent: true, body: { body: "   " } })) === "validation_failed");

  // Block: everything between the pair disappears at once
  const block = await call("PUT", `/v1/blocks/${a.account_id}`, { token: b.access_token });
  check("a climber can block", block.status === 200 || block.status === 201, code(block));
  check("the blocked climber can no longer open the profile", code(await call("GET", `/v1/profiles/${b.account_id}`, { token: a.access_token })) === "not_found");
  check("the blocked climber can no longer read the chat", code(await call("GET", `/v1/chats/${chatId}/messages`, { token: a.access_token })) === "not_found");
  check("the blocked climber can no longer message", code(await call("POST", `/v1/chats/${chatId}/messages`, { token: a.access_token, idempotent: true, body: { body: "hello?" } })) === "not_found");
  const after = await call("GET", `/v1/discovery?gym_id=${gym.gym_id}&limit=50`, { token: a.access_token });
  check("discovery hides the blocker", after.status === 200 && !(after.body.items ?? []).some((p) => p.account_id === b.account_id));
  check("the blocked climber cannot invite", code(await call("POST", "/v1/invitations", {
    token: a.access_token, idempotent: true, body: { recipient_account_id: b.account_id, gym_id: gym.gym_id, proposed_start_at: start },
  })) === "not_found");

  // Sessions: rotation and reuse detection
  const r1 = await call("POST", "/v1/auth/refresh", { installation: c.installation, body: { refresh_token: c.refresh_token } });
  check("a refresh token rotates", r1.status === 200 && r1.body.refresh_token !== c.refresh_token, code(r1));
  const reuse = await call("POST", "/v1/auth/refresh", { installation: c.installation, body: { refresh_token: c.refresh_token } });
  check("replaying a used refresh token is caught", code(reuse) === "refresh_token_reused", code(reuse));
  check("…and signs that session family out", code(await call("GET", "/v1/me", { token: r1.body?.access_token })) === "unauthorized");

  // Data export
  const exp = await call("GET", "/v1/me/export", { token: a.access_token });
  check("a climber can export their data", exp.status === 200, code(exp));
}

async function cleanUp() {
  let ok = true;
  for (const s of [...created]) {
    // A session the reuse check revoked (or an expired token) signs in again as the same climber.
    let r = await call("DELETE", "/v1/me", { token: s.access_token, body: { confirm: "DELETE" } });
    if (r.status === 401) {
      try {
        const fresh = await signIn(s.label, s.sub);
        r = await call("DELETE", "/v1/me", { token: fresh.access_token, body: { confirm: "DELETE" } });
      } catch { /* reported below */ }
    }
    if (r.status !== 202) {
      ok = false;
      console.log(`WARN  could not delete test account ${s.account_id} (${s.label}): ${code(r)}`);
    }
  }
  return ok;
}

try {
  await run();
} catch (err) {
  check("check ran to the end", false, err instanceof Error ? err.message : String(err));
} finally {
  const cleaned = await cleanUp();
  const last = created.find((s) => s.label === "a");
  if (last) check("a deleted account's token stops working", code(await call("GET", "/v1/me", { token: last.access_token })) === "account_deleted");
  if (!cleaned) {
    failures++;
    console.log("Leftover test accounts: remove them with OPERATIONS.md → Deleting a member's data on request.");
  }
  console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
  process.exit(failures === 0 ? 0 : 1);
}
