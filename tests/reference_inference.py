"""Reproduce the exact-model llama.cpp comparison; never downloads a model.

Run from the repository with a Python environment containing llama_cpp:
    python tests/reference_inference.py
"""
import ctypes
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from secure_model import load_verified


def main():
    from llama_cpp import Llama
    pinned = "8e4f4856fb84bafb895f1eb08e6c03e4be613ead2d942f91561aeac742a619aa"
    model = load_verified(
        lambda **kwargs: Llama(verbose=False, **kwargs),
        Path("models/llama3-small-Q3_K_M.gguf"), pinned,
    )
    prompt = (
        "<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n"
        "You are a helpful assistant. Answer the user clearly and concisely."
        "<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n"
        "Hello! What is two plus two? Please answer briefly."
        "<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n"
    )
    token_ids = model.tokenize(prompt.encode(), add_bos=False, special=True)
    varied = model.tokenize("I'm testing.\n\n  Hello! Café 1234".encode(), add_bos=False, special=True)
    model.reset()
    model.eval(token_ids + [122781, 16853, 100996, 118621])
    logits = ctypes.cast(model._ctx.get_logits(), ctypes.POINTER(ctypes.c_float))
    result = {
        "sha256": pinned,
        "prompt_tokens": token_ids,
        "varied_tokens": varied,
        "teacher_forced_logits": {str(i): logits[i] for i in (73752, 63141)},
        "raw_completions": {},
    }
    for name, text in (
        ("chat", "Hello! What is two plus two? Please answer briefly."),
        ("food", "Classify food risk. Raw chicken left in sunlight for two days, smells rotten. Reply exactly Low, Medium, or High."),
    ):
        result["raw_completions"][name] = model(text, max_tokens=16, temperature=0, repeat_penalty=1)["choices"][0]["text"]
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
