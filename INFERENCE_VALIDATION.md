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
