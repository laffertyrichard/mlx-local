# Dependencies and non-disruptive runtime evidence

Observed 2026-10-19 using files, executable lookup and package metadata only. No inference, downloads, installs, new workers, app restarts, heavy benchmarks or ODA launch occurred.

| Component | Needed for | Observed/requirement |
|---|---|---|
| macOS 14+, Apple silicon, Swift tools 6.0 | Actual mlx-local stack | `Package.swift` defines SwiftUI executable, LocalLLMCore, LocalInferenceBackends, RouterEvaluation, MultimodalSmoke and ConstructionTracer. SDK/compiler build not run for packaging |
| Python 3.10+ standard library | Area helper, fixtures and package contracts | Default `/opt/homebrew/bin/python3` available; core checks need no pip packages |
| ezdxf | CAD inspect/extract/render/annotate | 1.4.4 in existing `/opt/homebrew/anaconda3/bin/python`; absent from default Python. CAD is optional |
| PyMuPDF (`fitz`) | CAD SVG render regression; optional PDF tooling | 1.28.0 in same Anaconda interpreter, absent default Python |
| Shapely | Optional production topology prototype | 2.1.2 in Anaconda; not required by area helper. Claude must implement or explicitly configure a deterministic Boolean engine, not silently skip topology |
| Pillow/openpyxl | Optional raster/workbook tooling | 11.3.0 / 3.1.5 in Anaconda; not bundled or required for core tests. openpyxl alone does not recalculate workbook formulas |
| ODA File Converter | Optional DWG conversion | Author workspace documents existing app. This package did not launch or validate it; DWG conversion gate remains unavailable until actual versioned conversion/render test |
| MLX-LM / MLX-VLM / MLX-Audio workers | Existing local text/vision/OCR/speech | Executables present in `~/.local/bin`; isolated tool environments, not the default Python imports. No worker launched and no live health inferred |
| Native PDFKit/AppKit | Existing text extraction, rasterization and image normalization | Already implemented in LocalInferenceBackends; use these first for local PDF MVP |
| Workbook recalculation/export | Paired delivery gate | No engine assumed. Choose a deterministic formula cache/export strategy; if recalculation/rendering unavailable, report unavailable and block final release for that requested output |
| Blender/IFC/Prime | Optional future modeling | Not required, not packaged, no connection or startup authorized |

Use explicit runtime paths on this Mac only after the user selects them. Portable configuration defaults do not embed the Anaconda path. No `pip install`, `uv tool install`, runtime upgrade or security/configuration change belongs to this packaging task or unattended import.

The runtime snapshot in `runtime-summary.json` was last written 2026-10-06 and contains 27 records (17 mlx-lm, 9 mlx-vlm, 1 whisper-mlx). Its `healthy`/`unloaded` values are stale snapshot metadata, **not current process state**. Candidate cached families include Qwen3-VL-8B/30B, compact PaddleOCR, dots.ocr/olmOCR, and Qwen/Nemotron text models. Inspect the actual cache config and runtime compatibility before selection. Metadata context windows up to 262144 do not establish usable KV budget or small-dimension reading accuracy.

The repo MODEL-GUIDE reports M4 Pro/64 GiB as prior hardware evidence. A current sysctl query was denied by the environment; available unified memory and current trade-pricing workload were not established. Reserve capacity dynamically, let the user choose a resource cap, and defer rather than displace unrelated workers. No benchmark recommendation overrides current resource admission.
