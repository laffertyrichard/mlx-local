# Installed Model Registry

Generated from the installed runtime snapshot after the final V2 install. Memory is the conservative admission estimate (cached size/benchmark peak plus headroom), not only weight-file size.

| Identifier | Backend | Memory estimate | Capabilities | Health / state |
|---|---:|---:|---|---|
| `divinetribe/gemma-4-31b-it-abliterated-4bit-mlx` | mlx-vlm | 19.9 GB | comparison, document_understanding, general_chat, long_context, multi_image_vision, reasoning, summarization, vision, visual_reasoning | healthy / unloaded |
| `mlx-community/DeepSeek-R1-Distill-Llama-70B-4bit` | mlx-lm | 45.7 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |
| `mlx-community/DeepSeek-R1-Distill-Qwen-32B-4bit` | mlx-lm | 21.2 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |
| `mlx-community/dots.ocr-8bit` | mlx-vlm | 6.9 GB | OCR, document_understanding, structured_extraction | healthy / unloaded |
| `mlx-community/gemma-4-26b-a4b-it-4bit` | mlx-vlm | 35.6 GB | comparison, document_understanding, general_chat, long_context, multi_image_vision, reasoning, summarization, vision, visual_reasoning | healthy / unloaded |
| `mlx-community/gemma-4-31B-it-qat-4bit` | mlx-vlm | 33.2 GB | comparison, document_understanding, general_chat, long_context, multi_image_vision, reasoning, summarization, vision, visual_reasoning | healthy / unloaded |
| `mlx-community/Huihui-Qwen3.6-27B-abliterated-4.5bit-msq` | mlx-lm | 19.5 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |
| `mlx-community/Kimi-Linear-48B-A3B-Instruct-4bit` | mlx-lm | 31.8 GB | comparison, general_chat, reasoning, summarization | healthy / unloaded |
| `mlx-community/Kimi-VL-A3B-Thinking-2506-6bit` | mlx-vlm | 15.9 GB | comparison, document_understanding, general_chat, multi_image_vision, reasoning, structured_extraction, vision, visual_reasoning | healthy / unloaded |
| `mlx-community/Llama-3.3-70B-Instruct-4bit` | mlx-lm | 45.7 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |
| `mlx-community/olmOCR-7B-0725-8bit` | mlx-vlm | 12.3 GB | OCR, document_understanding, structured_extraction | healthy / unloaded |
| `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | mlx-lm | 21.2 GB | coding, general_chat, long_context, reasoning, structured_extraction, summarization, tool_use | healthy / unloaded |
| `mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit` | mlx-lm | 19.8 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |
| `mlx-community/Qwen3-32B-4bit` | mlx-lm | 21.2 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |
| `mlx-community/Qwen3-ASR-0.6B-8bit` | whisper-mlx | 2.1 GB | audio_understanding, speech_to_text | healthy / unloaded |
| `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | mlx-lm | 19.8 GB | coding, general_chat, long_context, reasoning, structured_extraction, summarization, tool_use | healthy / unloaded |
| `mlx-community/Qwen3-VL-30B-A3B-Instruct-4bit` | mlx-vlm | 22.5 GB | comparison, document_understanding, general_chat, multi_image_vision, reasoning, structured_extraction, summarization, vision, visual_reasoning | healthy / unloaded |
| `mlx-community/Qwen3-VL-8B-Instruct-4bit` | mlx-vlm | 8.3 GB | comparison, document_understanding, general_chat, multi_image_vision, reasoning, structured_extraction, summarization, vision, visual_reasoning | healthy / unloaded |
| `mlx-community/Qwen3.6-27B-4bit` | mlx-lm | 18.5 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |
| `mlx-community/Qwen3.6-35B-A3B-4bit` | mlx-lm | 23.5 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |
| `mlx-community/QwQ-32B-4bit` | mlx-lm | 21.2 GB | comparison, general_chat, long_context, reasoning, summarization | healthy / unloaded |

Machine-readable source: `~/Library/Application Support/MLXMenu/registry.json`. Capability overrides: `ModelMetadata/capabilities.json`. Measurements: `Benchmarks/local-results.json`.
