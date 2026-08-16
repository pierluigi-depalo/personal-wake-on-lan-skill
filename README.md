# alexa-wake-on-lan

> "Alexa, turn on [your PC]." — PC boots before you reach your desk.

A serverless Alexa Smart Home skill that wakes a home PC via Wake-on-LAN. No always-on server, no open router ports, no subscription.

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

Three directives are handled by [`src/index.js`](src/index.js):

- **`Alexa.Discovery.Discover`** — returns the PC as an endpoint with `Alexa.WakeOnLANController` (MAC address) and `Alexa.PowerController` interfaces
- **`Alexa.PowerController.TurnOn` / `TurnOff`** — returns a success response with `powerState: ON/OFF`; Alexa broadcasts the magic packet to the local Echo independently
- **`Alexa.ReportState`** — returns `powerState: ON`

No WoL library is needed in Lambda — the local Echo handles the network broadcast.

---

## Setup & Deployment Guide

For full step-by-step instructions on configuring your PC, setting up Login with Amazon (LWA), deploying the AWS Lambda function, and configuring the Alexa Developer Console, see the **[Skill Setup Guide](docs/setup-guide.md)**.

---

## Acknowledgments

This project is based on the [`alexa-wake-on-lan`](https://github.com/amerker/alexa-wake-on-lan/) project by amerker (MIT Licensed), extended to support multiple devices.

---

## License

[MIT](LICENSE)
