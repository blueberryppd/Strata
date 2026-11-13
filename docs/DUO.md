# Strata Duo: one DeepSeek V4.1 Flash model on two Macs

> **Experimental.** Strata Duo is a fork of [Strata](https://github.com/Niko1221/Strata) 0.2.10. It was tested on one
> pair of machines (see [Measured results](#measured-results)). It is not part of upstream Strata and does not follow
> upstream releases.

简体中文: [DUO.zh-CN.md](DUO.zh-CN.md)

## Contents

1. [What it is and what it is not](#what-it-is-and-what-it-is-not)
2. [How it works](#how-it-works)
3. [Requirements](#requirements)
4. [Setup from zero](#setup-from-zero)
5. [Daily use](#daily-use)
6. [Configuration reference](#configuration-reference)
7. [The on-demand gate](#the-on-demand-gate)
8. [Switching model precision](#switching-model-precision)
9. [Measured results](#measured-results)
10. [Limitations](#limitations)
11. [Security notes](#security-notes)
12. [Troubleshooting](#troubleshooting)
13. [Running the tests](#running-the-tests)
14. [How the code is organised](#how-the-code-is-organised)
15. [Provenance, credit and licence](#provenance-credit-and-licence)

## What it is and what it is not

DeepSeek V4.1 Flash is a mixture-of-experts model. Its quantised expert weights are larger than the memory of a
96 GB Mac. Such a Mac cannot keep them resident, so Strata's DeepSeek engine reads part of the experts from the SSD
or computes them on the CPU for every token, and that is what limits its speed.

Strata Duo splits the model **by layers** over two Macs. Each Mac loads the same model files but keeps only its own
half of the layers in memory: the *prefix host* runs layers 0-19, the *suffix host* runs layers 20-39. With half the
experts each, two 96 GB Macs can keep nearly all of them resident. The two engines talk over one encrypted connection
on a Thunderbolt cable. To a client the pair looks like one OpenAI-compatible server.

It is:

- a patch to Strata's DeepSeek V4.1 Metal engine (`strata_ds4`): about 1,250 added lines in five files;
- a set of shell and Python tools in [`duo/`](../duo) that build it, create certificates, start and stop the pair,
  check an installation (`duo.sh doctor`) and load the model on demand;
- tests, some of which run without a model.

It is not:

- a general cluster or a way to pool the memory of many machines: exactly two hosts;
- a speed-up for a model that already fits in one Mac's memory;
- a Strata feature. The Strata app does not know about it and does not show the model.

## How it works

```
   client (any OpenAI-compatible program)
      |  http://127.0.0.1:8080  (API key)
      v
+---- this Mac (runs duo.sh) -----------------+        +---- the other Mac (PEER) ------------------+
|                                             |        |                                            |
|  gate  duo_gate.py   127.0.0.1:8080         |        |                                            |
|    | loads the pair on the first request,   |        |                                            |
|    | unloads it after IDLE_MIN idle minutes |        |                                            |
|    v                                        |        |                                            |
|  127.0.0.1:8081 ====== ssh session with a port forward ======>  Strata API server (serve.server)  |
|                                             |        |             127.0.0.1:8080                 |
|                                             |        |                |  starts and drives        |
|                                             |        |                v                           |
|  PREFIX engine  strata_ds4 --duo-listen     |        |  SUFFIX engine  strata_ds4 --duo-connect   |
|    layers 0-19, Engram rows                 |<======>|    layers 20-39, head, sampling            |
|                                             |  link  |                                            |
+---------------------------------------------+        +--------------------------------------------+
        link = one TCP connection on the Thunderbolt cable, TLS 1.3, both sides authenticated
```

This is the measured layout (`LOCAL_ROLE=prefix` in `duo.conf`). The roles can be swapped (`LOCAL_ROLE=suffix`: the
API server then runs on this Mac and the other Mac runs the prefix engine); see [What was not tested](#what-was-not-tested).

For every token the suffix host sends the new token ids to the prefix host. The prefix host runs its 20 layers and
sends back the *hand-off*: the hidden state and the few side values the next layer needs, about 92 KB per token. The
suffix host runs its 20 layers, the output head and the sampler, and gives the token to the API server. A long prompt
is not sent token by token: it goes through in chunks of 2048 tokens, so both Macs work on it at the same time.

Both engines are the same program with the same model pack. When they connect they compare an identity string
(engine version, model geometry, the model files' names and sizes, the cut, the context size, the chunk size) and
refuse to pair if it differs.

Conversations that the server sets aside (so that returning to them does not re-read the prompt) hold both hosts'
halves in one file on the suffix host. A restarted prefix host has lost nothing.

## Requirements

Hardware:

- Two Apple Silicon Macs. Tested: two Mac Studio M5 Ultra with 96 GB each. Other models and memory sizes were not
  tested.
- A Thunderbolt cable between them (tested: Thunderbolt 5). Other links were not tested.
- On **each** Mac, the complete model files on an internal or other fast disk: the four GGUF shards of one precision
  plus the Engram GGUF (and the drafter file the pack refers to). Sizes are in Strata's
  [DEEPSEEK41.md](DEEPSEEK41.md) and [DEEPSEEK_MAC.md](DEEPSEEK_MAC.md).

Software:

- macOS on both (tested: macOS 27), with the Xcode Command Line Tools (`xcode-select --install`). No Homebrew and
  no sudo are needed.
- Remote Login (ssh) enabled on the other Mac, and key-based ssh from this Mac to it.
- On the suffix host: Strata's control directory (the folder that holds `serve/server.py`) and its Python. The
  measured pair used the one inside the Strata 0.2.10 app (`Strata.app/Contents/Resources/control`). Other Strata
  versions were not tested with this engine.
- Internet access on both Macs for the build (it downloads Apple's metal-cpp headers, llama.cpp at a pinned commit,
  OpenSSL 3.5.9, and cmake and ninja if you do not have them).

## Setup from zero

"This Mac" is the one you will run `duo/duo.sh` on and connect clients to. "The other Mac" is reached over ssh.
In the measured layout this Mac is the prefix host. The examples use `~/strata-duo` as the install directory on both
Macs and `user@other-mac.local` for the other Mac; use your own. Avoid spaces in the install directory's path (the
build refuses them).

### 1. Cable

Connect the two Macs with a Thunderbolt cable. In System Settings > Network both should show a "Thunderbolt Bridge"
with a self-assigned address (169.254.x.y). You do not need to configure addresses: `duo.sh` finds them at every
start, because self-assigned addresses change after a reboot.

### 2. Remote Login on the other Mac

On the other Mac: System Settings > General > Sharing > Remote Login: on.

### 3. An ssh key

On this Mac:

```sh
ssh-keygen -t ed25519                  # only if you have no key yet
ssh-copy-id user@other-mac.local
ssh -o BatchMode=yes user@other-mac.local true && echo ok     # must print "ok" without asking for a password
```

The first connection asks you to confirm the other Mac's host key. Do this once by hand.

### 4. Clone on both Macs

```sh
xcode-select --install                 # once, if the Command Line Tools are not installed
git clone -b strata-duo <URL of this repository> ~/strata-duo
```

Do the same on the other Mac. Both must be at the same commit.

### 5. Build on both Macs

```sh
cd ~/strata-duo
duo/build.sh
```

This fetches the dependencies, builds a static OpenSSL into `.duo-deps/` and builds the engine into
`build-duo/strata_ds4`. The first run is the slow one, because it also builds OpenSSL. It ends by printing the engine's version, for example
`strata-dsv41 0.1.56-metal build 0123abcde`. Run the same two commands on the other Mac. Each Mac must build its own
copy: the binary remembers the path of its checkout (it loads its Metal kernels from `metal/kernels` there), so do not
move or delete the checkout afterwards.

To rebuild later while a pair is running, build into another directory (`duo/build.sh build-duo-next`), set
`BUILD=build-duo-next` in `duo.conf`, and run `duo/duo.sh restart`. The script refuses to overwrite a running binary.

### 6. Certificates

On this Mac:

```sh
duo/gen_certs.sh
```

It writes `duo/certs-new/prefix/`, `duo/certs-new/suffix/` and `duo/certs-new/ca/` and prints what to do with them.
For the measured layout (this Mac is the prefix host):

```sh
mkdir -p duo/certs && chmod 700 duo/certs && cp -p duo/certs-new/prefix/* duo/certs/
ssh user@other-mac.local 'mkdir -p ~/strata-duo/duo/certs && chmod 700 ~/strata-duo/duo/certs'
scp -p duo/certs-new/suffix/* user@other-mac.local:strata-duo/duo/certs/
rm -rf duo/certs-new/prefix duo/certs-new/suffix
```

Then move `duo/certs-new/ca/ca.key` to offline storage, or delete it (`rm -P duo/certs-new/ca/ca.key`). Neither Mac
needs it to run. See [Security notes](#security-notes).

### 7. Model files on both Macs, and the pack

Follow [`duo/make_pack.md`](../duo/make_pack.md). In short: let Strata's own launcher download the model and build
its *pack* on one Mac, copy the model files and the pack folder to the other Mac, and run `duo/pack_relocate.py`
there so that the pack points at that Mac's copy of the files.

### 8. Settings

```sh
cp duo/duo.conf.example duo/duo.conf
chmod 600 duo/duo.conf
```

Edit `duo/duo.conf`: at least `PEER`, `PEER_DIR`, `LOCAL_PACK`, `PEER_PACK` and `SUFFIX_CONTROL_DIR`. Every setting
is explained in the file and in the [Configuration reference](#configuration-reference).

### 9. Doctor

```sh
duo/duo.sh doctor
```

It changes nothing. It prints one `PASS`, `FAIL`, `WARN`, `INFO` or `SKIP` line per check, and a `fix:` line under
each failure. Repeat until it ends with `RESULT: all checks passed`. What it checks: the settings, ssh without a
password, Remote Login, the same engine build on both Macs (it compares the output of `strata_ds4 --version`, which
holds the engine version and the source commit; the file hashes are shown for information only because each Mac's
build contains its own path), the certificates (present, the right role, signed by the same CA, not expired, key
mode 600, no key on the wrong host, and whether the engine itself accepts them), the model pack and model files
(present on both, same names and sizes), free disk, free ports, and the link addresses.

### 10. Start

```sh
duo/duo.sh start
```

It starts the gate, then loads the pair: the prefix engine first, then the API server and the suffix engine. It
prints the link addresses and each engine's first lines, and returns when the pair answers (on the measured pair a
load took about a minute). `duo/duo.sh status` then shows both engines.

### 11. First request

The API key was created at the first start in `duo/run/api_key` (and as a ready-made header line in
`duo/run/api_auth.hdr`). With curl, pass the header from the file, so that the key does not appear in the process list:

```sh
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H @duo/run/api_auth.hdr -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash","max_tokens":300,"messages":[{"role":"user","content":"Say hello in three languages."}]}'
```

### 12. Connect an OpenAI-compatible client

| Setting | Value |
|---|---|
| Base URL | `http://127.0.0.1:8080/v1` |
| API key | the contents of `duo/run/api_key` |
| Model | `deepseek-v4.1-flash` |

Streaming works. The gate listens on 127.0.0.1 only, so the client must run on this Mac. To reach it from another
machine, use an ssh tunnel to this Mac (`ssh -L 8080:127.0.0.1:8080 ...`); do not expose the port to a network.

### 13. Stop

```sh
duo/duo.sh stop
```

Both engines, the server and the gate end. Nothing loads by itself until the next `start`.

## Daily use

| You want to | Do |
|---|---|
| Turn the service on (load now) | `duo/duo.sh start` |
| Turn it off completely | `duo/duo.sh stop` |
| See what is running | `duo/duo.sh status` |
| Apply changed settings | `duo/duo.sh restart` (for `IDLE_MIN` or `BUSY_PATTERNS`: `stop`, then `start`) |
| Free the memory now, keep the service | `duo/duo.sh down` (the next request loads the pair again) |
| Measure the speed | `ROUNDS=8 duo/duo.sh bench` |
| Check the installation | `duo/duo.sh doctor` |
| Have the gate come back after a login | install the LaunchAgent: [`duo/launchd/README.md`](../duo/launchd/README.md) |

While the service is on, the pair is unloaded after `IDLE_MIN` idle minutes and both Macs get their memory back. The
next request loads it again and is answered after about a minute. If either Mac restarts or the link drops, the
engines end; the next request through the gate starts the pair again. (If it was this Mac that restarted, the gate
itself has to come back first: run `duo/duo.sh start`, or install the LaunchAgent.)

Files in `duo/run/` on this Mac (none are tracked by git): `api_key`, `api_auth.hdr`, `gate.log`, `prefix.log`,
`server.log`, `gate_state.json`, `bench.jsonl`, `.duo_wanted` (the service is on), `.duo_starting` (a load is under
way). On the suffix host, `duo/run/` holds `engine.log`, `serve.json`, the start script and the kept conversations
(`slots-<MODEL>/`).

## Configuration reference

All settings are in `duo/duo.conf` (a bash file; see [`duo/duo.conf.example`](../duo/duo.conf.example)).
`DUO_CONF=/path/to/file` selects another file.

| Setting | Default | Meaning |
|---|---|---|
| `PEER` | (required) | ssh destination of the other Mac (`user@host` or an alias of `~/.ssh/config`) |
| `LOCAL_ROLE` | `prefix` | this Mac's half: `prefix` (layers 0-19) or `suffix` (layers 20-39 and the API server). The other Mac gets the other role |
| `LOCAL_DIR` | this checkout | install directory on this Mac |
| `PEER_DIR` | (required) | install directory on the other Mac (`"~/..."` is expanded there) |
| `BUILD` | `build-duo` | build directory with `strata_ds4`, inside the install directory (`LOCAL_BUILD`, `PEER_BUILD` to differ) |
| `LOCAL_CERTS`, `PEER_CERTS` | `<install dir>/duo/certs` | certificate directory of each Mac |
| `MODEL` | `default` | your label for the loaded model; names the kept-conversations folder; usable in the pack paths |
| `LOCAL_PACK`, `PEER_PACK` | (required) | the model pack folder on each Mac |
| `MODEL_ID` | `deepseek-v4.1-flash` | model name shown to clients |
| `VX1`, `VX2` | `0.85`, `0.90` | share of free memory for resident experts on the prefix / suffix host (`--vram-experts`) |
| `CTX` | `65536` | context size in tokens |
| `SUFFIX_CONTROL_DIR` | (required) | Strata control directory on the suffix host (holds `serve/server.py`) |
| `SUFFIX_PYTHON` | `<control dir>/python/bin/python3.12` | the Python that runs the API server |
| `SLOT_DIR` | `<suffix run dir>/slots-<MODEL>` | where the server keeps conversations it set aside |
| `IDLE_MIN` | `30` | unload after this many idle minutes; `0`: never |
| `BUSY_PATTERNS` | `()` | `pgrep -f` patterns of programs the pair must not be loaded beside (see the gate) |
| `BUSY_MAX_S` | `2400` | longest wait for them; then the pair loads anyway; `0`: no limit |
| `APIPORT` | `8080` | the gate's port on this Mac (clients) |
| `BACKPORT` | `8081` | this Mac's port behind the gate (the tunnel's local end) |
| `SERVER_PORT` | `APIPORT` | the API server's port on the other Mac's 127.0.0.1 |
| `PORT` | `50090` | the link port between the engines |
| `LINK_PREFIX` | `169.254.` | start of the link's addresses, for discovery |
| `LINK_LOCAL_IP`, `LINK_PEER_IP` | (empty) | fixed link addresses instead of discovery |
| `MIN_FREE_GB` | `20` | free disk `doctor` wants on each Mac |
| `LOCAL_RUN`, `PEER_RUN` | `<install dir>/duo/run` | logs, key and state files |
| `GATE_PYTHON` | `/usr/bin/python3` | Python for the gate and the benchmark (3.9 or newer, no packages) |
| `SSH_OPTS` | `()` | extra ssh options |
| `LAUNCHD_LABEL` | `local.strata-duo.ensure` | label of the optional LaunchAgent |

The engines are always started with `--duo-cut 20 --dspark none --vision off --ssd-cache 0 --profile-readonly`.

## The on-demand gate

`duo/duo_gate.py` is a small HTTP proxy (Python standard library only) on `127.0.0.1:APIPORT`. It holds no model.

- A request that arrives while the pair is unloaded makes the gate run `duo.sh up`, wait, and then pass the request
  on. Several requests that arrive together cause one load.
- After `IDLE_MIN` minutes without a request it runs `duo.sh down`.
- `GET /v1/models` is answered by the gate when the pair is unloaded, so clients see the model at any time. It does
  not load the pair.
- Every request needs the API key (`Authorization: Bearer ...` or `x-api-key`), except `GET /duo/status`, which
  returns only `{"loaded", "loading", "active", "idle_s", "idle_min"}`.
- `POST /duo/unload` (with the key) unloads the pair now. It answers `200 {"unloaded": true}`, or `409` when a
  request is in flight or a load is under way. Another program that needs the memory can call it before it starts:

  ```sh
  curl -s -X POST -H @duo/run/api_auth.hdr http://127.0.0.1:8080/duo/unload
  ```

- `BUSY_PATTERNS`: each entry is a `pgrep -f` pattern. While a process on this Mac matches one, the gate does not
  load the pair and the request waits. After `BUSY_MAX_S` seconds it loads the pair anyway. The patterns are only
  looked at before a load; a program that starts while the pair is loaded should call `/duo/unload` itself.
- Request bodies larger than 64 MB are refused (`--max-body-mb`).

## Switching model precision

A pair loads one model. To switch between two precisions (for example 2.00 and 2.25 bpw), keep both sets of model
files and both packs on both Macs, and put the label into the pack paths in `duo.conf`:

```sh
MODEL=${MODEL:-2.25}
LOCAL_PACK="$HOME/strata-duo/packs/deepseek-v4.1-flash-${MODEL}bpw"
PEER_PACK="~/strata-duo/packs/deepseek-v4.1-flash-${MODEL}bpw"
```

Then change `MODEL` and run `duo/duo.sh restart` (or, for one run, `MODEL=2.00 duo/duo.sh restart`; the gate keeps
using the value in the file). Each label has its own folder of kept conversations.

## Measured results

Everything below was measured on one pair: **two Mac Studio M5 Ultra, 96 GB each, a Thunderbolt 5 cable, macOS 27**.

Method: 5 to 8 mixed English and Chinese prompts, 400 generated tokens each, temperature 0, sent through the HTTP API
(`duo/bench.py`). Speed = total generated tokens / total wall time.

| Measurement | Result |
|---|---|
| One Mac, DeepSeek V4.1 Flash 2.00 bpw, with the engine's RAM expert cache | 4.10 tokens/s |
| Two Macs, 2.00 bpw | 12.41 tokens/s over 30 rounds (range 12.13-12.58) |
| Two Macs, 2.25 bpw, default settings | 12.04 tokens/s over 8 rounds (range 11.6-12.6) |
| Reading a 12,724-token prompt (both precisions) | 22.7-22.9 s (about 555-560 tokens/s) |
| Returning to a parked 7,600-token conversation | 2.4 s, against 17.8 s to read it again |
| First request after an idle unload | answered after 60-77 s |
| Recovery after a dropped link | about 80 s |
| Data on the link | about 92 KB per generated token |
| Time cost of the link | about 0.03-0.15 ms per token |

RDMA was not implemented, because the link is not the bottleneck.

Correctness: with every routed expert on the CPU lane (`--vram-experts 0.0`), a split run on one machine is
token-identical to the unsplit engine. This holds on the windowed path by default, and on the chunked path with
`DS4_SUM_BY_EXPERT=1 DS4_SPEC_WASTE=1e9` (which fix the order of the floating-point sums).

### What was not tested

- other Mac models or memory sizes;
- more than two hosts;
- Linux;
- long runs of several hours;
- conversations near the 64K context limit;
- links other than Thunderbolt.

Also not tested, concerning the tools in this branch: the scripts in `duo/` are a generic rework of the scripts the
measurements were made with. The reworked `duo.sh` was exercised with stand-ins on one Mac
(`duo/tests/duo_sh_selftest.sh`) but **not yet on two real Macs**; `LOCAL_ROLE=suffix` has never been run on real
hardware in this form; starting the gate from launchd and a start after a full reboot were not tested.

## Limitations

- Exactly two hosts.
- Apple Silicon and Metal only.
- DeepSeek V4.1 Flash only. The cut is fixed at layer 20 for this model.
- Text only (no vision). One request at a time (`--parallel 1`). The drafter is off.
- A Stop during a long prompt read takes effect after the read.
- If either host restarts, the pair must be restarted. The gate does this on the next request.
- Based on Strata 0.2.10 (engine 0.1.56). It does not follow upstream releases automatically.
- Experimental.

## Security notes

**Threat model.** Two Macs that you own and control, connected by a cable. Other devices on your network and other
user accounts are not trusted. Anyone who can run programs as your user on either Mac is trusted: they can read the
keys, the API key, the logs and the kept conversations. Strata Duo has not had an independent security audit.

**What the TLS link does.** The connection between the engines carries the token ids of your conversation and the
model's activations. It is TLS 1.3 with mutual authentication: each engine has a certificate from your private CA,
checks that the other side's certificate is from the same CA and carries the *other role* (a prefix host accepts
only a `strata-stage-coordinator`, a suffix host only a `strata-stage-worker`), and refuses anything else. The prefix
engine listens only on the link's address, accepts connections only from the other Mac's link address
(`--duo-allow`), and takes one connection.

**What it does not do.** It does not protect against someone who has a role key or the CA key, or who controls one
of the two Macs. There is no revocation: if a key may have leaked, make a new set with `gen_certs.sh` and replace
the files on both Macs. The two engines trust each other once authenticated; the link protocol has not been hardened
against a peer that holds a valid certificate and misbehaves. Certificates expire (365 days by default; `doctor`
warns 30 days before), and the pair then stops connecting until you make a new set.

**Key handling.**

- The worker key (`strata-stage-worker.key`) must never leave the prefix host; the coordinator key must never leave
  the suffix host. `doctor` warns when it finds a key on the wrong host.
- Keep the CA key offline, or delete it. Neither host needs it. With it, new certificates for your pair can be made.
- Key files are mode 600 in a mode 700 directory. `certs/`, `certs-new/`, `run/` and `duo.conf` are in `.gitignore`.
- `gen_certs.sh` creates all keys on one Mac and you copy one role's folder to the other over ssh. If you prefer
  that a key never crosses, run `gen_certs.sh` on a third machine and copy each folder to its host.

**The API.** The gate and the API server listen on 127.0.0.1 only. The API key (48 hexadecimal characters, mode
600) is created at the first start, copied to the other Mac through ssh's standard input, and given to the server
in its environment. The tools never put it on a command line; use `curl -H @duo/run/api_auth.hdr` yourself.
`GET /duo/status` needs no key and reveals only whether the pair is loaded.

**On disk.** Kept conversations (`slots-<MODEL>/` on the suffix host) contain the conversation's tokens and state,
unencrypted. Treat the logs in `duo/run/` as private too (paths, addresses, timing).

**`duo.conf` is a shell script** that `duo.sh` executes. Keep it writable only by you (`chmod 600`).

**`--duo-insecure`.** The engine refuses to open the link without `--duo-certs`, unless `--duo-insecure` is given.
That flag selects a plain TCP connection: token ids and activations unencrypted, the peer known by its source
address only. It exists for loopback tests on one machine. `duo.sh` never uses it. Do not use it between machines.

## Troubleshooting

Start with `duo/duo.sh doctor`: most setup mistakes have a `FAIL` line with a fix.

| Symptom | Cause and fix |
|---|---|
| `cannot find the other Mac on the link` | The cable is not connected, or the Thunderbolt Bridge has no 169.254 address on one side. Check System Settings > Network on both Macs. With fixed addresses, set `LINK_LOCAL_IP` and `LINK_PEER_IP`. |
| `the prefix host did not start` | See `duo/run/prefix.log`. Common: a wrong pack path, model files missing (`duo/pack_relocate.py PACK`), a certificate problem (the engine's message names the file). |
| `the suffix host failed:` followed by a `maya-ds4: duo:` line | The engines refused to pair. `the two hosts differ: here ... there ...` shows both identity strings: the two Macs differ in engine version, model files (names and sizes), context size or chunk size. A TLS message means the certificates do not match: both Macs need files of the same `gen_certs.sh` run. |
| `the ssh session that holds the server ended` | See `duo/run/server.log`. Common: a wrong `SUFFIX_CONTROL_DIR` or `SUFFIX_PYTHON`, or the port is in use on the other Mac. |
| The engine on the other Mac reports `No route to host` | macOS refuses local-network access to a process that was detached from its login session. `duo.sh` therefore keeps the other Mac's process as a child of a long-lived ssh session. Do not start that process by hand with `nohup ... &` over ssh. |
| HTTP 401 | The API key is missing or wrong. It is the contents of `duo/run/api_key` on this Mac. |
| HTTP 503 `the pair did not start: ...` | The gate could not load the pair; the message holds the last lines of `duo.sh up`. Run `duo/duo.sh up` by hand to see all of it. |
| The first answer after a pause takes about a minute | The pair was unloaded after `IDLE_MIN` idle minutes and is loading. Set `IDLE_MIN=0` to keep it loaded. |
| An empty answer with a small `max_tokens` | The model's thinking used the whole budget. Allow more tokens (a few hundred). |
| Stop does not stop a long prompt | A Stop during a long prompt read takes effect after the read (see Limitations). |
| A request waits a long time and `gate.log` says `busy` | A process matches one of `BUSY_PATTERNS`. `duo/duo.sh doctor` shows which. |
| The Mac swaps or slows down | Another program needs the memory. Lower `VX1` or `VX2` for that Mac and restart, or list the program in `BUSY_PATTERNS` and have it call `/duo/unload`. |
| `the gate did not start` | Another program uses `APIPORT`. Choose another port in `duo.conf`. |
| It worked, and after an update of the Strata app it does not | The Duo engine is built from this branch and does not change with the app, but the API server comes from `SUFFIX_CONTROL_DIR`. Keep a copy of the 0.2.10 control folder and point `SUFFIX_CONTROL_DIR` at it. |

Logs: `duo/run/gate.log` (the gate), `duo/run/prefix.log` (the prefix engine), `duo/run/server.log` (the ssh
session and the API server), and `duo/run/engine.log` on the suffix host (the suffix engine).

## Running the tests

See [`duo/tests/README.md`](../duo/tests/README.md) for what each test proves and how long it takes. Four need no
model and no second Mac:

```sh
duo/tests/link_smoke.sh              # the TLS link alone over loopback, with test certificates: about 10 s
python3 duo/tests/gate_selftest.py   # the gate against stand-ins: about 30 s
duo/tests/duo_sh_selftest.sh         # duo.sh end to end against stand-ins, both layouts: about 2 minutes
duo/tests/doctor_selftest.sh         # doctor with an unreachable peer: about 20 s
```

The engine tests (split against unsplit, the negative TLS tests, conversation slots) load a model twice on one Mac
and need a pack that fits. Do not run them on a Mac that is serving.

## How the code is organised

For someone who wants to read the engine change or port it to another backend or model. `git diff c5ab5d4 -- src
metal` is all of it (c5ab5d4 is the upstream commit this branch starts from).

| File | What is in it |
|---|---|
| `src/dsv41/ds4_duo.hpp` | The link: message header and operations, the `Link` class (listen / connect, send / receive), the TLS context and handshake checks, `link_policy` and `link_preflight`. Self-contained; `duo/tests/link_bench.cpp` uses it alone. |
| `src/dsv41/ds4_model.cu` | Everything that touches the model: `duo_check`, `duo_identity`, `duo_open`, `duo_serve`, the hand-off in the layer loop, the chunked path (`duo_give_chunk`, `duo_take_chunk`, `duo_serve_chunks`), the slots (`duo_slot_save`, `duo_slot_load`), and loading only this host's layers. |
| `src/dsv41/ds4_main.cpp` | The `--duo-*` options, the chunk default, the prefix host's main loop, the pair's slot folder. |
| `src/dsv41/ds4_model.hpp` | The options (`duo_role`, `duo_cut`, `duo_addr`, `duo_allow`, `duo_certs`, `duo_insecure`) and two methods. |
| `metal/CMakeLists.txt` | `-DSTRATA_DUO_TLS=ON -DSTRATA_DUO_OPENSSL_ROOT=...`: static OpenSSL 3 for `strata_ds4`. Off by default; then the build is upstream's plus a refusal of `--duo-certs`. |

The ideas, in the order you would need them:

**The cut must be at a KV source layer.** In this model some layers write a compressed key-value store that later
layers read (`kv_source_layer_ids` and `index_source_layer_ids` in the pack's `ds4.txt`). A layer must not read a
store that the other host writes. `duo_check` walks all layers and refuses a cut that separates a reader from its
source. Layer 20 is a source layer and halves the 40 layers; it is also the layer of the long-prompt skip, so the
suffix host can skip rows exactly as one host does. `duo.sh` always passes `--duo-cut 20`; no other cut was tested.

**The hand-off.** What crosses from layer 19 to layer 20 is what the engine already moves between two GPUs of one
machine: `h | pre | topk | cand` (the hidden state, 4 x 5120 floats per token, and three small side arrays), 92,192
bytes per token. `duo_sizes` gives the layout. The prefix host sends it after its last layer; the suffix host reads
it as the input of its first layer.

**Mirrored state calls.** The suffix host is the one the server talks to. Every call that changes the
conversation's state is repeated to the prefix host, which applies it to its own layers: `kForward` (a window's
tokens), `kReset`, `kCheckpoint`, `kMark`, `kPin`, `kRestore`. Of these only `kForward` is answered (with the
hand-off, `kHand`). Both hosts keep restore points from their own layers in the same order, so a restore gives
matching states. The handshake: the suffix host sends `kHello` with its identity string, the prefix host compares it
with its own and answers `kOk`, or `kErr` with both strings (`the two hosts differ: here ... there ...`).

**Slots.** `slot_save` on the suffix host saves its half, asks the prefix host for its half (`kSlotSave` -> `kSlot`),
and returns one blob (`"DS4DUOS1"`, cut, layers, position, the two sizes, the two halves). `slot_load` sends the
prefix half back (`kSlotLoad`) and restores its own. Both halves go in, or neither; a failure after a partial write
resets both hosts. The slot identity ends in ` duo-cut=K`, so one host's slots are never given to a pair.

**Chunked prompts.** For a long prompt the suffix host sends `kChunks` once: the tokens, the rows per chunk, the
skip, and the restore points to keep (`ChunksPlan`). The prefix host runs its layers over each chunk and streams
that chunk's hand-off rows; the suffix host consumes them chunk by chunk. A chunk is 2048 rows by default
(`--prefill-chunk`, same on both hosts). A run of chunks is not interrupted by a Stop.

**Only this host's layers are loaded.** Each layer is marked `foreign` or not from the role and the cut; a host does
not load the dense weights of foreign layers, and the prefix host does not load the head.

**The link.** One TCP connection, one thread, a 32-byte header (`magic "DDUO"`, operation, two integers, payload
size) and a payload. TLS is applied to the same stream. A port to another backend needs to keep only the message
format; a port to another model needs a cut that passes `duo_check` and the hand-off layout of that model.

## Provenance, credit and licence

- Strata Duo is based on **Strata** by Niko1221 and contributors (MIT licence), at commit c5ab5d4 (app 0.2.10,
  engine 0.1.56): <https://github.com/Niko1221/Strata>. The DeepSeek engine in Strata comes from Project Maya (see
  `third_party/project-maya/NOTICE.md`).
- The idea of running one model over two hosts, and the design of the TLS transport, follow the Linux/CUDA
  stage-RPC fork by **petria** (<https://github.com/petria/Strata>, branch `rpc-v0.2.13`). Its transport was used as
  the reference for the TLS link (TLS 1.3, a private CA, role certificates named `strata-stage-worker` and
  `strata-stage-coordinator`).
- Upstream issue **#5298** is the request for multi-host operation.
- The Duo code and these documents were written with an AI coding assistant and tested on the hardware described in
  [Measured results](#measured-results).
- Licence: MIT, the same as Strata; see [`LICENSE`](../LICENSE). The notice for this fork is in
  [`third_party/strata-duo/NOTICE.md`](../third_party/strata-duo/NOTICE.md).
