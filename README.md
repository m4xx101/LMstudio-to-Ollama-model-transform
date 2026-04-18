# sync-local-models

One GGUF file, every local inference tool.

## Why this exists

If you've used more than one local inference tool, you've hit this problem: **every tool wants its own copy of your models.** Download a 40 GB Llama 3 quant in LM Studio, then Ollama wants it again, then you try text-generation-webui and it wants it *again*, then KoboldCpp, then Jan. Six copies of the same file, none of them talking to each other, all burning SSD space.

These scripts fix that. One canonical copy of each GGUF lives in your LM Studio folder. Every other tool gets pointed at it — via Modelfile references, hardlinks, or generated launch scripts — **without duplicating a single byte.**

## Why not just use the old bash one-liner

The common approach floating around is a loop that writes a Modelfile with a hardcoded ChatML template and runs `ollama create`. That approach silently breaks half your models. ChatML is the wrong template for Llama 3 (uses `<|start_header_id|>`), Mistral (uses `[INST]`), Gemma (uses `<start_of_turn>`), DeepSeek (uses `<｜User｜>`), and Phi. Your model loads but produces garbage or never stops generating.

These scripts write a **minimal** Modelfile and let Ollama's built-in `tokenizer.chat_template` metadata detection pick the right template from each GGUF. The result: models actually work out of the box.

## What else is fixed vs. the usual scripts

- **No duplicate storage** — hardlinks when same filesystem, absolute-path references otherwise. A 40 GB model stays 40 GB.
- **Filters that match reality** — `mmproj-*.gguf` (vision projectors, not standalone models), `.downloading` / `.incomplete` / `.partial` files, and non-first shards of split GGUFs (`*-00002-of-00003.gguf`) are excluded automatically. The old scripts register all of these as broken models.
- **One bad model doesn't kill the run** — per-model `try/catch` isolation, everything logged, loop continues.
- **Idempotent** — re-running skips what's already registered. `--force` / `-Force` overrides.
- **Dry-run first** — preview every action with `--dry-run` (bash) or `-WhatIf` (PowerShell) before touching anything.
- **Multi-target** — register into Ollama, text-generation-webui, KoboldCpp, llama-server, and Jan in a single pass.

## Files

| File | Platform |
|---|---|
| `Sync-LocalModels.ps1` | Windows (PowerShell 5.1+) |
| `sync-local-models.sh` | macOS (bash 3.2+) and Linux |

Both scripts share the same design, flags, and behavior. Pick the one that matches your OS.

## Quick start

```bash
# macOS / Linux — dry run against Ollama to see what would happen
./sync-local-models.sh --target ollama --dry-run

# Real run, all tools you have configured
./sync-local-models.sh --target all \
    --textgen-models-dir ~/ai/textgen/user_data/models \
    --koboldcpp-exe      ~/ai/koboldcpp/koboldcpp \
    --llamacpp-dir       ~/ai/llama.cpp/build/bin
```

```powershell
# Windows — dry run
.\Sync-LocalModels.ps1 -Target Ollama -WhatIf

# Real run
.\Sync-LocalModels.ps1 -Target All `
    -TextGenModelsDir 'D:\ai\textgen\user_data\models' `
    -KoboldCppExe    'D:\ai\koboldcpp\koboldcpp.exe' `
    -LlamaCppDir     'D:\ai\llama.cpp\bin'
```

Run `--help` / `Get-Help` for the full flag list.

## When you might *not* want this

- If a tool rewrites the model file in place (none of the supported ones do today, but worth being aware of — hardlinks mean one file, edited everywhere).
- If you're syncing across volumes on Windows without Developer Mode enabled — cross-volume symlinks need elevation. Keep models on one drive or enable Developer Mode.
- If you specifically want tool-specific fine-tuning parameters baked into each registration — the generated Modelfiles use sensible defaults (`temperature=0.7`, `top_p=0.9`); override with `--ollama-template` / `-OllamaTemplate` or edit the generated files directly.

## License

MIT. Do what you want.
