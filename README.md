# Radiatore

### Server fans that follow your GPU's temperature on a Supermicro board, when the NVIDIA GPU lives inside a VM.

Supermicro's fan control has no idea a GPU needs airflow, and the best fan
controller for these boards can't read a GPU that's passed through to a
virtual machine. This is how I made the server's fans follow my passively
cooled Tesla P100's temperature anyway, with a fail-safe that runs the fans
flat out whenever it can't get a reading. It took a few days to get right.

It isn't P100-specific: it works with any NVIDIA GPU that `nvidia-smi` can read
inside the VM, and with several of them.

> **Proxmox host + passed-through GPU + smfc + one very restricted SSH key.**

---

## Table of Contents

- [TL;DR](#tldr)
- [Will It Work With My GPU?](#will-it-work-with-my-gpu)
- [The Problem](#the-problem)
- [How It Works](#how-it-works)
- [My Setup](#my-setup)
- [Step 1: The VM Side](#step-1-the-vm-side)
- [Step 2: The Host Side](#step-2-the-host-side)
- [Step 3: smfc Config](#step-3-smfc-config)
- [Finding Fan Resonance](#finding-fan-resonance)
- [Results](#results)
- [Gotchas](#gotchas)
- [Files](#files)
- [Credits](#credits)
- [License](#license)

---

# TL;DR

- A passive GPU like the Tesla P100 has **no fan**. It relies on the server's
  chassis fans, and stock Supermicro fan modes don't follow GPU temperature.
  Cards with their own fans benefit too: the case fans can ramp with GPU load.
- [smfc](https://github.com/petersulyok/smfc) can drive Supermicro fan zones
  from GPU temperature, by calling `nvidia-smi`. But with the GPU passed
  through to a VM, the host has **no NVIDIA driver and no `nvidia-smi`**.
- So smfc calls a small stand-in script instead, `smfc-gpu-temp`, which asks the
  VM for the temperature over SSH. With several GPUs, it reports the hottest.
- The SSH key can only run **one** `nvidia-smi` query, and only from the host.
- **Any failure reads as 90 °C**, so the GPU fans go to 100%. That covers the VM
  being off, SSH timing out, or junk output.

---

# Will It Work With My GPU?

Probably, if you have all three of these:

| Need | Why |
|---|---|
| A **Supermicro board** smfc supports | smfc drives the fans through Supermicro's IPMI commands. Check its [supported boards](https://github.com/petersulyok/smfc). |
| An **NVIDIA GPU passed through to a VM** | Any card the VM's driver supports: Tesla and other datacenter cards, Quadro/RTX workstation cards, GeForce. Passive cards gain the most. |
| **SSH from the host to that VM** | Proxmox is my setup, but ESXi, Unraid, plain KVM and others work the same way: the host only needs to reach the VM over SSH. |

**Several GPUs in one VM:** the key's `nvidia-smi` query returns one line per
GPU, and the script reports the **hottest** one. If any GPU's reading is
missing or garbage, the whole read counts as failed and the fans go to 100%.
All your GPU fans follow the hottest card. That's the safe default for cards
sharing a chassis.

**GPUs in different VMs:** use one key and VM address per VM, as separate
copies of the script with their own `/etc/default` file. Point a separate
smfc `[GPU:n]` controller at each copy.

**Tested on:** a Tesla P100 16 GB PCIe (passive) in a Supermicro X10DRL-CT.
If you get it running on other hardware, [open an issue](https://github.com/wendsell/radiatore/issues)
and I'll add it here.

---

# The Problem

On a Supermicro X10 board, the BMC (the IPMI controller) runs the fans in a
few fixed modes: Standard, Optimal, Heavy IO, Full. None of them look at a PCIe
GPU. A Tesla P100 is built for servers that force air through it, so it has a
heatsink and no fan. Under load it heats up fast, and it slows itself down
at 82 °C and shuts down at 85 °C.

smfc fixes the "fans don't follow the GPU" part. It's a daemon that drives
Supermicro fan zones through `ipmitool`, with separate controllers for CPU,
disks and GPUs. Its GPU controller reads temperatures with `nvidia-smi`.

That's where it breaks with GPU passthrough. The P100 is handed to a VM with
`vfio-pci`, so:

- the Proxmox host must **not** load an NVIDIA driver (it would grab the card
  away from the VM), so there's no `nvidia-smi` on the host, and
- the only place the temperature can be read is inside the VM.

smfc runs on the host because that's where the BMC is. The GPU lives in the
VM. Something has to carry one number across.

---

# How It Works

```text
 Proxmox host                                    GPU VM
 ┌──────────────────────────────┐   SSH        ┌─────────────────────────────┐
 │ smfc [GPU] controller         │  (key that   │ user gputemp                │
 │   nvidia_smi_path ──► smfc-gpu-temp ──────────► authorized_keys:          │
 │                     (4 s max) │  can only    │   command="nvidia-smi       │
 │   ◄── "53"  or  "90" on error │  run one     │   --query-gpu=temperature…" │
 │ ipmitool ──► BMC ──► fans     │  query)      │ Tesla P100 (vfio)           │
 └──────────────────────────────┘              └─────────────────────────────┘
```

smfc lets you point its GPU controller at any program instead of the real
`nvidia-smi` (`nvidia_smi_path`). It passes its usual arguments and reads a
temperature back. `smfc-gpu-temp`:

1. SSHes to the VM with a dedicated key, with a hard 4-second limit
   (`timeout -k 1 4 ssh …`).
2. Ignores smfc's arguments. The VM decides what runs, not the host.
3. Checks the answer is a sane number (5–120 °C). With several GPUs, every
   line has to be, and the hottest one is reported.
4. On **any** failure, prints `90` instead. That's above smfc's `max_temp`, so
   the GPU fan zone goes to 100%.
5. Logs only when the state changes ("read FAILED" / "read OK again"), not
   every poll.

The time limit matters more than it looks. smfc runs the program **without a
timeout**, and all of smfc's controllers share one loop. A hung SSH call would
freeze CPU fan control too, not just the GPU's. So the script always returns
within about 4 seconds, whatever happens.

On the VM, the key is locked down in `authorized_keys`:

```conf
restrict,from="<host ip>",command="/usr/bin/nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits" ssh-ed25519 AAAA… smfc-gpu-temp@host
```

- `command=` means the key runs that query and nothing else, whatever the
  client asks for.
- `from=` means the key only works from the host's address.
- `restrict` turns off port forwarding, agent forwarding, X11 and the PTY.

The account itself (`gputemp`) is a locked system user with no password.

---

# My Setup

| Part | What |
|---|---|
| Board | Supermicro **X10DRL-CT** |
| CPUs | 2 × Xeon E5-2690 v4 |
| GPU | **Tesla P100 16 GB PCIe**, passive, `vfio-pci` passthrough |
| Host | Proxmox VE 9 |
| GPU VM | Ubuntu 24.04, NVIDIA **580-server** driver (last branch with Pascal support), packages held |
| Fan control | **smfc 6.4.2** |
| Fan zones | zone 0 = FAN1–FAN6 (CPUs and system), zone 1 = FANA + FANB (in front of the P100) |

---

# Step 1: The VM Side

Create a locked system user to own the key:

```sh
sudo useradd --system --home-dir /var/lib/gputemp --create-home --shell /bin/sh gputemp
sudo passwd -l gputemp
sudo install -d -m 700 -o gputemp -g gputemp /var/lib/gputemp/.ssh
```

Check that the user can read the GPU:

```sh
sudo -u gputemp /usr/bin/nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits
```

The `authorized_keys` line goes in after step 2 creates the key. There's a
template in [`examples/authorized_keys`](examples/authorized_keys). The file
must be owned by `gputemp` with mode `600`.

---

# Step 2: The Host Side

Make the key, and pin the VM's host key so the script never trusts a new one:

```sh
install -d -m 700 /etc/smfc
ssh-keygen -t ed25519 -N '' -C "smfc-gpu-temp@$(hostname)" -f /etc/smfc/gpu-temp.key
ssh-keyscan -t ed25519 <vm ip> > /etc/smfc/gpu-vm.known_hosts   # check the fingerprint matches the VM's
```

Put `/etc/smfc/gpu-temp.key.pub` into the VM's `authorized_keys` line from step 1.

Install the script and tell it where the VM is:

```sh
install -m 755 bin/smfc-gpu-temp /usr/local/bin/smfc-gpu-temp
echo 'VM_HOST="gputemp@<vm ip>"' > /etc/default/smfc-gpu-temp
```

Test both outcomes:

```sh
/usr/local/bin/smfc-gpu-temp     # VM up: prints the GPU temperature, e.g. 53
# shut the VM down, or point VM_HOST somewhere wrong, then run it again:
/usr/local/bin/smfc-gpu-temp     # prints 90 within ~4 s
journalctl -t smfc-gpu-temp      # "GPU temp read FAILED ..., reporting 90C fail-safe"
```

> [!WARNING]
> Never install the NVIDIA driver on the Proxmox host. With `vfio-pci`
> passthrough, the VM owns the card.

---

# Step 3: smfc Config

Install smfc using [its own instructions](https://github.com/petersulyok/smfc).
My full config is in [`examples/smfc.conf`](examples/smfc.conf). The important
parts:

**GPU zone (zone 1, FANA/FANB), driven by the P100:**

```ini
[GPU]
enabled=1
ipmi_zone=1
gpu_type=nvidia
nvidia_smi_path=/usr/local/bin/smfc-gpu-temp
min_temp=45.0
max_temp=75.0
min_level=35
max_level=100
```

Fans reach 100% by 75 °C, leaving room before the P100's own slowdown at 82 °C.
The fail-safe reading of 90 °C is past `max_temp`, so a failure always means
100%.

**Chassis boost (zone 0 also follows the GPU):** the CPU fans move a lot of the
air that goes through the GPU, so a second GPU controller also bids on zone 0.
smfc lets several controllers share a zone and applies whichever asks for
more:

```ini
[GPU:1]
enabled=1
ipmi_zone=0
nvidia_smi_path=/usr/local/bin/smfc-gpu-temp
control_function=60-35, 61-40, 64-40, 65-45, 67-45, 68-50, 69-50, 70-65, 74-65, 75-70
```

`control_function` is a list of `temperature-level` points. This curve
deliberately **skips 55–60% duty**, where my chassis fans resonate (see the
next section), and stops at 70%, which is as loud as I'm willing to go.
The CPU controller on zone 0 uses the same trick.

In smfc's log you can watch the two controllers compete:

```console
Shared IPMI zone [0]: new level = 40% (winner: CPU=40%/48.0C, losers: GPU:1=35%/53.0C)
IPMI zone [1]: new level = 48% (GPU=53.0C)
```

> [!IMPORTANT]
> Keep zone 0 at 35% or above. At 30% my fans ran at about 1000 RPM, and the
> BMC's lowest RPM threshold is 700. If a fan dips under it, the BMC assumes
> the fan has failed and runs **everything** at 100%.

---

# Finding Fan Resonance

Some duty levels make the chassis hum or buzz. [`tools/fan_sweep.sh`](tools/fan_sweep.sh)
finds them. It stops smfc, holds the GPU zone at a safe level, steps zone 0
from 35% to 100% in 5% steps, and logs the RPM of every fan at each step.
It aborts if a CPU passes 75 °C, bumps the GPU zone to 100% if the P100 passes
70 °C, and always restarts smfc when it exits.

```sh
HOLD=20 tools/fan_sweep.sh     # 20 s per step; listen while it runs
```

My sweep (zone 0, FAN1–FAN6):

| Duty | FAN1 | FAN2 | FAN3 | FAN4 | FAN5 | FAN6 |
|---:|---:|---:|---:|---:|---:|---:|
| 35% | 1200 | 1200 | 1300 | 2000 | 1100 | 1200 |
| 50% | 1600 | 1700 | 1700 | 2700 | 1700 | 1700 |
| 55% | 1700 | 1800 | 1800 | 3000 | 1800 | 1900 |
| 60% | 1800 | 1900 | 1900 | 3200 | 2000 | 2000 |
| 70% | 2000 | 2100 | 2200 | 3600 | 2300 | 2400 |
| 100% | 2600 | 2700 | 3000 | 4900 | 3400 | 3500 |

The RPM numbers climb smoothly. Resonance is something you **hear**, not see
in the readings. For me it was 55–60%, so both zone 0 curves jump from 50%
straight to 65%.

---

# Results

**Idle,** live readings from both sides:

| Reading | Value |
|---|---|
| `nvidia-smi` inside the VM | 54 °C, 34 W |
| `smfc-gpu-temp` on the host | 53 °C |
| Zone 1 (FANA/FANB) | 48–61%, 3100 RPM |
| Zone 0 (FAN1–FAN6) | 35–40%, set by the CPUs |

**Under load,** the P100 settles at about **79–80 °C** around **175–187 W**,
and `nvidia-smi` reports power-cap and thermal-slowdown throttling. That's
with the GPU fans at 100%. A repaste didn't change it: before and after, an
LLM benchmark (qwen2.5 14B in Ollama) ran at the same ~20 tokens/s and climbed
to the same 78–79 °C. The card is limited by **airflow**, not by its thermal
paste.

**The fail-safe has fired for real.** At two boots the host's smfc started
before the VM was up. The script reported 90 °C, the GPU fans ran at 100% for
about 30 seconds, then it logged "GPU temp read OK again" and settled. Nothing
had to be touched.

---

# Gotchas

- **Never install the NVIDIA driver on the host.** The VM owns the GPU.
- **Pascal needs an older driver.** On the VM I'm on the 580-server branch,
  the last one with Pascal support, with the packages held so an upgrade can't
  replace it.
- **The script must never hang.** smfc runs it without a timeout, and one stuck
  call freezes fan control for every zone.
- **Know your BMC's low-RPM threshold** (`ipmitool sensor`) and keep minimum
  duty above it.
- **Don't move BMC-monitored fans** to another controller (say, an ESP32). A
  fan the BMC can't see reads as failed and sends every fan to 100%.
- **Expect full fans for a few seconds at boot.** smfc starts before the VM,
  so the first readings are the fail-safe. That's working as intended.
- **Pin the VM's host key** (`StrictHostKeyChecking=yes` with a dedicated
  known_hosts file). The script runs as root, so it shouldn't trust a new key
  without you checking it first.

---

# Files

| File | What |
|---|---|
| [`bin/smfc-gpu-temp`](bin/smfc-gpu-temp) | The stand-in for `nvidia-smi` that smfc calls on the host |
| [`examples/smfc.conf`](examples/smfc.conf) | My full smfc config, with comments |
| [`examples/authorized_keys`](examples/authorized_keys) | The restricted key line for the VM |
| [`examples/smfc-gpu-temp.default`](examples/smfc-gpu-temp.default) | `/etc/default/smfc-gpu-temp` example (VM address and so on) |
| [`tools/fan_sweep.sh`](tools/fan_sweep.sh) | Zone 0 duty sweep for finding resonance |
| [`tests/test-smfc-gpu-temp.sh`](tests/test-smfc-gpu-temp.sh) | Tests the script against a fake `ssh`: one GPU, several, failures, a hang. No VM or root needed. |

---

# Credits

- [**smfc**](https://github.com/petersulyok/smfc) by Peter Sulyok does all the
  actual fan control. Radiatore is just the bridge that lets it see a GPU
  inside a VM.

---

# License

Radiatore is free software: you can redistribute it and/or modify it under the
terms of the [GNU General Public License](LICENSE) as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. Copyright (C) 2026 wendsell.

Not affiliated with Supermicro, NVIDIA, Proxmox, or the smfc project.
