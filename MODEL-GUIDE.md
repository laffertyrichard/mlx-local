# Model guide for this Mac

Hardware observed: Mac mini (Mac16,11), Apple M4 Pro with 14 CPU cores, 20 GPU cores, 64 GiB unified memory, and roughly 1.1 TiB free SSD space. MLX 0.31.2 and MLX-LM 0.31.3 are installed. The Hugging Face cache currently holds about 371 GiB.

## Recommended daily choices

| Use | Model | Cached size | Local benchmark evidence | Suggested settings |
|---|---|---:|---|---|
| Best balanced default | `mlx-community/Qwen3.6-35B-A3B-4bit` | ~19 GiB | Cleanup .965; codegen .943; fast MoE | no-think, decode 4, 32K routine context |
| Best fast coding/agents | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | ~16 GiB | Purpose-built coder; 3B active MoE | no-think, decode 4, 32–64K context |
| Preferred abliterated | `mlx-community/Huihui-Qwen3.6-27B-abliterated-4.5bit-msq` | ~16 GiB | Codegen .971 (35/36); cleanup .937 | no-think, decode 2, 32K context |
| Proven fast general | `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit` | ~16 GiB | Cleanup .965 at ~61 tok/s | no-think, decode 4 |
| Maximum dense coding | `mlx-community/Qwen3.6-27B-4bit` | ~15 GiB | Codegen .971 (35/36) | no-think, decode 2 |
| Heavy reasoning ceiling | `mlx-community/Llama-3.3-70B-Instruct-4bit` or DeepSeek 70B | ~37 GiB | Fits, but little headroom | one request, 8–16K routine context |

The menu defaults to Huihui Qwen3.6 27B because abliterated models were requested. For autonomous code editing and reliable tool JSON, Qwen3-Coder 30B A3B or official Qwen3.6 35B A3B should normally be safer and faster.

## Operating envelope

- Sweet spot: 27–35B total parameters at 4–5 bits. A3B MoE variants give substantially better throughput.
- Routine context: 32K. Use 64K for one or two agents after checking memory pressure; native 262K support is not a practical target on 64 GiB.
- Dense 27–32B: decode concurrency 2, prompt concurrency 1.
- A3B MoE: decode concurrency 4, prompt concurrency 1; reduce concurrency for long contexts.
- 70B 4-bit: concurrency 1, preferably 8–16K context. 32K is an upper practical experiment, not a routine default.
- Keep prompt caches capped. MLX Menu currently uses two entries and a 4 GiB cap.

## Benchmark caveats

The text suites are small (7 cleanup, 5 reasoning, 5 codegen tasks) and many results are single runs. Thinking mode was dramatically slower and sometimes harmed formatting. The abliterated Huihui model reached 1.0 on the five-task reasoning suite with thinking enabled, but needed roughly 1,195 seconds; thinking codegen regressed to .800 and took roughly 1,969 seconds. Abliteration lowers refusal behavior but can reduce instruction hierarchy and tool/schema fidelity, so it should not automatically be treated as a quality upgrade.
