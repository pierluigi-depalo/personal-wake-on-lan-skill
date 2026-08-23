# wol-agent — native polling scripts for "Alexa, turn off [PC]"

Two scripts poll the **wol-bridge** Lambda (a Function URL) for shutdown commands
and keep the device state in DynamoDB. No Node.js, no AWS SDK, no IAM access keys
— just built-in OS tools (PowerShell 5.1 on Windows, curl + jq on Linux).

## How it works

Every 20 seconds the script POSTs to the bridge:

```
POST https://<url>.lambda-url.<region>.on.aws/?deviceId=<id>
     x-pc-secret: <secret>
     { "powerState": "ON" }
```

The bridge verifies the secret, writes the heartbeat to DynamoDB, and replies
`{ "action": "shutdown" }` when a fresh shutdown command is pending. On
`shutdown` the script reports `OFF` (which triggers an Alexa ChangeReport so the
app updates instantly) and then powers the PC down. Commands older than 90s are
discarded by the bridge instead of executed, so one written while the PC was
going offline can never re-fire on next boot.

## Setup

1. Create the `wol-bridge` Lambda + Function URL (see `docs/setup-guide.md` Step 6).
2. Copy the Function URL and your device's secret into the script.
3. Install the script to run at boot (below).

## Windows — Task Scheduler

1. Open **Task Scheduler** → *Create Task*.
2. **General**: name `wol-agent`; *Run whether user is logged on or not*; *Run with highest privileges*.
3. **Triggers**: *At startup*.
4. **Actions**: *Start a program* →
   - Program: `powershell.exe`
   - Arguments:
     ```
     -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\scripts\wol-agent.ps1" -DeviceId "wol-pc-001" -ApiUrl "https://<url>.lambda-url.<region>.on.aws/" -Secret "REPLACE_ME"
     ```
5. **Conditions**: uncheck *Start the task only if the computer is on AC power*.

## Linux — systemd

```ini
# /etc/systemd/system/wol-agent.service
[Unit]
Description=Alexa Wake-on-LAN agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DEVICE_ID=wol-pc-001
Environment=API_URL=https://<url>.lambda-url.<region>.on.aws/
Environment=SECRET=REPLACE_ME
ExecStart=/opt/wol-agent/wol-agent.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
chmod +x /opt/wol-agent/wol-agent.sh
sudo systemctl daemon-reload
sudo systemctl enable --now wol-agent
```

## Security

- The `x-pc-secret` header is the **only** thing protecting the bridge. Keep it
  per-device (each device gets its own secret in the bridge's `PC_SECRETS` env
  var) and treat it like a password.
- The secret grants: the ability to report that device's state and to consume its
  shutdown command. It does **not** grant any AWS access.
- The script keeps polling through network failures (it logs and retries) and
  exits only when a shutdown is actually issued.

## Notes

- The bridge's Function URL auth is set to **NONE** — authorization is enforced
  in the Lambda code via the secret header. Do not reuse this pattern for
  anything holding sensitive data.
- `shutdown /s /t N` on Windows waits `N` seconds; the Linux script sleeps
  `GRACE` seconds (default 10) and then runs `shutdown -h now`.
