import crypto from "node:crypto";
import {
  DynamoDBClient,
  GetItemCommand,
  PutItemCommand,
} from "@aws-sdk/client-dynamodb";

const REGION = process.env.AWS_REGION || "eu-west-1";
const CLIENT_ID = process.env.ALEXA_CLIENT_ID;
const CLIENT_SECRET = process.env.ALEXA_CLIENT_SECRET;
const TABLE_NAME = process.env.DYNAMODB_TABLE_NAME || "AlexaEventTokens";
const EVENT_GATEWAY_URL =
  process.env.ALEXA_EVENT_GATEWAY_URL || "https://api.eu.amazonalexa.com/v3/events";
const DB_KEY = "current_alexa_user";
const TOKEN_MARGIN_MS = 5 * 60 * 1000;

// --- Shutdown via bridge (DynamoDB command row, consumed by the PC's polling script) ---
const DEVICE_STALE_MS = Number(process.env.DEVICE_STALE_MS || 11 * 60 * 1000);

const dynamodb = new DynamoDBClient({ region: REGION });

// ==========================================
// CACHE: il cuore dell'ottimizzazione.
// Le invocazioni warm saltano completamente DynamoDB e LWA.
// ==========================================
let tokenCache = null;   // { accessToken, refreshToken, expiresAt }
let devicesCache = null;

function requireConfig() {
  const missing = [];
  if (!CLIENT_ID) missing.push("ALEXA_CLIENT_ID");
  if (!CLIENT_SECRET) missing.push("ALEXA_CLIENT_SECRET");
  if (!TABLE_NAME) missing.push("DYNAMODB_TABLE_NAME");
  if (missing.length) {
    throw new Error(`Missing environment variables: ${missing.join(", ")}`);
  }
}

function id() {
  return crypto.randomUUID();
}

const getDirective = (event) => event?.directive || {};
const getHeader = (event) => getDirective(event).header || {};
const getEndpoint = (event) => getDirective(event).endpoint || {};

function normalizeMac(mac) {
  if (typeof mac !== "string") return null;
  const x = mac.trim().toUpperCase().replace(/[^0-9A-F]/g, "");
  if (x.length !== 12) return null;
  return x.match(/.{2}/g).join("-");
}

function getDevices() {
  if (devicesCache) return devicesCache; // parse una sola volta per container

  let devices;
  if (process.env.WOL_DEVICES) {
    devices = JSON.parse(process.env.WOL_DEVICES);
    if (!Array.isArray(devices) || devices.length === 0) {
      throw new Error("WOL_DEVICES must be a non-empty JSON array.");
    }
  } else {
    const mac = normalizeMac(process.env.MAC_ADDRESS);
    if (!mac) throw new Error("No devices configured. Set WOL_DEVICES or MAC_ADDRESS.");
    devices = [{
      endpointId: process.env.ENDPOINT_ID || "wol-pc-001",
      friendlyName: process.env.PC_FRIENDLY_NAME || "PC",
      macAddress: mac,
    }];
  }

  devicesCache = devices.map((d, index) => {
    const mac = normalizeMac(d.mac || d.macAddress);
    if (!mac) throw new Error(`Invalid MAC at index ${index}.`);
    return {
      endpointId: d.endpointId || `wol-device-${index + 1}`,
      friendlyName: d.name || d.friendlyName || `Device ${index + 1}`,
      macAddress: mac,
    };
  });
  return devicesCache;
}

async function saveTokens(tokenData) {
  tokenCache = tokenData; // aggiorna subito la cache, poi persisti
  await dynamodb.send(
    new PutItemCommand({
      TableName: TABLE_NAME,
      Item: {
        id: { S: DB_KEY },
        accessToken: { S: tokenData.accessToken },
        refreshToken: { S: tokenData.refreshToken },
        expiresAt: { N: String(tokenData.expiresAt) },
        updatedAt: { N: String(Date.now()) },
      },
    })
  );
}

async function loadTokens() {
  const result = await dynamodb.send(
    new GetItemCommand({
      TableName: TABLE_NAME,
      Key: { id: { S: DB_KEY } },
      ConsistentRead: true,
    })
  );
  if (!result.Item) return null;
  return {
    accessToken: result.Item.accessToken?.S,
    refreshToken: result.Item.refreshToken?.S,
    expiresAt: Number(result.Item.expiresAt?.N || 0),
  };
}

async function lwaTokenRequest(params, label) {
  const response = await fetch("https://api.amazon.com/auth/o2/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8" },
    body: new URLSearchParams(params).toString(),
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`${label} failed: ${response.status} ${text}`);
  }
  return JSON.parse(await response.text());
}

async function getValidToken() {
  // ===== HOT PATH: 0 I/O, ~0ms =====
  if (tokenCache && tokenCache.expiresAt > Date.now() + TOKEN_MARGIN_MS) {
    return tokenCache.accessToken;
  }

  // Cold start: leggi da DB una sola volta
  const stored = tokenCache || await loadTokens();
  if (!stored) {
    throw new Error("No stored token. Re-enable the skill to trigger AcceptGrant.");
  }

  // Token dal DB ancora valido: usalo senza refresh LWA
  if (
    stored.accessToken &&
    stored.refreshToken &&
    stored.expiresAt > Date.now() + TOKEN_MARGIN_MS
  ) {
    tokenCache = stored;
    return stored.accessToken;
  }

  // Refresh (raro: solo a token scaduto)
  const refreshed = await lwaTokenRequest(
    {
      grant_type: "refresh_token",
      refresh_token: stored.refreshToken,
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    },
    "LWA refresh"
  );

  const tokenData = {
    accessToken: refreshed.access_token,
    refreshToken: refreshed.refresh_token || stored.refreshToken,
    expiresAt: Date.now() + Number(refreshed.expires_in || 3600) * 1000,
  };
  await saveTokens(tokenData);
  return tokenData.accessToken;
}

async function sendGatewayEvent(body, accessToken) {
  const response = await fetch(EVENT_GATEWAY_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const text = await response.text();
    const err = new Error(`Event Gateway rejected event: ${response.status} ${text}`);
    err.status = response.status;
    throw err;
  }
  return response.status; // niente parse del body: risparmia lavoro inutile
}

// ==========================================
// DEVICE STATE (DynamoDB row wol-device/<deviceId>)
// written by the resident agent; read by TurnOff / ReportState / ChangeReport
// ==========================================
const deviceRowKey = (deviceId) => `wol-device/${deviceId}`;

function isFresh(row, now = Date.now()) {
  return !!row?.heartbeatAt && now - Number(row.heartbeatAt) <= DEVICE_STALE_MS;
}

async function getDeviceState(deviceId) {
  const result = await dynamodb.send(
    new GetItemCommand({
      TableName: TABLE_NAME,
      Key: { id: { S: deviceRowKey(deviceId) } },
    })
  );
  if (!result.Item) return null;
  return {
    powerState: result.Item.powerState?.S,
    heartbeatAt: result.Item.heartbeatAt ? Number(result.Item.heartbeatAt.N) : null,
    lastAck: result.Item.lastAck?.M
      ? {
          requestId: result.Item.lastAck.M.requestId?.S,
          status: result.Item.lastAck.M.status?.S,
          ackAt: result.Item.lastAck.M.ackAt ? Number(result.Item.lastAck.M.ackAt.N) : null,
          reason: result.Item.lastAck.M.reason?.S,
        }
      : null,
  };
}

// ==========================================
// SHUTDOWN via bridge command row
// ==========================================
async function putCommand(deviceId) {
  await dynamodb.send(
    new PutItemCommand({
      TableName: TABLE_NAME,
      Item: {
        id: { S: `cmd-${deviceId}` },
        action: { S: "shutdown" },
        requestId: { S: id() },
        createdAt: { N: String(Date.now()) },
      },
    })
  );
}

async function handleTurnOff(event) {
  const endpointId = getEndpoint(event).endpointId;
  const targetDevice = getDevices().find((d) => d.endpointId === endpointId);

  if (!targetDevice) {
    return errorResponse(event, "NO_SUCH_ENDPOINT", `Unknown endpointId: ${endpointId}`);
  }

  try {
    const row = await getDeviceState(endpointId);

    if (row?.powerState === "OFF") {
      // Idempotent: already off (or shutting down), nothing to do.
      return buildPowerResponse(event, "OFF");
    }

    if (!isFresh(row)) {
      // No fresh heartbeat: the PC is off/unreachable — never write a command that
      // would re-fire on next boot.
      return errorResponse(event, "ENDPOINT_UNREACHABLE", "PC is offline (no recent heartbeat).");
    }

    // Write the command; the PC's polling script consumes it within ~20s.
    await putCommand(endpointId);
    return buildPowerResponse(event, "OFF");
  } catch (error) {
    console.error("TurnOff failed:", error);
    return errorResponse(event, "ENDPOINT_UNREACHABLE", error?.message || "Shutdown command failed");
  }
}

// ==========================================
// handler AcceptGrant / Discovery / ReportState
// (invariati nella logica)
// ==========================================
function acceptGrantResponse(messageId) {
  return {
    event: {
      header: { namespace: "Alexa.Authorization", name: "AcceptGrant.Response", messageId, payloadVersion: "3" },
      payload: {},
    },
  };
}

function acceptGrantError(messageId, message) {
  return {
    event: {
      header: { namespace: "Alexa.Authorization", name: "ErrorResponse", messageId, payloadVersion: "3" },
      payload: { type: "ACCEPT_GRANT_FAILED", message },
    },
  };
}

async function handleAcceptGrant(event) {
  requireConfig();
  const header = getHeader(event);
  const payload = getDirective(event).payload || {};
  const code = payload.grant?.code;
  const granteeToken = payload.grantee?.token;

  if (!code || !granteeToken) {
    return acceptGrantError(header.messageId, "Missing grant code or grantee token.");
  }

  try {
    const tokens = await lwaTokenRequest(
      {
        grant_type: "authorization_code",
        code,
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
      },
      "LWA authorization-code exchange"
    );
    if (!tokens.access_token || !tokens.refresh_token) throw new Error("No tokens in LWA response.");

    await saveTokens({
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token,
      expiresAt: Date.now() + Number(tokens.expires_in || 3600) * 1000,
    });
    return acceptGrantResponse(header.messageId);
  } catch (error) {
    console.error("AcceptGrant failed:", error);
    return acceptGrantError(header.messageId, "Failed to retrieve the LWA tokens.");
  }
}

function discoveryResponse() {
  const endpoints = getDevices().map((device) => ({
    endpointId: device.endpointId,
    friendlyName: device.friendlyName,
    description: "Wake-on-LAN Device",
    manufacturerName: "Custom",
    displayCategories: ["COMPUTER"],
    cookie: {},
    capabilities: [
      {
        type: "AlexaInterface",
        interface: "Alexa.WakeOnLANController",
        version: "3",
        properties: {},
        configuration: { MACAddresses: [device.macAddress] },
      },
      {
        type: "AlexaInterface",
        interface: "Alexa.PowerController",
        version: "3",
        properties: {
          supported: [{ name: "powerState" }],
          proactivelyReported: true,
          retrievable: true,
        },
      },
      {
        type: "AlexaInterface",
        interface: "Alexa.EndpointHealth",
        version: "3",
        properties: {
          supported: [{ name: "connectivity" }],
          proactivelyReported: true,
          retrievable: true,
        },
      },
      { type: "AlexaInterface", interface: "Alexa", version: "3" },
    ],
  }));

  return {
    event: {
      header: { namespace: "Alexa.Discovery", name: "Discover.Response", payloadVersion: "3", messageId: id() },
      payload: { endpoints },
    },
  };
}

async function stateReport(event) {
  const header = getHeader(event);
  const endpoint = getEndpoint(event);
  const row = await getDeviceState(endpoint.endpointId);
  const fresh = isFresh(row);
  const powerState = fresh && row.powerState ? row.powerState : "OFF";
  return {
    event: {
      header: { namespace: "Alexa", name: "StateReport", messageId: id(), correlationToken: header.correlationToken, payloadVersion: "3" },
      endpoint: { endpointId: endpoint.endpointId, scope: endpoint.scope },
      payload: {},
    },
    context: {
      properties: [
        {
          namespace: "Alexa.PowerController",
          name: "powerState",
          value: powerState,
          timeOfSample: new Date().toISOString(),
          uncertaintyInMilliseconds: 0,
        },
        {
          namespace: "Alexa.EndpointHealth",
          name: "connectivity",
          value: fresh ? { value: "OK" } : { value: "UNREACHABLE" },
          timeOfSample: new Date().toISOString(),
          uncertaintyInMilliseconds: 0,
        },
      ],
    },
  };
}

function errorResponse(event, type, message) {
  const header = getHeader(event);
  const endpoint = getEndpoint(event);
  return {
    event: {
      header: { namespace: "Alexa", name: "ErrorResponse", messageId: id(), correlationToken: header.correlationToken, payloadVersion: "3" },
      endpoint: endpoint.endpointId ? { endpointId: endpoint.endpointId } : undefined,
      payload: { type, message },
    },
  };
}

function buildWakeUpEvent(event, accessToken) {
  const header = getHeader(event);
  const endpoint = getEndpoint(event);
  return {
    event: {
      header: { namespace: "Alexa.WakeOnLANController", name: "WakeUp", messageId: id(), correlationToken: header.correlationToken, payloadVersion: "3" },
      endpoint: { scope: { type: "BearerToken", token: accessToken }, endpointId: endpoint.endpointId },
      payload: {},
    },
    context: {
      properties: [
        {
          namespace: "Alexa.PowerController",
          name: "powerState",
          value: "OFF",
          timeOfSample: new Date().toISOString(),
          uncertaintyInMilliseconds: 500,
        },
      ],
    },
  };
}

function buildFinalResponse(event, accessToken) {
  return buildPowerResponse(event, "ON", accessToken, 0);
}

// Generic Alexa.PowerController response: used by TurnOn, TurnOff and idempotent paths.
function buildPowerResponse(event, powerState, accessToken, uncertaintyInMilliseconds = 0) {
  const header = getHeader(event);
  const endpoint = getEndpoint(event);
  return {
    event: {
      header: { namespace: "Alexa", name: "Response", messageId: id(), correlationToken: header.correlationToken, payloadVersion: "3" },
      endpoint: { scope: { type: "BearerToken", token: accessToken }, endpointId: endpoint.endpointId },
      payload: {},
    },
    context: {
      properties: [
        {
          namespace: "Alexa.PowerController",
          name: "powerState",
          value: powerState,
          timeOfSample: new Date().toISOString(),
          uncertaintyInMilliseconds,
        },
      ],
    },
  };
}

// ==========================================
// HOT PATH OTTIMIZZATO
// Warm + token valido = 1 sola chiamata HTTPS (Event Gateway)
// ==========================================
async function handleTurnOn(event) {
  const endpointId = getEndpoint(event).endpointId;
  const targetDevice = getDevices().find((d) => d.endpointId === endpointId);

  if (!targetDevice) {
    return errorResponse(event, "NO_SUCH_ENDPOINT", `Unknown endpointId: ${endpointId}`);
  }

  try {
    let accessToken = await getValidToken(); // cache: ~0ms se valido

    try {
      await sendGatewayEvent(buildWakeUpEvent(event, accessToken), accessToken);
    } catch (e) {
      // Retry una sola volta se il token era stato revocato/scaduto
      if (e.status === 401 || e.status === 403) {
        tokenCache = null;
        accessToken = await getValidToken();
        await sendGatewayEvent(buildWakeUpEvent(event, accessToken), accessToken);
      } else throw e;
    }

    return buildFinalResponse(event, accessToken);
  } catch (error) {
    console.error("TurnOn failed:", error);
    return errorResponse(event, "ENDPOINT_UNREACHABLE", error?.message || "WakeUp failed");
  }
}

function buildChangeReport(deviceId, accessToken, powerState, connectivity) {
  const now = new Date().toISOString();
  return {
    event: {
      header: { namespace: "Alexa", name: "ChangeReport", messageId: id(), payloadVersion: "3" },
      endpoint: { scope: { type: "BearerToken", token: accessToken }, endpointId: deviceId },
      payload: {
        change: {
          cause: { type: "PHYSICAL_INTERACTION" },
          properties: [
            {
              namespace: "Alexa.PowerController",
              name: "powerState",
              value: powerState,
              timeOfSample: now,
              uncertaintyInMilliseconds: 0,
            },
          ],
        },
      },
    },
    context: {
      properties: [
        {
          namespace: "Alexa.PowerController",
          name: "powerState",
          value: powerState,
          timeOfSample: now,
          uncertaintyInMilliseconds: 0,
        },
        {
          namespace: "Alexa.EndpointHealth",
          name: "connectivity",
          value: { value: connectivity },
          timeOfSample: now,
          uncertaintyInMilliseconds: 0,
        },
      ],
    },
  };
}

// Called by the resident agent via lambda:Invoke on boot / before shutdown,
// so Alexa's app reflects real state even when the PC is toggled by hand.
async function handleChangeReport(event) {
  const { deviceId, state } = event;
  const targetDevice = getDevices().find((d) => d.endpointId === deviceId);
  if (!targetDevice || !["ON", "OFF"].includes(state)) {
    throw new Error(`Invalid changeReport payload: ${JSON.stringify({ deviceId, state })}`);
  }

  const row = await getDeviceState(deviceId);
  const connectivity = isFresh(row) ? "OK" : "UNREACHABLE";
  const accessToken = await getValidToken();

  try {
    await sendGatewayEvent(buildChangeReport(deviceId, accessToken, state, connectivity), accessToken);
  } catch (e) {
    // Retry once if the token was revoked/expired.
    if (e.status === 401 || e.status === 403) {
      tokenCache = null;
      const freshToken = await getValidToken();
      await sendGatewayEvent(buildChangeReport(deviceId, freshToken, state, connectivity), freshToken);
    } else {
      throw e;
    }
  }
  return { changeReported: true };
}

export const handler = async (event) => {
  try {
    // Warm-up programmato (vedi EventBridge): tiene caldo il container
    // e rigenera il token PRIMA che l'utente parli
    if (event?.warmup) {
      try { await getValidToken(); } catch (e) { console.error("Warmup refresh failed:", e.message); }
      return { warmed: true };
    }

    if (event?.type === "changeReport") return await handleChangeReport(event);

    requireConfig();
    const header = getDirective(event).header || {};
    const { namespace, name } = header;

    if (namespace === "Alexa.Authorization" && name === "AcceptGrant") return await handleAcceptGrant(event);
    if (namespace === "Alexa.Discovery" && name === "Discover") return discoveryResponse();
    if (namespace === "Alexa" && name === "ReportState") return await stateReport(event);
    if (namespace === "Alexa.PowerController" && name === "TurnOn") return await handleTurnOn(event);
    if (namespace === "Alexa.PowerController" && name === "TurnOff") return await handleTurnOff(event);

    return errorResponse(event, "INVALID_DIRECTIVE", `Unsupported: ${namespace}/${name}`);
  } catch (error) {
    console.error("Lambda error:", error);
    return errorResponse(event, "INTERNAL_ERROR", error?.message || "Internal error");
  }
};