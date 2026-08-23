# alexa-wake-on-lan

> "Alexa, turn on [your PC]." — PC boots before you reach your desk.
> "Alexa, turn off [your PC]." — PC shuts down when you leave it.

A serverless Alexa Smart Home skill that wakes a home PC via Wake-on-LAN and shuts it down via a small resident agent. No always-on server, no open router ports, no subscription — everything stays in the AWS Always-Free tier.

---

## How It Works

The skill uses Amazon's [`Alexa.WakeOnLANController`](https://developer.amazon.com/en-US/docs/alexa/device-apis/alexa-wakeonlancontroller.html) interface. The Lambda function handles device discovery and power control responses, returning your PC's MAC address. Alexa then instructs your local Echo device to broadcast the magic packet directly on the LAN — the cloud never touches your network.

```
"Alexa, turn on [your PC]"
        │
        ▼
  Alexa Cloud calls Lambda
        │
        ▼
  Lambda returns MAC address / success
        │
        ▼
  Alexa instructs local Echo
        │
        ▼
  Echo broadcasts magic packet
        │
        ▼
  PC wakes up ✓
```

**Turn off** works differently — a powered-off PC can't receive commands, so a tiny polling script on the PC bridges the gap:

```
"Alexa, turn off [your PC]"
        │
        ▼
  Alexa Cloud calls Lambda
        │
        ▼
  Lambda writes a shutdown command to DynamoDB
        │
        ▼
  wol-bridge (a public Function URL) exposes it
        │
        ▼
  PowerShell/Bash script on the PC polls every 20s
        │
        ▼
  Script reports OFF, runs `shutdown /s /t 10`
        │
        ▼
  PC powers off ✓
```

The script also writes the PC's power state to DynamoDB every 20 seconds (so `ReportState` and `TurnOff` know whether the PC is on and reachable) and reports state changes through the bridge, so the app stays accurate even when you toggle the PC by hand. No Node.js, no AWS SDK, no IAM access keys on the PC.

Everything stays free: the bridge runs on Lambda (1M requests/month, always free), and one PC polling every 20s uses ~13% of that. See the [Skill Setup Guide](docs/setup-guide.md) for the full build.

---

## Architecture Decisions

### Why `Alexa.WakeOnLANController`

The alternative — Lambda calling a local HTTP endpoint or MQTT broker to send the magic packet — requires port-forwarding or a persistent tunnel, plus an always-on bridge device. `Alexa.WakeOnLANController` uses the Echo (already on your LAN, already always-on) to do the broadcast. No open ports, no bridge.

### Why not a ready-made skill

Services like SayBoot use the same mechanism and work well. The tradeoff: your PC's MAC address lives in their backend. This keeps everything in your own AWS account.

### Alternative: Fritzbox TR-064

AVM Fritzbox routers expose a TR-064 SOAP API (`X_AVM-DE_WakeOnLANByMACAddress`) accessible remotely via `myfritz.net`. Lambda can call it directly — no Echo required, no account linking. Better if you want non-Alexa triggers (scripts, shortcuts, automations). For pure voice use, `WakeOnLANController` is cleaner.

---

## Lambda Overview

Three directive types are handled by [`src/index.js`](src/index.js):

- **`Alexa.Discovery.Discover`** — returns the PC as an endpoint with `Alexa.WakeOnLANController` (MAC address), `Alexa.PowerController` and `Alexa.EndpointHealth` interfaces
- **`Alexa.PowerController.TurnOn` / `TurnOff`** — TurnOn returns a success response with `powerState: ON`; Alexa broadcasts the magic packet to the local Echo independently. TurnOff writes a shutdown command to DynamoDB that the PC's polling script consumes via the bridge, and returns `powerState: OFF`
- **`Alexa.ReportState`** — returns the real `powerState` (ON/OFF) from the DynamoDB row written by the PC's polling script, plus connectivity

No WoL library is needed in Lambda — the local Echo handles the network broadcast.

The **[`scripts/`](scripts/)** directory contains the polling scripts (PowerShell / Bash) that run on the PC: they poll the bridge for shutdown commands, keep the device state in DynamoDB, and report changes back to Alexa via ChangeReport.

---

## Setup & Deployment Guide

For full step-by-step instructions on configuring your PC, setting up Login with Amazon (LWA), deploying the AWS Lambda function, and configuring the Alexa Developer Console, see the **[Skill Setup Guide](docs/setup-guide.md)**.

---

## Acknowledgments

This project is based on the [`alexa-wake-on-lan`](https://github.com/amerker/alexa-wake-on-lan/) project by amerker (MIT Licensed), extended to support multiple devices.

---

## License

[MIT](LICENSE)
