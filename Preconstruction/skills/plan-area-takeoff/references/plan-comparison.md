# Existing and proposed plan comparison

Use for overlays of as-built/existing, demolition, proposed or revised plans. Create an evidence-preserving registration, not a redesigned floor plan. Label the source's status accurately: an architectural existing-condition sheet is not a field-verified as-built survey.

## Register the plans

1. Record each source file/revision, sheet and PDF page, page rotation, render resolution, pixel dimensions and crop. Isolate matching floor-plan viewports, excluding title blocks and unrelated details. Preserve the uncropped source.
2. Calibrate both views independently. Align using retained building features with corresponding witness points, such as unchanged wall corners or column centers. Avoid room names, furniture, moved partitions and page borders. Use at least three well-spread controls, preferably more, and reserve independent landmarks for validation.
3. Start with translation/rotation/uniform-scale registration (similarity transform). Record matrix, point pairs, residuals in pixels and real units, and independent landmark errors. Use a documented affine correction only when independent evidence demonstrates scan distortion. Do not freely warp plans to erase actual differences.
4. Inspect retained geometry across the entire footprint. Investigate mismatches as registration error, different drawing wall-face conventions, scan distortion or actual revision. If good global registration cannot be established, show alignment limits or separate local comparisons with their transforms. Do not imply exact coincidence.
5. Keep comparison transforms separate from takeoff calibration and manifests. An overlay fit must not silently change previously accepted quantities. Never reuse raw coordinates across different raster frames merely because PDF page numbers match.

## Render and explain

Use a colorblind-friendly pair such as orange for existing and blue for proposed, with coincident linework dark/neutral. Preserve source linework; show titles, source pages, color legend and "Do not scale". Provide an overview and readable detail views if a full sheet makes changes too small. An optional layered PDF or slider can help compare dense plans, but a static export must be understandable on its own.

Label the view as a drawing comparison. Different-colored dimensions, text, symbols and furniture are drawing differences, not confirmed demolition or new construction. Summarize major spatial changes only after inspecting the actual plan, demolition sheet and scope. Do not derive structural removal quantities by pixel subtraction.

Save reproducible registration inputs with the artifact when useful. Reopen and render the final export; check source identity, orientation, no mirroring, retained corners, additions and distant validation landmarks. Quantify alignment residuals instead of describing a scanned comparison as exact.
