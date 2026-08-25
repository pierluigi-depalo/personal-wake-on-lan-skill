'use strict';

const RAW_BASE = "https://raw.githubusercontent.com/pierluigi-depalo/personal-wake-on-lan-skill/main";
const STATE_KEY = "wol-installer-state";

const GATEWAY_BY_REGION = {
  "eu-west-1": "",
  "us-east-1": "https://api.amazonalexa.com/v3/events",
  "us-west-2": "https://api.amazonalexa.com/v3/events",
  "ap-northeast-1": "https://api.fe.amazonalexa.com/v3/events",
};

const state = Object.assign(
  { region: "eu-west-1", devices: [], alexaClientId: "", alexaClientSecret: "", bridgeUrl: "" },
  JSON.parse(localStorage.getItem(STATE_KEY) || "{}")
);

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function saveState() {
  localStorage.setItem(STATE_KEY, JSON.stringify(state));
}

function genSecret() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function normalizeMac(raw) {
  const hex = (raw || "").replace(/[^0-9a-fA-F]/g, "").toUpperCase();
  return hex.length === 12 ? hex.match(/../g).join(":") : null;
}

function isValidMac(raw) {
  return /^(?:[0-9A-Fa-f]{2}[:-]?){5}[0-9A-Fa-f]{2}$/.test((raw || "").trim());
}

function psQuote(s) {
  return "'" + String(s).replace(/'/g, "''") + "'";
}

function shQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

/* ---------------- devices editor ---------------- */

function addDevice() {
  state.devices.push({
    endpointId: "wol-pc-" + String(state.devices.length + 1).padStart(3, "0"),
    friendlyName: "",
    mac: "",
    secret: genSecret(),
  });
  saveState();
  renderDevices();
}

function renderDevices() {
  const list = $("#device-list");
  list.textContent = "";
  state.devices.forEach((dev, i) => {
    const card = document.createElement("div");
    card.className = "device-card";

    const mk = (labelText, key, placeholder, type) => {
      const label = document.createElement("label");
      label.textContent = labelText;
      const input = document.createElement("input");
      input.type = type || "text";
      input.value = dev[key] ?? "";
      input.placeholder = placeholder;
      input.addEventListener("input", () => {
        dev[key] = input.value;
        saveState();
        renderOutputs();
      });
      label.appendChild(input);
      return label;
    };

    card.appendChild(mk("Device ID (deviceId)", "endpointId", "office-pc"));
    card.appendChild(mk("Friendly name", "friendlyName", "Office PC"));
    card.appendChild(mk("Wired MAC address", "mac", "AA:BB:CC:DD:EE:FF"));

    const secretLabel = mk("Shared secret (PC_SECRETS)", "secret", "", "password");
    card.appendChild(secretLabel);

    const remove = document.createElement("button");
    remove.className = "remove";
    remove.type = "button";
    remove.textContent = "✕";
    remove.title = "Remove device";
    remove.addEventListener("click", () => {
      state.devices.splice(i, 1);
      saveState();
      renderDevices();
    });
    card.appendChild(remove);
    list.appendChild(card);
  });

  if (!state.devices.length) {
    const p = document.createElement("p");
    p.className = "note";
    p.textContent = "No devices yet — add at least one.";
    list.appendChild(p);
  }
  renderOutputs();
}

function validateDevices() {
  const problems = [];
  const seen = new Set();
  if (!state.devices.length) problems.push("Add at least one device.");
  state.devices.forEach((d) => {
    const tag = d.endpointId || "(unnamed)";
    if (!/^[a-z0-9][a-z0-9-]{1,62}$/i.test(d.endpointId || ""))
      problems.push(`${tag}: device ID must be a short slug (letters/digits/dashes).`);
    if (seen.has(d.endpointId)) problems.push(`${tag}: duplicate device ID.`);
    seen.add(d.endpointId);
    if (!isValidMac(d.mac))
      problems.push(`${tag}: MAC must look like AA:BB:CC:DD:EE:FF.`);
    if (!d.secret || d.secret.length < 32)
      problems.push(`${tag}: secret missing.`);
  });
  return problems;
}

/* ---------------- generated artifacts ---------------- */

function devicesJson() {
  return JSON.stringify(
    state.devices.map((d) => ({
      endpointId: d.endpointId.trim(),
      friendlyName: (d.friendlyName || d.endpointId).trim(),
      macAddress: normalizeMac(d.mac),
    }))
  );
}

function pcSecretsJson() {
  return JSON.stringify(
    Object.fromEntries(state.devices.map((d) => [d.endpointId.trim(), d.secret]))
  );
}

function templateUrl() {
  const path = location.pathname.replace(/[^/]*$/, "");
  return location.origin + path + "wol-stack.template.json";
}

function cfnDeepLink() {
  const region = state.region;
  const params = new URLSearchParams();
  params.set("templateURL", templateUrl());
  params.set("stackName", "wol-stack");
  if (state.alexaClientId) params.set("param_AlexaClientId", state.alexaClientId);
  try { params.set("param_DevicesJson", devicesJson()); } catch (_) {}
  params.set("param_PagesOrigin", location.origin);
  // Secrets deliberately NOT embedded (they would land in browser history).
  return (
    `https://${region}.console.aws.amazon.com/cloudformation/home?region=${region}` +
    `#/stacks/create/review?${params.toString()}`
  );
}

function deployOneLinerPs() {
  const url = `${RAW_BASE}/scripts/deploy-aws.ps1`;
  const args = [
    "-Region", psQuote(state.region),
    "-AlexaClientId", psQuote(state.alexaClientId),
    "-AlexaClientSecret", psQuote(state.alexaClientSecret),
    "-DevicesJson", psQuote(devicesJson()),
    "-PcSecretsJson", psQuote(pcSecretsJson()),
  ].join(" ");
  return (
    `iwr ${url} -OutFile "$env:TEMP\\deploy-wol.ps1"; ` +
    `powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\\deploy-wol.ps1" ${args}`
  );
}

function deployOneLinerSh() {
  const url = `${RAW_BASE}/scripts/deploy-aws.sh`;
  const gw = GATEWAY_BY_REGION[state.region];
  return (
    `curl -fsSL ${url} -o /tmp/deploy-wol.sh && bash /tmp/deploy-wol.sh` +
    ` --region ${state.region}` +
    ` --client-id ${shQuote(state.alexaClientId)}` +
    ` --client-secret ${shQuote(state.alexaClientSecret)}` +
    ` --devices ${shQuote(devicesJson())}` +
    ` --secrets ${shQuote(pcSecretsJson())}` +
    (gw ? ` --gateway-url ${gw}` : "")
  );
}

function agentInstallWin(dev) {
  const url = `${RAW_BASE}/scripts/install-agent.ps1`;
  return (
    `iwr ${url} -OutFile "$env:TEMP\\wol-install.ps1"; ` +
    `powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\\wol-install.ps1" ` +
    `-Install -DeviceId ${psQuote(dev.endpointId)} ` +
    `-ApiUrl ${psQuote(state.bridgeUrl || "<bridge-function-url>")} ` +
    `-Secret ${psQuote(dev.secret)}`
  );
}

function agentInstallLinux(dev) {
  const url = `${RAW_BASE}/scripts/install-agent.sh`;
  const bridge = state.bridgeUrl || "<bridge-function-url>";
  return (
    `curl -fsSL ${url} | sudo env DEVICE_ID=${shQuote(dev.endpointId)} ` +
    `API_URL=${shQuote(bridge)} SECRET=${shQuote(dev.secret)} bash -s -- install\n` +
    `# or interactively:\n# curl -fsSL ${url} -o /tmp/wol-install.sh && sudo bash /tmp/wol-install.sh`
  );
}

function setPre(id, text) {
  $(id).textContent = text;
}

function renderOutputs() {
  const problems = validateDevices();
  const ok = problems.length === 0;
  $("#devices-validation").textContent = problems.join(" ");
  setPre("#out-wol-devices", ok ? devicesJson() : "# fix validation errors above");
  setPre("#out-pc-secrets", ok ? pcSecretsJson() : "# fix validation errors above");

  setPre("#out-deploy-ps", ok && state.alexaClientId ? deployOneLinerPs() : "# fill in devices + client id first");
  setPre("#out-deploy-sh", ok && state.alexaClientId ? deployOneLinerSh() : "# fill in devices + client id first");

  $("#cfn-link").href = cfnDeepLink();

  // Agent step: device picker + bridge url field
  const sel = $("#agent-device");
  const prev = sel.value;
  sel.textContent = "";
  state.devices.forEach((d, i) => {
    const opt = document.createElement("option");
    opt.value = String(i);
    opt.textContent = d.endpointId + ((d.friendlyName) ? ` (${d.friendlyName})` : "");
    sel.appendChild(opt);
  });
  if (prev) sel.value = prev;

  // Status form prefill from first device
  if (!$("#st-device").value && state.devices[0]) {
    $("#st-device").value = state.devices[0].endpointId;
    $("#st-secret").value = state.devices[0].secret;
  }

  renderAgentOutput();
}

function renderAgentOutput() {
  const idx = parseInt($("#agent-device").value || "0", 10);
  const dev = state.devices[idx];
  if (!dev) {
    setPre("#out-agent-win", "# add a device first");
    setPre("#out-agent-linux", "# add a device first");
    return;
  }
  setPre("#out-agent-win", agentInstallWin(dev));
  setPre("#out-agent-linux", agentInstallLinux(dev));
}

/* ---------------- wiring ---------------- */

document.addEventListener("click", (e) => {
  const copyBtn = e.target.closest(".copy");
  if (copyBtn) {
    const pre = document.getElementById(copyBtn.dataset.copy);
    navigator.clipboard.writeText(pre.textContent).then(() => {
      const old = copyBtn.textContent;
      copyBtn.textContent = "Copied!";
      setTimeout(() => (copyBtn.textContent = old), 1200);
    });
  }
});

$$(".tab").forEach((tab) =>
  tab.addEventListener("click", () => {
    $$(".tab").forEach((t) => t.classList.toggle("active", t === tab));
    $$("[data-pane]").forEach((pane) => {
      pane.hidden = pane.dataset.pane !== tab.dataset.tab;
    });
  })
);

$("#add-device").addEventListener("click", addDevice);
$("#region").addEventListener("change", (e) => {
  state.region = e.target.value;
  saveState();
});
$("#alexa-client-id").addEventListener("input", (e) => {
  state.alexaClientId = e.target.value;
  saveState();
  renderOutputs();
});
$("#agent-device").addEventListener("change", renderAgentOutput);

$("#status-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const result = $("#status-result");
  const verdict = $("#status-verdict");
  const detail = $("#status-detail");
  result.hidden = false;
  result.className = "status-result";

  if (!state.bridgeUrl) {
    result.classList.add("err");
    verdict.textContent = "Enter your bridge Function URL in Step 4 first.";
    detail.textContent = "";
    return;
  }
  verdict.textContent = "Checking…";

  const url = state.bridgeUrl.replace(/\/+$/, "") +
    "?deviceId=" + encodeURIComponent($("#st-device").value.trim());
  const started = performance.now();
  try {
    const resp = await fetch(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-pc-secret": $("#st-secret").value,
      },
      body: JSON.stringify({ powerState: "ON" }),
    });
    const ms = Math.round(performance.now() - started);
    let body;
    try { body = await resp.json(); } catch (_) { body = await resp.text(); }
    if (resp.status === 401) {
      result.classList.add("err");
      verdict.textContent = "Unauthorized (401) — wrong secret or deviceId.";
    } else if (!resp.ok) {
      result.classList.add("err");
      verdict.textContent = `Bridge answered HTTP ${resp.status}.`;
    } else if (body && body.action === "shutdown") {
      result.classList.add("err");
      verdict.textContent =
        "Online — but a fresh SHUTDOWN command was pending! The target PC will power off within seconds.";
    } else {
      result.classList.add("ok");
      verdict.textContent = `Online ✓ — heartbeat written (${ms} ms). The PC shows ON in the Alexa app.`;
    }
    detail.textContent = typeof body === "string" ? body : JSON.stringify(body, null, 2);
  } catch (err) {
    result.classList.add("err");
    verdict.textContent = "Request failed — offline, wrong URL, or CORS blocked.";
    detail.textContent =
      err.message +
      "\n\nIf you deployed manually (Option B), make sure the Function URL's" +
      "\nCORS AllowOrigin includes: " + location.origin +
      "\nThe CloudFormation stack sets this automatically.";
  }
  saveState();
});

$("#bridge-url").addEventListener("input", (e) => {
  state.bridgeUrl = e.target.value.trim();
  saveState();
  renderAgentOutput();
});
$("#reset-state").addEventListener("click", () => {
  localStorage.removeItem(STATE_KEY);
  location.reload();
});

/* ---------------- routing ---------------- */

function showStep(id) {
  $$(".step").forEach((s) => (s.hidden = s.id !== id));
  $$(".step-link").forEach((a) =>
    a.classList.toggle("active", a.dataset.step === id)
  );
}

window.addEventListener("hashchange", () => {
  const id = location.hash.slice(1) || "prereqs";
  if (document.getElementById(id)) showStep(id);
});

/* ---------------- init ---------------- */

$("#region").value = state.region;
$("#alexa-client-id").value = state.alexaClientId;
$("#bridge-url").value = state.bridgeUrl;
renderDevices();
showStep(location.hash.slice(1) || "prereqs");
