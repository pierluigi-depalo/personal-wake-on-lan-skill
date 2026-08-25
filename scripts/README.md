# wol-agent — native polling scripts for "Alexa, turn off [PC]"

Two scripts poll the **wol-bridge** Lambda (a Function URL) for shutdown commands
and keep the device state in DynamoDB. No Node.js, no AWS SDK, no IAM access keys
— just built-in OS tools (PowerShell 5.1 on Windows, bash + curl on Linux).

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

### Unified entry point (recommended)

`wol.ps1` (Windows) / `wol.sh` (Linux/macOS) are thin dispatchers that expose
every management task through one interface; extra arguments are passed straight
through to the underlying script:

```powershell
# Windows (elevated)
.\scripts\wol.ps1 deploy -Region eu-west-1 -AlexaClientId ... -AlexaClientSecret ... -DevicesJson '[...]' -PcSecretsJson '{...}'
.\scripts\wol.ps1 add-dev 'wol-pc-001|Office PC'      # incremental device add (auto MAC on this PC)
.\scripts\wol.ps1 install -DeviceId wol-pc-001 -ApiUrl "https://<url>.../" -Secret REPLACE_ME
.\scripts\wol.ps1 status -Live
.\scripts\wol.ps1 uninstall -Purge
.\scripts\wol.ps1 remove --delete-table               # AWS teardown
```

```bash
# Linux/macOS
sudo bash ./scripts/wol.sh deploy --region eu-west-1 ...          # full AWS deploy
sudo bash ./scripts/wol.sh add-dev 'gaming-rig|Gaming Rig'        # incremental device add
sudo bash ./scripts/wol.sh install --id wol-pc-001 --url "https://<url>.../" --secret REPLACE_ME
bash ./scripts/wol.sh status --live
sudo bash ./scripts/wol.sh uninstall --purge
bash ./scripts/wol.sh remove --delete-table                       # AWS teardown
```

The dispatcher exit code mirrors the delegate script's, so it is safe to use in
CI/scripts.

### Direct calls

**Automated (recommended):** open the **web installer** (`docs/installer/index.html` via GitHub
Pages) — it collects devices/secrets, deploys the AWS side with CloudFormation and prints a
ready-to-paste one-liner that runs `install-agent.ps1` / `install-agent.sh` on the target PC.

From a repo checkout the local installers work standalone:

```powershell
# Windows (elevated) — installs agent + registers the scheduled task
.\scripts\install-agent.ps1 -Install -DeviceId wol-pc-001 `
    -ApiUrl "https://<url>.lambda-url.<region>.on.aws/" -Secret "REPLACE_ME"
.\scripts\install-agent.ps1 -Status -Live      # inspect
.\scripts\install-agent.ps1 -Uninstall -Purge  # remove
```

```bash
# Linux (root) — interactive TUI or env-driven non-interactive
sudo ./scripts/install-agent.sh                       # wizard
sudo DEVICE_ID=wol-pc-001 API_URL="https://<url>.../" SECRET=REPLACE_ME \
     ./scripts/install-agent.sh install               # unattended
sudo ./scripts/install-agent.sh status --live
```

Both also run WoL pre-flight checks (Fast Startup / magic-packet capability on Windows,
`ethtool` Wake-on caps on Linux), test bridge connectivity, and support `repair`.

Manual steps below remain valid if you prefer doing it by hand.

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
