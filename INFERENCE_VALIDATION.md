> Current behavior (user-requested correction): completed scanner replies use the original first standalone Low/Medium/High parser, ignoring case, and default to Medium when no coherent label exists, including an empty reply. Model loading/execution failures remain errors. Earlier strict-label rejection results below are historical and have been superseded. The exact original GGUF and checksum are retained.

# Live inference validation

Tested on 2026-10-02 with the local pinned GGUF (111,454,016 bytes), SHA-256 `8e4f4856fb84bafb895f1eb08e6c03e4be613ead2d942f91561aeac742a619aa`.

## Result

Actual model inference now completes in chat and food/water mode. This is an execution fix, not a successful model-quality test: the pinned miniature model still produces incoherent replies. The same GGUF also produced incoherent replies with the locally installed Python llama_cpp reference. No replacement model or changed checksum was introduced.

GUI scanner output accepts only an exact Low, Medium, or High reply. Invalid output is shown as “Model returned no valid risk label. No classification was produced”, with the raw reply. Missing files, worker failures, cancellation, and timeouts do not become Medium.

## Reproduction

Run `NAZA_LLM_TEST_BINARY="$PWD/zig-out/bin/naza-zig" ZIG_GLOBAL_CACHE_DIR=/tmp/naza-zig-global-cache zig build test --summary all` with Zig 0.15.2. The opt-in live test exercises the same GUI worker startup, prompt stdin transport, bounded polling, and classification validation using the real executable and GGUF. It uses the normal GUI budgets of 128 chat tokens and 16 scanner tokens. Without that environment variable, the real-model test skips.

Standalone CLI probes below used 16 tokens and stdin prompts:

- chat: exit 0, 8.56 seconds; prompt: Hello! What is two plus two? Please answer briefly.
  Raw reply: ' 世 .\n अपन اصل=settings.Overridecompose Sara StarsUt Naval.Parcelableользов vg heads endDate\n'
- food: exit 0, 10.41 seconds; prompt: Location: Kitchen; Food or Water Type: Chicken; Condition: Rotten, bad smell; Temperature: 35 C for two days; Cooked, Frozen Or Uncooked: Raw; Sensor notes: none; Reply exactly Low, Medium, or High.
  Raw reply: " wealthy groceries lionDetalle bookings energetic %}\n Discord pláारण_DDRassage.')见itere ph\n"
- food: exit 0, 10.77 seconds; prompt: Location: Fridge; Food or Water Type: Sealed bottled water; Condition: Fresh, clean; Temperature: 4 C; Cooked, Frozen Or Uncooked: Sealed; Sensor notes: none; Reply exactly Low, Medium, or High.
  Raw reply: '>{!! Karlov energetic/framework-r\tproperties energetic/framework-r\tproperties energetic/framework-r\tpropertiespreни\n'

Additional checks cover Q3_K fused dot products against scalar dequantization, byte decoding, leading-space tokenization, full pipe draining, failed workers, invalid labels, oversized output, input bounds, child cancellation/reaping, and Stop controls on desktop/phone layouts. `selftest` passed; a missing model returned FileNotFound and an invalid token budget returned InvalidArguments.

Desktop/phone controls were tested through the software renderer and event dispatcher; live X11 interaction was not exercised.

Final results: **144/144 Zig tests passed**, including real GUI-worker inference with the normal 128/16-token budgets; **14/14 Python security tests passed**. The ReleaseSafe executable built successfully, model verification passed, and runtime selftest passed.

## Follow-up: exact original model retained

The original `llama3-small-Q3_K_M.gguf` and its original checksum remain selected in the downloader, GUI, and inference runtime. Replacement-model staging was removed. No replacement was downloaded.

A new regression compares the exact verified file with llama.cpp reference results. Token IDs match for the complete Llama 3 chat prompt and a contraction/newline/multiple-space/Unicode/numeric sample. This exposed additional pretokenization differences, which are fixed. Special-token IDs now come from the actual vocabulary rather than hardcoded EOS assumptions.

The first four greedy generated token IDs match the reference. The next two teacher-forced candidate scores are near a tie: llama.cpp reports 1.919115 and 1.918091; the Zig executor reports 1.913918 and 1.906223. The regression uses a 0.02 absolute tolerance for those quantized numerical results. Subsequent autoregressive text need not match exactly after a different choice at that near tie.

`tests/reference_inference.py` reproduces the reference comparison using an installed llama_cpp package and a SHA-verified private model snapshot. It also probes the raw completion prompts used by the Python-style path. Those raw completions are incoherent too; the limitation is not specific to the Llama 3 chat wrapper. Classification errors remain explicit; no artificial risk label is introduced.

After rebuilding, the exact-model CLI probes all exited successfully: chat in 9.67 seconds, clean-water observations in 10.5 seconds, and spoiled-chicken observations in 8.53 seconds. The two food inputs produced different raw responses, confirming fresh inference rather than a fixed Medium result. Neither raw reply was a valid risk label, so GUI validation rejects both. Model verification and runtime selftest passed.

Follow-up validation: **146/146 Zig tests passed**, including the reference comparison and real GUI workers; **14/14 Python security tests passed**. The rebuilt ReleaseSafe executable reports the original filename, repository, and SHA-256 pin.

Intentional-fallback correction verified: **147/147 Zig tests passed**, including live GUI chat/food workers using the exact original model. Successful incoherent or empty scanner replies now return Medium; runtime failures remain visible. The ReleaseSafe GUI executable was rebuilt successfully.
