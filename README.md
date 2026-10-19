# 🥔 Spud

Zero-footprint reverse tunnel for resource-constrained machines. One command to set up, push notification when it's ready. No VPS, no account, no credit card.

**Uses:**
- [bore.pub](https://github.com/ekzhang/bore) — free public TCP tunnel relay
- [ntfy.sh](https://ntfy.sh) — free push notifications (no account needed)

---

## How it works

```
[Potato] ──bore──▶ bore.pub:RANDOM_PORT
                         │
                         ▼
              ntfy.sh/YOUR_TOPIC
                         │
                         ▼
              📱 "ssh -p 54321 root@bore.pub"
                         │
              you SSH in from anywhere ──────▶ [Potato shell]
```

Potato connects *out* (NAT-friendly), bore assigns a random port, Spud pushes that port to your phone via ntfy. Every reconnect sends a new notification with the new port.

---

## One-time setup (your laptop)

**1. Generate your admin keypair**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/spud_admin -N "" -C "spud-admin"
cat ~/.ssh/spud_admin.pub   # copy this
```

**2. Edit `setup.sh` and `setup.ps1`**
```bash
ADMIN_PUBKEY="ssh-ed25519 AAAA...  spud-admin"   # your pubkey from above
NTFY_TOPIC_PREFIX="spud-XXXXXXXXXXXXXXXX"          # any random string, e.g. spud-f7k2xm9q3r
```
> The ntfy topic per machine will be `$NTFY_TOPIC_PREFIX-$(hostname)`

**3. Subscribe on your phone**
- Install the [ntfy app](https://ntfy.sh/#subscribe) (Android/iOS, free)
- Subscribe to `YOUR_NTFY_TOPIC_PREFIX-*` or individual machine topics

**4. Push to GitHub**
```bash
git init
git add .
git commit -m "Initial Spud setup"
git remote add origin https://github.com/rex/spud.git
git push -u origin main
```

---

## Run on a potato

**Linux / embedded:**
```bash
curl -fsSL https://raw.githubusercontent.com/rex/spud/main/setup.sh | sudo sh
```

**Windows (run PowerShell as Administrator):**
```powershell
iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/rex/spud/main/setup.ps1'))
```

That's it. Within ~30 seconds your phone gets a notification:
```
ssh -p 54321 root@bore.pub  [mybox01 | 14:23]
```

---

## Connecting

```bash
# Use YOUR private key (never leaves your laptop)
ssh -i ~/.ssh/spud_admin -p PORT root@bore.pub
```

Or add to `~/.ssh/config`:
```
Host spud-*
    User root
    IdentityFile ~/.ssh/spud_admin
    StrictHostKeyChecking no
```
Then just: `ssh -p PORT spud-mybox01`

---

## What gets installed on the potato

| Path | What |
|------|------|
| `/etc/spud/bore` | bore binary (~3MB static) |
| `/etc/spud/host_key` | SSH host key (if dropbear was installed) |
| `/etc/spud/tunnel-loop.sh` | Reconnect loop + ntfy notification |
| `/etc/spud/current_port` | Current bore port (updated on each connect) |
| `/root/.ssh/authorized_keys` | Your admin pubkey |
| systemd/OpenRC/inittab/cron | Persistence (whichever is available) |

**Total footprint:** ~3–5 MB (bore binary + dropbear if needed)

---

## Supported platforms

| OS | Init systems |
|----|-------------|
| Linux (Debian, Ubuntu, Alpine, Arch, RHEL…) | systemd, OpenRC, busybox inittab, rc.local, cron |
| Embedded Linux (OpenWRT, buildroot…) | opkg, busybox inittab |
| Windows 7 SP1+ | Scheduled Task (New-ScheduledTask or schtasks.exe fallback) |

**Architectures:** x86_64, aarch64, armv7, armv6, mipsel, mips, i686, riscv64

---

## Security

- **Your private key never touches any script or server.** Only your public key is baked in.
- **bore.pub port is public** but SSH key auth means no key = no shell, period.
- **ntfy topic is your "obscurity" layer** — keep it non-guessable to avoid anyone watching for your port announcements.
- **No passwords** — `PasswordAuthentication no` is enforced on setup.

---

## Removing Spud

```bash
# Linux
systemctl disable --now spud-tunnel.service spud-sshd.service 2>/dev/null
rm -rf /etc/spud /etc/systemd/system/spud-*.service

# Windows (as Administrator)
Unregister-ScheduledTask -TaskName SpudTunnel -Confirm:$false
Remove-Item "$env:ProgramData\spud" -Recurse -Force
```
