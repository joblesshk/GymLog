# GymLog Worker relay

Optional Cloudflare Worker for ASR WebSocket forwarding, Chat Completions streaming and installation-scoped quotas. This repository does not provide a running relay or any provider credentials.

## Local checks

```sh
npm ci --ignore-scripts
npm run check
```

Tests use synthetic identities and mocked upstreams. TypeScript checks and protocol tests do not prove your deployed provider credentials or regional connectivity.

## Deploy your own service

Prerequisites: a Cloudflare account (the free plan supports the SQLite-backed Durable Object used for quotas), a DeepSeek API key with available balance, and a Volcengine speech app with Doubao streaming ASR 2.0 enabled (its App ID and Access Token). `wrangler.jsonc` is preset for `deepseek-flash` and resource ID `volc.seedasr.sauc.duration`; change them only if your account uses different products.

1. Install the dependencies with `npm ci --ignore-scripts` and authenticate your own Cloudflare account with `npx wrangler login`.
2. Review `wrangler.jsonc`: Worker name, upstream endpoints, model allowlist, request limits and Durable Object bindings. Do not place secrets in `vars`. The Worker is served on your `*.workers.dev` subdomain; to use only a Custom Domain, set `workers_dev` to `false` and add the domain.
3. Deploy, then add the secrets. Secrets take effect without redeploying; until they exist every protected route returns 401. Generate the signing secret randomly and enter provider credentials at the interactive prompts:

```sh
npm run deploy
openssl rand -hex 32 | npx wrangler secret put RELAY_TOKEN_SIGNING_SECRET
npx wrangler secret put UPSTREAM_ASR_APP_ID
npx wrangler secret put UPSTREAM_ASR_ACCESS_TOKEN
npx wrangler secret put UPSTREAM_LLM_API_KEY
```

4. Check the deployment with `curl https://<your-worker-host>/healthz`, which should return `{"ok":true,...}`. Then set the app's `GYMLOG_RELAY_BASE_URL` to that HTTPS root URL (see [SETUP](../../docs/SETUP.md)).
5. Test with synthetic utterances and workouts; verify errors, limits and cost controls before use with personal data.

No secrets are included in an example file. If you use `.dev.vars` for local development, it remains ignored and must not be committed. A `.env` file is not the production secret store.

## Routes

- `POST /v1/trial/session`: exchanges a random installation credential and `X-Operation-ID` for a short-lived operation grant.
- `GET /v1/usage`: current installation quota.
- `GET /v1/asr/bigmodel_nostream`: ASR WebSocket flow.
- `POST /v1/cleanup/chat/completions`: streaming language-model request; also used by training reviews.
- `GET /healthz`: liveness only, not proof that an upstream service works.

The client generates its own installation identity and persists it in Keychain. A submitted operation is charged once even if the upstream fails or the request is cancelled; ASR and its following interpretation share the same operation. Training review requests use their own operation. The example quota is 1,000 operations per installation per calendar month in UTC+8, defined in `src/quota.ts`.

## Abuse and cost controls

Installation identities are self-generated, so per-installation quotas alone do not bound cost. The example configuration adds three service-wide controls in `wrangler.jsonc`:

- `GLOBAL_DAILY_ASR_LIMIT` / `GLOBAL_DAILY_CLEANUP_LIMIT`: upstream calls allowed per day (UTC+8) across all installations; once reached, routes return 503 until the next day. Size them to your provider budget.
- `TRIAL_RATE_LIMITER`: Workers rate-limit binding on grant issuance, keyed by client IP (20 per minute by default). Pick your own `namespace_id` if you run several Workers in one account.
- `ALLOWED_SYSTEM_PROMPT_SHA256`: cleanup requests must use one of the app's system prompts, one user message and known fields, so the relay is not a general-purpose model proxy. When an app prompt changes, `CloudPromptPinTests` fails until this list and the test constant are updated; deploy the new hash alongside the old one until old app builds are retired.

## Deployment boundaries

Random installation identities can be regenerated; they are not accounts or hardware attestation. Before making a service broadly accessible, add appropriate enrollment/access controls, platform rate limits, spending controls and monitoring. No deployment or supplier billing is performed by GitHub CI.

The relay handles audio, text and workout context. Review platform/provider logging and retention settings. Do not log request bodies, bearer tokens or health records. See the repository PRIVACY.md and SECURITY.md.
