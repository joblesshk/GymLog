# GymLog Worker relay

Optional Cloudflare Worker for ASR WebSocket forwarding, Chat Completions streaming and installation-scoped quotas. This repository does not provide a running relay or any provider credentials.

## Local checks

```sh
npm ci --ignore-scripts
npm run check
```

Tests use synthetic identities and mocked upstreams. TypeScript checks and protocol tests do not prove your deployed provider credentials or regional connectivity.

## Deploy your own service

1. Install the dependencies and authenticate your own Cloudflare account with `npx wrangler login`.
2. Review `wrangler.jsonc`: Worker name, upstream endpoints, model allowlist, request limits and Durable Object bindings. Do not place secrets in `vars`. The public `*.workers.dev` URL is disabled by default; attach a Custom Domain or route you control, or deliberately set `workers_dev` to `true`.
3. Create the secrets through Wrangler's interactive input. Supply your own random signing secret and provider credentials:

```sh
npx wrangler secret put RELAY_TOKEN_SIGNING_SECRET
npx wrangler secret put UPSTREAM_ASR_APP_ID
npx wrangler secret put UPSTREAM_ASR_ACCESS_TOKEN
npx wrangler secret put UPSTREAM_LLM_API_KEY
npm run deploy
```

4. Configure the app's `GYMLOG_RELAY_BASE_URL` build setting with that HTTPS root URL. Provider endpoints, models and resource IDs must correspond to the account/product you actually use.
5. Test with synthetic utterances and workouts; verify errors, limits and cost controls before use with personal data.

No secrets are included in an example file. If you use `.dev.vars` for local development, it remains ignored and must not be committed. A `.env` file is not the production secret store.

## Routes

- `POST /v1/trial/session`: exchanges a random installation credential and `X-Operation-ID` for a short-lived operation grant.
- `GET /v1/usage`: current installation quota.
- `GET /v1/asr/bigmodel_nostream`: ASR WebSocket flow.
- `POST /v1/cleanup/chat/completions`: streaming language-model request; also used by training reviews.
- `GET /healthz`: liveness only, not proof that an upstream service works.

The client generates its own installation identity and persists it in Keychain. A submitted operation is charged once even if the upstream fails or the request is cancelled; ASR and its following interpretation share the same operation. Training review requests use their own operation. The example quota is 1,000 operations per installation per calendar month in UTC+8, defined in `src/quota.ts`.

## Deployment boundaries

Random installation identities can be regenerated; they are not accounts or hardware attestation. Before making a service broadly accessible, add appropriate enrollment/access controls, platform rate limits, spending controls and monitoring. No deployment or supplier billing is performed by GitHub CI.

The relay handles audio, text and workout context. Review platform/provider logging and retention settings. Do not log request bodies, bearer tokens or health records. See the repository PRIVACY.md and SECURITY.md.
