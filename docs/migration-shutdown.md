# Migration Guide: adding "turn off" to an existing deployment

For deployments that already run the **turn-on-only** version of the skill
(TurnOff answered with `NOT_SUPPORTED_IN_CURRENT_MODE`). Follow the steps in
order; total time is ~30 minutes per PC plus one-time AWS setup.

> Starting from scratch instead? Use [docs/setup-guide.md](setup-guide.md) —
> this document only covers the delta.

---

## What you are adding

| Component | Where it runs | Purpose |
|---|---|---|
| Updated skill Lambda (`src/index.js`) | existing skill Lambda | real `ReportState`, `TurnOff` via command row, `ChangeReport` intake |
| Bridge Lambda (`src/bridge.js`) | new Lambda, public Function URL | authenticates PC polls, keeps heartbeats, hands out shutdown commands |
| Polling agent (`scripts/wol-agent.ps1` / `.sh`) | each PC | 20s poll loop, reports state, executes shutdown |

New DynamoDB rows in your existing `AlexaEventTokens` table (no schema change,
no new table):

- `wol-device/<deviceId>` — heartbeat + power state, written by the agent every 20s
- `cmd-<deviceId>` — pending shutdown command, written by TurnOff, consumed+deleted by the bridge

---

## Step 1 — Update the skill Lambda

1. Open the existing skill Lambda in the console.
2. Replace the inline code with the contents of [`src/index.js`](../src/index.js) → **Deploy**.
3. Optional env var:
   - `DEVICE_STALE_MS` (default `660000` = 11 min): how old a heartbeat may be
     before the device counts as offline. Keep the default unless your PCs
     sleep aggressively.
4. No new IAM permissions are required — the role already has `dynamodb:GetItem`
   and `dynamodb:PutItem` on the table.

**Rollback safety**: at this point nothing changes for users yet. The new code
answers `TurnOff` with `ENDPOINT_UNREACHABLE` until a heartbeat exists, which is
exactly what an offline PC is. `TurnOn`/`Discovery`/`AcceptGrant` behave as before.

## Step 2 — Create the bridge Lambda

1. Lambda Console → **Create function**:
   - Name: `wol-bridge`; Runtime: `Node.js 20.x`; Architecture: `arm64`.
2. Environment variables:
   - `PC_SECRETS` (**required**): JSON map `{ "<deviceId>": "<secret>", ... }`.
     Generate one secret per device: `openssl rand -hex 32`.
     Device ids must match the skill's `WOL_DEVICES[].endpointId` (or `ENDPOINT_ID`).
   - `WOL_SKILL_FUNCTION`: name (not ARN) of the skill Lambda — enables
     ChangeReports + the 30-min warmup. Omit to disable both.
   - `DYNAMODB_TABLE_NAME`: only if not `AlexaEventTokens`.
3. Paste [`src/bridge.js`](../src/bridge.js) into the inline editor → **Deploy**
   (only bundled `@aws-sdk` imports — no zip needed).
4. Add this inline policy to the function's IAM role:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
         "Resource": "arn:aws:dynamodb:REGION:ACCOUNT:table/AlexaEventTokens"
       },
       {
         "Effect": "Allow",
         "Action": "lambda:InvokeFunction",
         "Resource": "arn:aws:lambda:REGION:ACCOUNT:function:alexa-wake-on-lan"
       }
     ]
   }
   ```
5. Configuration → **Function URL** → **Create**, auth type **NONE**.
   Authorization happens in-code via the `x-pc-secret` header; without it every
   request gets `401`. Copy the URL.
6. Smoke test from any machine (expect `{"error":"Unauthorized"}` with 401):
   ```bash
   curl -i -X POST "https://<url>/?deviceId=wol-pc-001" \
        -H "x-pc-secret: WRONG" -d '{"powerState":"ON"}'
   ```

> Do **not** add a Function URL to the skill Lambda — it must stay
> Amazon-invoked only.

## Step 3 — Install the agent on each PC

Full instructions: [`scripts/README.md`](../scripts/README.md). Summary:

**Windows** — Task Scheduler task named `wol-agent`, trigger *At startup*,
run whether user is logged on, highest privileges:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\wol-agent.ps1" ^
  -DeviceId "wol-pc-001" ^
  -ApiUrl "https://<url>.lambda-url.eu-west-1.on.aws/" ^
  -Secret "<device secret>" ^
  -GraceSeconds 10
```

Uncheck *Start the task only if the computer is on AC power*, then start the
task once manually.

**Linux** — install the systemd unit from `scripts/README.md` with
`Environment=DEVICE_ID=...`, `API_URL=...`, `SECRET=...`, then
`sudo systemctl enable --now wol-agent`.

The first poll writes `wol-device/<id>` immediately — verify it appears in
DynamoDB (Table → Explore items) with a fresh `heartbeatAt`.

## Step 4 — Test before going live

**Level 1 — Lambda console** (details and payloads in setup-guide.md → Testing):

- `Alexa.PowerController / TurnOff` with the PC on and polling → expect
  `powerState: OFF` response + a fresh `cmd-<id>` row that vanishes within 20s,
  then the PC shuts down.
- With no/stale heartbeat → expect `ErrorResponse ENDPOINT_UNREACHABLE`.
- `Alexa / ReportState` → expect the real power state + EndpointHealth connectivity.
- Simulate a stale command: write a `cmd-<id>` row with `createdAt` set to a
  day-old epoch ms → next poll must return `{"action":"none"}` and delete the row.

**Level 2 — end to end**: *"Alexa, turn off [PC]"* → Alexa says OK, PC powers
down within ~30s, app shows Off (via ChangeReport).

If discovery state looks stale after the Lambda update, say
*"Alexa, discover my devices"* once so Alexa re-reads the (now retrievable)
capabilities.

## Step 5 — Cleanup / cost notes

- The bridge now sends `{"warmup": true}` to the skill every 30 min, so the
  EventBridge warmup schedule can be deleted (Scheduler is free only the first
  12 months).
- One PC ≈ 130K requests/month (~13% of the always-free 1M); DynamoDB stays far
  inside the 25 RCU/WCU free tier.

## Rollback

1. Redeploy the previous `src/index.js` → TurnOff reverts to
   `NOT_SUPPORTED_IN_CURRENT_MODE`; turn-on is unaffected.
2. Leave or remove the agents: they keep heartbeating harmlessly. If the bridge
   stays deployed, its ChangeReport invocations against the old skill Lambda are
   ignored (the old router answers INVALID_DIRECTIVE but takes no action).
3. To decommission fully: disable the agent task/service, delete the bridge
   Lambda + Function URL, and remove `wol-device/*` / `cmd-*` rows.

## Troubleshooting

See the expanded table at the end of [setup-guide.md](setup-guide.md#troubleshooting)
— covers 401s from the bridge, stale-heartbeat errors, and stale app state.
