# Strata Duo tests

Three kinds: tests that need **no model** (run them after every change to the tools), loopback tests of the
**engine** on one Mac (need a model pack that fits in memory twice), and the **evidence** kept from the development
runs. None of them needs the second Mac. The real two-Mac start is tested with `duo.sh doctor` and `duo.sh start`.

Paths come from environment variables (see `env.sh`); nothing is hard-coded. Output goes to `duo/tests/out/`
(`DUO_TEST_OUT`), which git ignores. Use paths without spaces for the test variables.

## Without a model

| Test | What it proves | Takes |
|---|---|---|
| `link_smoke.sh [PORT]` | The link code of this tree (`src/dsv41/ds4_duo.hpp`) builds with TLS; a worker and a coordinator connect over loopback with the two role certificates (TLS 1.3, both verified); 5,000 round trips of a 92 KB hand-off, plain and TLS, with the time per round trip. | about 10 s |
| `link_security.sh [PORT]` | The link's refusals and failure handling, over loopback: plain mode without an allowed address is refused, a key file others can read is refused, a peer that is killed gives a read error at once, a wrong header is told apart from a closed link, the listener keeps waiting after it drops a stranger, the TLS handshake has a real 10 s deadline, a stopped (not dead) peer is waited for, and the file fingerprint of a 150 GiB sparse file is the same twice, differs when the header or the tail differs, and takes under a second. | about 1 min |
| `gate_security_test.py` | The gate's handling of bad requests: the key is checked before the body is read, bodies without or with a negative length and chunked bodies are refused, oversized bodies get 413, an unload in progress makes a request wait and then load, one failed health probe does not unload a pair. | about 30 s |
| `gate_selftest.py` | The real gate against a stand-in server and a stand-in `duo.sh`: 401 without the key, the model list while unloaded, on-demand load, one load for two simultaneous requests, a streamed answer passed on piece by piece, `/duo/unload` 409 and 200, busy patterns, idle unload, 503 for a failed load. | about 30 s |
| `duo_sh_selftest.sh` | The real `duo.sh` and gate against a stand-in ssh, a stand-in engine and a stand-in API server, in folders with spaces and an apostrophe: `doctor` (also with a wrong key mode, a key on the wrong host, a model file of another size), `start`, a request, `status`, `up`, `bench`, `restart`, `down`, reload through the gate, the lock, `stop`, `ensure`, `launchagent`, then `LOCAL_ROLE=suffix`, then an unreachable peer. It checks that the API key is in no process's arguments. It cannot prove anything about real ssh sessions, macOS's local-network rules or the engines. | about 2 minutes |
| `doctor_selftest.sh` | `duo.sh doctor` with a peer that cannot be reached: it finishes, reports the failure with a fix, checks this Mac, marks the other Mac's checks as skipped, writes nothing, exits 1. | about 20 s |
| `make_test_certs.sh` | Not a test: throwaway certificates for the tests (one CA with both roles in one folder, a second CA, and the mixed folders of the negative tests). | a few seconds |

`link_smoke.sh`, `duo_sh_selftest.sh` and `make_test_certs.sh` need the OpenSSL 3 that `duo/build.sh` builds
(`duo/build.sh --deps-only` is enough). The stand-in engine of `duo_sh_selftest.sh` is a shell script named
`strata_ds4` in a temporary folder; on a Mac that is serving a real pair it does not touch that pair (it uses its
own ports and folders), but `duo.sh status` there will list it while the test runs.

## Engine tests on one Mac (loopback)

These start the real engine twice on one Mac (a worker and a coordinator on 127.0.0.1) and compare its output with
one unsplit engine. They need:

- `DUO_TEST_PACK`: a DeepSeek V4.1 pack whose model fits in this Mac's memory twice, or that you run with
  `--vram-experts 0.0` (every routed expert on the CPU lane, which the scripts do). The evidence below was produced
  with the ISTA-DAS Coder pack (see `docs/DEEPSEEK41.md`) on one M5 Ultra with 96 GB.
- `DUO_TEST_PYTHON`: a Python with the `regex` package (Strata's own Python has it); the tokenizer is
  `tools/strata_tokenizer.py`.
- `DUO_TEST_TEXT`: any UTF-8 text file of 135,000 characters or more. The long prompts are cut from it.
- the test certificates (`make_test_certs.sh`), and for one case a plain build (`duo/build.sh --plain`).

**Do not run them on a Mac that is serving a pair**: two more engines push it into swap. `slots_test.py` refuses to
run when swap has grown.

| Test | What it proves |
|---|---|
| `pair.sh LABEL WORKER_EXE COORD_EXE PORT "WORKER FLAGS" "COORD FLAGS"` | One split run on the windowed path; prints the hash of the output ids. Run once with `--duo-insecure` and once with `--duo-certs`, and compare with `ds4_run.py` on one engine: the same hash means the split is token-identical. |
| `run.sh single\|duo LABEL CHUNK [TOKENS]` | The same for a long prompt on the chunked path. With `DUO_ENV="DS4_SUM_BY_EXPERT=1 DS4_SPEC_WASTE=1e9"` the single and duo hashes are equal; at default settings the order of the floating-point sums differs and so can the hash. |
| `negative.sh [PORT]` | Every wrong peer is refused: no certificate, TLS 1.2, the wrong role, another CA, no ALPN, a silent peer, an address outside `--duo-allow`, plain against TLS and TLS against plain, a plain build given `--duo-certs`. A refused peer leaves the worker waiting for the right one. |
| `serve_test.py single\|duo LABEL CHUNK` | A conversation through `--serve` that uses restore points (a mark inside a long read, a continuation, leaving the conversation at the mark, continuing after the restore); optional Stop during a long read. Equal hashes for single and duo. |
| `slots_test.py single\|duo LABEL SCENARIO` | Conversation slots: two interleaved conversations, a slot kept on disk across fresh engines, a shared start, and failures injected on the worker (the `fail` scenario needs a worker built with `-DSTRATA_DUO_TESTHOOKS=ON`; a normal build ignores `DS4_DUO_SLOT_TEST`). Equal hashes for single and duo. |
| `slot_tool.py`, `cmp_dump.py`, `cmp_sets.py` | Helpers: inspect or alter slot files for negative tests; compare the engines' debug dumps. |

Each run loads the model once (single) or twice (duo); how long that takes depends on the pack and the disk.
`negative.sh` loads it about a dozen times.

## Evidence from the development runs

`evidence/` holds the summaries the tests printed during development, on one Mac Studio M5 Ultra 96 GB with the
Coder pack, `--vram-experts 0.0 --max-context 8192 --ssd-cache 0 --profile-readonly`. Local paths were replaced by
`<certs>`, `<tests>` and `<work>`. The text file the prompts were cut from is not part of this repository, so a new
run prints other hashes; what counts is that single and duo print the *same* hash. The speeds in these logs are two
engines sharing one Mac with all experts on the CPU lane: they say nothing about a real pair.

| File | Content |
|---|---|
| `evidence/timing.txt` | Windowed path: four runs over the plain link, four over TLS and two with a plain build. All ten give `ids_sha 136cfb473f3e2b0c`, the hash of the unsplit engine on the same prompt. |
| `evidence/negative.txt` | The output of `negative.sh`: each case with the client's and the worker's lines. |
| `evidence/slots_runs.txt` | The slot scenarios, single and duo, with every turn's hash. |
| `evidence/link_bench.txt` | `link_bench` three times: plain median 36 us, TLS median 52-53 us per round trip of 92 KB. |

Summary of the equalities (hashes of the output token ids; each row: one unsplit engine against a split pair):

| Case | Unsplit | Split (Duo) |
|---|---|---|
| Windowed path, 32 tokens | 136cfb473f3e2b0c | 136cfb473f3e2b0c (plain link and TLS) |
| Chunked path, 4,200-token prompt, chunks of 1024, `DS4_SUM_BY_EXPERT=1 DS4_SPEC_WASTE=1e9` | 503d37e8d56f786c | 503d37e8d56f786c |
| `--serve` conversation with restore points, same settings | 8a4b0d5c1a498666, 91febc5a6b63a23d, f4f3a78f34142c62, 80b3d84adc5e3f74 | the same four |
| The same with `--no-expert-cache`, with and without a Stop during a 3,022-token read | 73de31a3a38c103d, 91febc5a6b63a23d, 0b1a439103ca7ffe, cef1f32d90e46b7b | the same four |
| Slots: two interleaved conversations (`inter`) | 839fb521ee02871e | 839fb521ee02871e (plain link and TLS) |
| Slots: `inter` with longer prompts | 195f245787dcc4ec | 195f245787dcc4ec |
| Slots: kept on disk, fresh engines (`persist2`) | f52491c764bb18cd | f52491c764bb18cd |
| Slots: a shared start (`shared`) | 6853774fbe21d470 | 6853774fbe21d470 |
| Slots: the worker refuses or fails (`fail`, three kinds) | 48d313f3e99d7249 (slots off) | 48d313f3e99d7249 each |

Notes on this evidence:

- At default settings the chunked path of a pair differs from one host by one unit in the last place of some sums
  (the order in which expert outputs are added depends on what the device's earlier layers streamed). The two
  variables above fix the order; with them the results are identical.
- The first Duo run of `inter` gave other answers and ran much slower while another process restarted a large
  service on the same Mac; it is in `evidence/slots_runs.txt`. The nine Duo runs after it did not show this.
- Not covered by these tests: two real hosts, a link that dies inside a slot save or load, slots of very long
  conversations, a yield during a chunked run.
