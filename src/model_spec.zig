// Publisher GGUF and its published content SHA-256. Never accept an arbitrary
// hash supplied by the download server or an unverified local replacement.
pub const repository = "HuggingFaceTB/SmolLM2-360M-Instruct-GGUF";
pub const repo = "https://huggingface.co/" ++ repository ++ "/resolve/main/";
pub const file = "smollm2-360m-instruct-q8_0.gguf";
pub const sha256_hex = "48ab3034d0dd401fbc721eb1df3217902fee7dab9078992d66431f09b7750201";
pub const label = "SMOLLM2 360M INSTRUCT / Q8_0";
pub const approximate_bytes: usize = 386 * 1000 * 1000;
