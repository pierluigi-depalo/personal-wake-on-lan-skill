import crypto from "node:crypto";
import {
  DynamoDBClient,
  GetItemCommand,
  PutItemCommand,
  DeleteItemCommand,
} from "@aws-sdk/client-dynamodb";
import {
  LambdaClient,
  InvokeCommand,
} from "@aws-sdk/client-lambda";

const REGION = process.env.AWS_REGION || "eu-west-1";

const CLIENT_ID = process.env.ALEXA_CLIENT_ID;
const CLIENT_SECRET = process.env.ALEXA_CLIENT_SECRET;

const TABLE_NAME = process.env.DYNAMODB_TABLE_NAME || "AlexaEventTokens";
const EVENT_GATEWAY_URL =
  process.env.ALEXA_EVENT_GATEWAY_URL ||
  "https://api.eu.amazonalexa.com/v3/events";

const LAMBDA_NAME = process.env.ASYNC_LAMBDA_NAME || process.env.AWS_LAMBDA_FUNCTION_NAME;

// Usiamo una chiave fissa per il database, poiché è una skill personale
const DB_KEY = "current_alexa_user";

const dynamodb = new DynamoDBClient({ region: REGION });
const lambda = new LambdaClient({ region: REGION });

function requireConfig() {
  const missing = [];
  if (!CLIENT_ID) missing.push("ALEXA_CLIENT_ID");
  if (!CLIENT_SECRET) missing.push("ALEXA_CLIENT_SECRET");
  if (!TABLE_NAME) missing.push("DYNAMODB_TABLE_NAME");
  if (!LAMBDA_NAME) missing.push("ASYNC_LAMBDA_NAME");
  if (missing.length) {
    throw new Error(`Missing environment variables: ${missing.join(", ")}`);
  }
}

function id() {
  return crypto.randomUUID();
}

function getDirective(event) {
  return event?.directive || {};
}

function getHeader(event) {
  return getDirective(event).header || {};
}

function getEndpoint(event) {
  return getDirective(event).endpoint || {};
}

function getGranteeToken(event) {
  return getEndpoint(event)?.scope?.token ||
    getDirective(event)?.payload?.grantee?.token ||
    null;
}

function normalizeMac(mac) {
  if (typeof mac !== "string") return null;
  const x = mac.trim().toUpperCase().replace(/[^0-9A-F]/g, "");
  if (x.length !== 12) return null;
  return x.match(/.{2}/g).join("-");
}

function getDevices() {
  if (process.env.WOL_DEVICES) {
    try {
      const devices = JSON.parse(process.env.WOL_DEVICES);
      if (!Array.isArray(devices) || devices.length === 0) {
        throw new Error("WOL_DEVICES must be a non-empty JSON array.");
      }
      return devices.map((d, index) => {
        const mac = normalizeMac(d.mac || d.macAddress);
        if (!mac) {
          throw new Error(`Invalid MAC address for device at index ${index} in WOL_DEVICES.`);
        }
        return {
          endpointId: d.endpointId || `wol-device-${index + 1}`,
          friendlyName: d.name || d.friendlyName || `Device ${index + 1}`,
          macAddress: mac,
        };
      });
    } catch (e) {
      console.error("Failed to parse WOL_DEVICES.", e.message);
      throw new Error("Invalid WOL_DEVICES format. It must be a valid JSON array.");
    }
  }

  const mac = normalizeMac(process.env.MAC_ADDRESS);
  if (mac) {
    return [
      {
        endpointId: process.env.ENDPOINT_ID || "wol-pc-001",
        friendlyName: process.env.PC_FRIENDLY_NAME || "PC",
        macAddress: mac,
      },
    ];
  }

  throw new Error(
    "No devices configured. Set WOL_DEVICES env var with a JSON array."
  );
}

// ==========================================
// MODIFICATA: Salvataggio con chiave fissa
// ==========================================
async function saveTokens(tokenData) {
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

// ==========================================
// MODIFICATA: Lettura con chiave fissa
// ==========================================
async function loadTokens() {
  const result = await dynamodb.send(
    new GetItemCommand({
      TableName: TABLE_NAME,
      Key: {
        id: { S: DB_KEY },
      },
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

async function deleteTokens() {
  await dynamodb.send(
    new DeleteItemCommand({
      TableName: TABLE_NAME,
      Key: {
        id: { S: DB_KEY },
      },
    })
  );
}

async function exchangeAuthorizationCode(code) {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code,
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
  });

  const response = await fetch("https://api.amazon.com/auth/o2/token", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
    },
    body: body.toString(),
  });

  const text = await response.text();

  if (!response.ok) {
    throw new Error(`LWA authorization-code exchange failed: ${response.status} ${text}`);
  }

  const data = JSON.parse(text);

  if (!data.access_token || !data.refresh_token) {
    throw new Error(`LWA response did not contain access_token/refresh_token: ${text}`);
  }

  return data;
}

async function refreshAccessToken(refreshToken) {
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
  });

  const response = await fetch("https://api.amazon.com/auth/o2/token", {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
    },
    body: body.toString(),
  });

  const text = await response.text();

  if (!response.ok) {
    throw new Error(`LWA refresh failed: ${response.status} ${text}`);
  }

  const data = JSON.parse(text);

  if (!data.access_token) {
    throw new Error(`LWA refresh did not return access_token: ${text}`);
  }

  return data;
}

// ==========================================
// MODIFICATA: Non chiama più l'API profilo, usa direttamnte i token
// ==========================================
async function getValidToken(granteeToken) {
  // Il granteeToken è l'accessToken temporaneo inviato da Alexa.
  // Se è scaduto, usiamo il nostro refreshToken salvato.
  
  const stored = await loadTokens();

  if (!stored) {
    throw new Error(
      "No stored Event Gateway token for this Alexa customer. Re-enable the add-on to trigger AcceptGrant."
    );
  }

  const margin = 5 * 60 * 1000;

  if (
    stored.accessToken &&
    stored.refreshToken &&
    stored.expiresAt > Date.now() + margin
  ) {
    // Se il nostro token salvato è ancora valido, usiamo questo.
    // (In alternativa potremmo usare direttamente il granteeToken, ma così siamo sicuri che è sincronizzato col DB)
    return stored.accessToken;
  }

  // Altrimenti, facciamo il refresh
  const refreshed = await refreshAccessToken(stored.refreshToken);

  const expiresIn = Number(refreshed.expires_in || 3600);
  const expiresAt = Date.now() + expiresIn * 1000;

  await saveTokens({
    accessToken: refreshed.access_token,
    refreshToken: refreshed.refresh_token || stored.refreshToken,
    expiresAt,
  });

  return refreshed.access_token;
}

function acceptGrantResponse(messageId) {
  return {
    event: {
      header: {
        namespace: "Alexa.Authorization",
        name: "AcceptGrant.Response",
        messageId,
        payloadVersion: "3",
      },
      payload: {},
    },
  };
}

function acceptGrantError(messageId, message) {
  return {
    event: {
      header: {
        namespace: "Alexa.Authorization",
        name: "ErrorResponse",
        messageId,
        payloadVersion: "3",
      },
      payload: {
        type: "ACCEPT_GRANT_FAILED",
        message,
      },
    },
  };
}

async function handleAcceptGrant(event) {
  requireConfig();

  const header = getHeader(event);
  const payload = getDirective(event).payload || {};
  const grant = payload.grant || {};
  const grantee = payload.grantee || {};

  const code = grant.code;
  const granteeToken = grantee.token;

  if (!code || !granteeToken) {
    return acceptGrantError(
      header.messageId,
      "AcceptGrant did not contain the required grant code and grantee token."
    );
  }

  try {
    const tokens = await exchangeAuthorizationCode(code);

    await saveTokens({
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token,
      expiresAt: Date.now() + Number(tokens.expires_in || 3600) * 1000,
    });

    console.log("AcceptGrant: LWA token exchange succeeded.");

    return acceptGrantResponse(header.messageId);
  } catch (error) {
    console.error("AcceptGrant failed:", error);

    return acceptGrantError(
      header.messageId,
      "Failed to retrieve the LWA tokens from the authorization code."
    );
  }
}

function discoveryResponse(messageId) {
  const devices = getDevices();

  const endpoints = devices.map((device) => {
    return {
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
          configuration: {
            MACAddresses: [device.macAddress],
          },
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
        {
          type: "AlexaInterface",
          interface: "Alexa",
          version: "3",
        },
      ],
    };
  });

  return {
    event: {
      header: {
        namespace: "Alexa.Discovery",
        name: "Discover.Response",
        payloadVersion: "3",
        messageId: id(),
      },
      payload: {
        endpoints: endpoints,
      },
    },
  };
}

function deferredResponse(correlationToken) {
  return {
    event: {
      header: {
        namespace: "Alexa",
        name: "DeferredResponse",
        messageId: id(),
        correlationToken,
        payloadVersion: "3",
      },
      payload: {
        estimatedDeferralInSeconds: 15,
      },
    },
  };
}

function stateReport(event) {
  const header = getHeader(event);
  const endpoint = getEndpoint(event);

  return {
    event: {
      header: {
        namespace: "Alexa",
        name: "StateReport",
        messageId: id(),
        correlationToken: header.correlationToken,
        payloadVersion: "3",
      },
      endpoint: {
        endpointId: endpoint.endpointId,
        scope: endpoint.scope,
      },
      payload: {},
    },
    context: {
      properties: [
        {
          namespace: "Alexa.PowerController",
          name: "powerState",
          value: "OFF",
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
      header: {
        namespace: "Alexa",
        name: "ErrorResponse",
        messageId: id(),
        correlationToken: header.correlationToken,
        payloadVersion: "3",
      },
      endpoint: endpoint.endpointId
        ? { endpointId: endpoint.endpointId }
        : undefined,
      payload: {
        type,
        message,
      },
    },
  };
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

  const text = await response.text();

  if (!response.ok) {
    throw new Error(`Alexa Event Gateway rejected event: ${response.status} ${text}`);
  }

  let json = null;
  if (text) {
    try {
      json = JSON.parse(text);
    } catch {}
  }

  return { status: response.status, body: json, raw: text };
}

function buildWakeUpEvent(event, accessToken) {
  const header = getHeader(event);
  const endpoint = getEndpoint(event);

  return {
    event: {
      header: {
        namespace: "Alexa.WakeOnLANController",
        name: "WakeUp",
        messageId: id(),
        correlationToken: header.correlationToken,
        payloadVersion: "3",
      },
      endpoint: {
        scope: {
          type: "BearerToken",
          token: accessToken,
        },
        endpointId: endpoint.endpointId,
      },
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
  const header = getHeader(event);
  const endpoint = getEndpoint(event);

  return {
    event: {
      header: {
        namespace: "Alexa",
        name: "Response",
        messageId: id(),
        correlationToken: header.correlationToken,
        payloadVersion: "3",
      },
      endpoint: {
        scope: {
          type: "BearerToken",
          token: accessToken,
        },
        endpointId: endpoint.endpointId,
      },
      payload: {},
    },
    context: {
      properties: [
        {
          namespace: "Alexa.PowerController",
          name: "powerState",
          value: "ON",
          timeOfSample: new Date().toISOString(),
          uncertaintyInMilliseconds: 0,
        },
      ],
    },
  };
}

function buildFinalError(event, accessToken, message) {
  const header = getHeader(event);
  const endpoint = getEndpoint(event);

  return {
    event: {
      header: {
        namespace: "Alexa",
        name: "ErrorResponse",
        messageId: id(),
        correlationToken: header.correlationToken,
        payloadVersion: "3",
      },
      endpoint: {
        scope: {
          type: "BearerToken",
          token: accessToken,
        },
        endpointId: endpoint.endpointId,
      },
      payload: {
        type: "ENDPOINT_UNREACHABLE",
        message,
      },
    },
  };
}

async function processTurnOnAsync(originalEvent) {
  const granteeToken = getGranteeToken(originalEvent);
  const endpointId = getEndpoint(originalEvent).endpointId;

  try {
    const accessToken = await getValidToken(granteeToken);

    console.log("Sending WakeUp:", { endpointId, gateway: EVENT_GATEWAY_URL });

    const wakeUp = buildWakeUpEvent(originalEvent, accessToken);
    const gatewayResult = await sendGatewayEvent(wakeUp, accessToken);

    console.log("WakeUp accepted by Event Gateway:", { status: gatewayResult.status });

    const finalResponse = buildFinalResponse(originalEvent, accessToken);
    await sendGatewayEvent(finalResponse, accessToken);

    console.log("Final Alexa Response accepted.");
  } catch (error) {
    console.error("WakeUp workflow failed:", error);

    try {
      const accessToken = await getValidToken(granteeToken);
      const finalError = buildFinalError(originalEvent, accessToken, error?.message || "WakeUp failed");
      await sendGatewayEvent(finalError, accessToken);
    } catch (finalError) {
      console.error("Unable to send final ErrorResponse:", finalError);
    }
  }
}

async function startAsyncTurnOn(event) {
  if (!LAMBDA_NAME) {
    throw new Error("ASYNC_LAMBDA_NAME is not configured");
  }

  await lambda.send(
    new InvokeCommand({
      FunctionName: LAMBDA_NAME,
      InvocationType: "Event",
      Payload: Buffer.from(JSON.stringify({ __asyncWakeOnLan: true, originalEvent: event })),
    })
  );
}

async function handleTurnOn(event) {
  const endpointId = getEndpoint(event).endpointId;
  const devices = getDevices();
  
  const targetDevice = devices.find(d => d.endpointId === endpointId);

  if (!targetDevice) {
    return errorResponse(event, "NO_SUCH_ENDPOINT", `Unknown endpointId: ${endpointId}`);
  }

  await startAsyncTurnOn(event);

  return deferredResponse(getHeader(event).correlationToken);
}

async function handleTurnOff(event) {
  return errorResponse(event, "NOT_SUPPORTED_IN_CURRENT_MODE", "TurnOff is not supported by this Wake-on-LAN endpoint.");
}

export const handler = async (event) => {
  try {
    requireConfig();

    if (event?.__asyncWakeOnLan) {
      await processTurnOnAsync(event.originalEvent);
      return;
    }

    const directive = getDirective(event);
    const header = directive.header || {};
    const namespace = header.namespace;
    const name = header.name;

    if (namespace === "Alexa.Authorization" && name === "AcceptGrant") {
      return await handleAcceptGrant(event);
    }

    if (namespace === "Alexa.Discovery" && name === "Discover") {
      return discoveryResponse(header.messageId);
    }

    if (namespace === "Alexa" && name === "ReportState") {
      return stateReport(event);
    }

    if (namespace === "Alexa.PowerController" && name === "TurnOn") {
      return await handleTurnOn(event);
    }

    if (namespace === "Alexa.PowerController" && name === "TurnOff") {
      return await handleTurnOff(event);
    }

    return errorResponse(event, "INVALID_DIRECTIVE", `Unsupported directive: ${namespace}/${name}`);
  } catch (error) {
    console.error("Lambda error:", error);
    return errorResponse(event, "INTERNAL_ERROR", error?.message || "Internal error");
  }
};