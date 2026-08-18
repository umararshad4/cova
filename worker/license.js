// Licence issuing endpoint. Deploy to Cloudflare Workers (or anything that speaks Web Crypto).
//
// The app never talks to Polar directly. It sends the key the customer bought and the machine it is
// running on; this validates and activates that key with Polar, then returns a short-lived blob
// signed with an Ed25519 key that only this Worker holds. The app verifies that signature offline,
// so a customer on a plane keeps working until the blob's expiry lapses.
//
// Secrets (wrangler secret put ...):
//   POLAR_ACCESS_TOKEN   Polar organisation access token
//   SIGNING_KEY_HEX      32-byte Ed25519 private key, hex. Pairs with License.publicKeyHex.
//
// Deploy:
//   npx wrangler deploy
//
// The app calls: POST /activate  { "key": "...", "machine": "<IOPlatformUUID>" }

const BLOB_DAYS = 45;

function base64url(bytes) {
  let binary = "";
  for (const byte of new Uint8Array(bytes)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function hexToBytes(hex) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}

async function signingKey(env) {
  // Cloudflare Workers support Ed25519 in Web Crypto. The private key is a raw 32-byte seed, so it
  // is imported as a PKCS#8 blob with the standard Ed25519 prefix.
  const prefix = hexToBytes("302e020100300506032b657004220420");
  const seed = hexToBytes(env.SIGNING_KEY_HEX);
  const pkcs8 = new Uint8Array(prefix.length + seed.length);
  pkcs8.set(prefix, 0);
  pkcs8.set(seed, prefix.length);
  return crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"]);
}

async function issue(env, { email, machine, seats }) {
  const payload = {
    tier: "pro",
    email,
    machine,
    issued: Date.now() / 1000,
    expires: Date.now() / 1000 + BLOB_DAYS * 86400,
    seats,
  };
  // Key order must be stable: the app verifies the signature over these exact bytes.
  const json = new TextEncoder().encode(
    JSON.stringify(payload, Object.keys(payload).sort())
  );
  const key = await signingKey(env);
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, key, json);
  return `${base64url(json)}.${base64url(signature)}`;
}

async function polar(env, path, body) {
  const response = await fetch(`https://api.polar.sh${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.POLAR_ACCESS_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return { ok: response.ok, status: response.status, data: await response.json().catch(() => ({})) };
}

export default {
  async fetch(request, env) {
    if (request.method !== "POST") {
      return new Response("POST a licence key to /activate", { status: 405 });
    }

    let input;
    try {
      input = await request.json();
    } catch {
      return json({ error: "Malformed request." }, 400);
    }

    const key = (input.key || "").trim();
    const machine = (input.machine || "").trim();
    if (!key || !machine) return json({ error: "Missing licence key or machine id." }, 400);

    // Polar tracks activations per key, which is what enforces the device limit — doing it in the
    // app would be trivially bypassed.
    const activation = await polar(env, "/v1/customer-portal/license-keys/activate", {
      key,
      organization_id: env.POLAR_ORGANIZATION_ID,
      label: machine,
      conditions: { machine },
    });

    if (!activation.ok) {
      // 403 from Polar is the device limit; anything else is a bad key.
      const message =
        activation.status === 403
          ? "That licence is already active on the maximum number of Macs. Deactivate one first."
          : "That licence key was not recognised.";
      return json({ error: message }, 400);
    }

    const record = activation.data.license_key || activation.data;
    const blob = await issue(env, {
      email: record.customer?.email || record.user?.email || "",
      machine,
      seats: record.limit_activations || 3,
    });

    return json({ license: blob });
  },
};

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
