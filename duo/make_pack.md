# Model files and the pack, on both Macs

Both Macs need the **complete** model files and a **pack** that points at them. Each engine opens every model file
at start, although it keeps only its own half of the layers in memory.

## What the files are

A model in the layout Strata's DeepSeek V4.1 engine reads consists of:

| Files | What |
|---|---|
| four GGUF shards of one GSQ-RCO quantisation, `DeepSeek-V4.1-Flash-...-GSQ-RCO-<quant>-0000N-of-00004.gguf` | the model at one precision (for example 2.00 or 2.25 bits per weight) |
| the Engram GGUF, `DeepSeek-V4.1-Flash-Engram-IQ4_NL.gguf` | the n-gram lookup table; the same file for every precision |
| the drafter GGUF, `dspark-...-Q8_0.gguf` | Strata Duo runs with the drafter off, but a pack built by Strata's launcher lists the file, and the engine opens every listed file. It must exist on both Macs. |

Which sets exist, their sizes, and where Strata downloads them from: Strata's own documentation,
[`docs/DEEPSEEK41.md`](../docs/DEEPSEEK41.md) and [`docs/DEEPSEEK_MAC.md`](../docs/DEEPSEEK_MAC.md). A different
quantisation in the same layout works the same way if Strata can pack it; only the sets named in
[`docs/DUO.md`](../docs/DUO.md) were measured.

The **pack** is a small folder (a few MB) that holds no weights:

| File | What |
|---|---|
| `ds4.txt` | the model's geometry, and `model_dir /absolute/path/of/the/model/files` |
| `tensors.txt` | `file N name` lines (the model files, relative to `model_dir`), then where every tensor is |
| `engram.bin`, `expert-profile.bin`, `tokenizer/` | the Engram hash tables, the expert placement profile, the tokenizer |

## Step 1: get the model and its pack on one Mac

Use Strata itself, as its documentation describes. Either the Strata app (Models > DeepSeek-V4.1-Flash > pick a
precision > Download and prepare), or the terminal:

```sh
strata launch --family deepseek41 --model ist-das-2.00bpw --plan     # shows what it would do; changes nothing
strata launch --family deepseek41 --model ist-das-2.00bpw            # downloads, checks, builds the pack
strata launch --family deepseek41 --model ist-das-2.00bpw --model-path DIR    # from files you already have in DIR
```

Strata checks sizes and SHA-256 and builds the pack. (The recipe it uses, `tools/dsv41/pack_gguf.py`, is described
in `docs/DEEPSEEK41.md`.) Stop Strata's own server afterwards: a pair needs the memory.

Find the pack folder (the one that contains `ds4.txt`) and look at what it refers to:

```sh
python3 duo/pack_relocate.py /path/to/the/pack
```

It prints `model_dir` and every model file with its size. A line marked "outside the model folder" is a file that
the pack reaches by a relative path such as `../shared/dspark-....gguf`.

## Step 2: copy the model files to the other Mac

The model files are a few hundred GB. Over the Thunderbolt cable, from the Mac that has them:

```sh
# the other Mac's Thunderbolt address: on that Mac, System Settings > Network > Thunderbolt Bridge (169.254.x.y)
rsync -a --progress /path/to/model-folder/ user@169.254.x.y:/path/on/the/other/mac/model-folder/
```

(`rsync` to the other Mac's normal name also works, but may go over Wi-Fi or Ethernet.) Copy every file the check
in step 1 listed, including a file outside the model folder: put it in the model folder on the other Mac, or at the
same relative place.

## Step 3: copy the pack and point it at the other Mac's files

```sh
rsync -a /path/to/the/pack/ user@other-mac.local:strata-duo/packs/NAME/
```

On the other Mac the copied pack still names the first Mac's folder. Fix it there:

```sh
cd ~/strata-duo
python3 duo/pack_relocate.py packs/NAME --model-dir /path/on/the/other/mac/model-folder
```

If the pack lists a file outside the model folder and you copied that file *into* the model folder, add `--pull-in`:
the `file N ../somewhere/name.gguf` line then becomes `file N name.gguf`. To give one file another path, use
`--map name.gguf=relative/or/absolute/path` (a path in `tensors.txt` cannot contain spaces; `model_dir` can).
`--dry-run` shows the changes without writing. The first change keeps the original as `ds4.txt.orig` /
`tensors.txt.orig`.

The command ends with the list of files and `all N files present`. If the first Mac's files are also not where its
pack says (for example you moved them to an internal disk), run the same command there.

## Step 4: check both

Set `LOCAL_PACK` and `PEER_PACK` in `duo/duo.conf` and run:

```sh
duo/duo.sh doctor
```

It checks on both Macs that the pack is there, that every model file it names exists, and that the names and sizes
agree between the two Macs. The engines make the same comparison (file names and sizes) when they connect, and
refuse to pair when it fails.

## Two precisions

Repeat the steps for the second precision into a second model folder and a second pack. The Engram and drafter files
are the same for every precision; if you keep one copy outside the model folders, every pack must reach it (see
`--map`). Then switch with `MODEL` as described in `docs/DUO.md`, "Switching model precision".
