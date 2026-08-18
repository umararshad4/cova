# Commerce and kill-switch endpoints

Two small pieces of server, neither of which the app ever waits on.

## `license.js` — issuing

Deploy to Cloudflare Workers. The customer buys through Polar, gets a licence key, and pastes it
into Settings › License. The app posts it here with the Mac's `IOPlatformUUID`; this validates and
activates it against Polar (which is what enforces the device limit) and returns a blob signed with
an Ed25519 key held only by the Worker.

The app verifies that signature **offline**, so losing this endpoint does not take customers
offline — it only stops new activations and refreshes.

```bash
swift ../scripts/make-license-key.swift --generate     # once
npx wrangler secret put SIGNING_KEY_HEX                # the private half
npx wrangler secret put POLAR_ACCESS_TOKEN
npx wrangler deploy
```

Then paste the public half into `License.publicKeyHex`. **That single paste is what switches the
paywall on** — see `License.bypassGate`.

## `flags.json.example` — the kill switch

A static signed file, served from anywhere. When an Apple update breaks a feature built on private
API, sign a new one naming that feature and every running app switches it off within a day, instead
of waiting for a Sparkle update to propagate.

Sign it with the same key:

```bash
swift ../scripts/make-flags.swift <private-key-hex> lockScreen audioTap > flags.txt
```

Host it, then set `FeatureFlags.feedURL` to its URL. Leaving that empty disables the mechanism
entirely, and every failure path leaves all features **on**.
