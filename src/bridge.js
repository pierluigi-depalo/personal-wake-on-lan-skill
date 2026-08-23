// wol-bridge — public HTTPS endpoint for the PC's polling script.
//
// Deployed as its own Lambda with a Function URL (Auth type NONE; auth enforced
// here via a per-device shared secret in the x-pc-secret header). The Alexa skill
// Lambda stays Amazon-invoked only and is never exposed.
//
// The PC script POSTs once per cycle:
//   POST /?deviceId=<id>   { "powerState": "ON"|"OFF" }
//
// The bridge:
//   1. verifies x-pc-secret against PC_SECRETS[deviceId]
//   2. writes the state row (wol-device/<deviceId>) — same prefix the skill reads
//   3. fires a ChangeReport into the skill on ON<->OFF transitions
//   4. consumes a pending shutdown command (cmd-<deviceId>) if present
//   5. best-effort warms the skill every 30 min (no EventBridge schedule needed)
//
// Env: PC_SECRETS (required, JSON map {deviceId: secret}),
//      DYNAMODB_TABLE_NAME (default AlexaEventTokens),
//      WOL_SKILL_FUNCTION (skill Lambda name for ChangeReport/warmup; unset disables)

import { DynamoDBClient, GetItemCommand, PutItemCommand, DeleteItemCommand } from "@aws-sdk/client-dynamodb";
import { LambdaClient, InvokeCommand } from "@aws-sdk/client-lambda";

const REGION = process.env.AWS_REGION || "eu-west-1";
const TABLE_NAME = process.env.DYNAMODB_TABLE_NAME || "AlexaEventTokens";
const SKILL_FUNCTION = process.env.WOL_SKILL_FUNCTION;
const WARMUP_INTERVAL_MS = 30 * 60 * 1000;
// A shutdown command older than this is discarded instead of executed, so a
// command written while the PC was going offline can never re-fire on next boot.
const CMD_MAX_AGE_MS = 90 * 1000;

let pcSecrets;
try {
  pcSecrets = JSON.parse(process.env.PC_SECRETS || "{}");
} catch {
  pcSecrets = {};
}

const dynamodb = new DynamoDBClient({ region: REGION });
const lambda = SKILL_FUNCTION ? new LambdaClient({ region: REGION }) : null;

let lastWarmupAt = 0;

const ok = (body) => ({ statusCode: 200, body: JSON.stringify(body) });
const err = (statusCode, message) => ({ statusCode, body: JSON.stringify({ error: message }) });

const ddb = {
  async get(key) {
    const res = await dynamodb.send(new GetItemCommand({ TableName: TABLE_NAME, Key: { id: { S: key } } }));
    return res.Item || null;
  },
  async put(key, fields) {
    const Item = { id: { S: key } };
    for (const [k, v] of Object.entries(fields)) {
      Item[k] = typeof v === "number" ? { N: String(v) } : { S: String(v) };
    }
    await dynamodb.send(new PutItemCommand({ TableName: TABLE_NAME, Item }));
  },
  async del(key) {
    await dynamodb.send(new DeleteItemCommand({ TableName: TABLE_NAME, Key: { id: { S: key } } }));
  },
};

function toPlain(item) {
  const out = {};
  for (const [k, v] of Object.entries(item || {})) {
    out[k] = v.S ?? (v.N ? Number(v.N) : v.BOOL);
  }
  return out;
}

async function invokeSkill(payload) {
  if (!lambda) return;
  try {
    await lambda.send(
      new InvokeCommand({ FunctionName: SKILL_FUNCTION, InvocationType: "Event", Payload: JSON.stringify(payload) })
    );
  } catch (e) {
    console.error("Skill invoke failed:", e.message);
  }
}

export const handler = async (event) => {
  // Function URL payload format 2.0: header names are lowercase.
  const deviceId = event.queryStringParameters?.deviceId;
  const secret = event.headers?.["x-pc-secret"];

  if (!deviceId || !secret || pcSecrets[deviceId] !== secret) {
    // Log enough to debug mismatches without ever logging secrets.
    console.error(
      `Unauthorized poll: deviceId=${deviceId || "(none)"} knownDeviceId=${Boolean(pcSecrets[deviceId])} headerPresent=${Boolean(secret)}`
    );
    return err(401, "Unauthorized");
  }

  let body = {};
  try {
    // Function URLs base64-encode some content types (e.g. form-urlencoded).
    const raw = event.isBase64Encoded
      ? Buffer.from(event.body, "base64").toString("utf8")
      : event.body;
    body = raw ? JSON.parse(raw) : {};
  } catch {
    return err(400, "Invalid JSON body");
  }

  try {
    const now = Date.now();

    // 1. State write + ChangeReport on transition.
    const prev = toPlain(await ddb.get(`wol-device/${deviceId}`));
    const newState = body.powerState === "OFF" ? "OFF" : "ON";
    await ddb.put(`wol-device/${deviceId}`, { powerState: newState, heartbeatAt: now });
    if (prev.powerState && prev.powerState !== newState) {
      await invokeSkill({ type: "changeReport", deviceId, state: newState });
    }

    // 2. Consume a pending shutdown command (stale ones are discarded).
    const cmd = toPlain(await ddb.get(`cmd-${deviceId}`));
    if (cmd.action === "shutdown") {
      await ddb.del(`cmd-${deviceId}`);
      if (now - Number(cmd.createdAt) <= CMD_MAX_AGE_MS) {
        return ok({ action: "shutdown" });
      }
    }

    // 3. Best-effort warmup (only on polls where the PC is on).
    if (lambda && now - lastWarmupAt >= WARMUP_INTERVAL_MS) {
      lastWarmupAt = now;
      await invokeSkill({ warmup: true });
    }

    return ok({ action: "none" });
  } catch (e) {
    console.error("Bridge error:", e);
    return err(500, e.message);
  }
};
