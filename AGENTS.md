# PPT Selective Rework Pipeline

## Product contract

- This repository is one portable Codex Desktop Local Project for both the setup PC and the operator PC. The operator opens the same repository root in Codex Desktop and runs the same rules, scripts, imagegen workflow, dashboard, and job state; do not create a separate staff-only app, reduced package, or divergent code path.
- Treat the PPTX presentation order as the canonical slide inventory.
- Never edit files under `00_input`. Build outputs from a copy.
- Reference PNG archives are visual evidence only. Map their entries by archive order, not by filename.
- Flag every PPTX slide without a matching reference image. Do not silently drop it.
- The first production gates are page triage and primary-color approval.
- Automatic triage is complete only when every slide's actual decision status is populated. A recommendation badge beside an `unreviewed` decision is not classification.
- Persist decision provenance (`auto_visual`, `auto_heuristic`, or `human`) and preserve every human override when inventory or automation is rerun.
- A visual-triage thumbnail must open the current original-resolution reference in an accessible large viewer with zoom. Thumbnail-only review is not sufficient evidence for a keep/rework decision.
- The triage dashboard must provide a fullscreen original-slide review mode in canonical PPTX order: `ArrowLeft`/`ArrowRight` navigate, `Space` toggles a persisted human rework selection, the marked state is visually unmistakable without covering any source-image pixels, and a live checked-slide list supports direct jumps. Keyboard shortcuts must not fire while the reviewer is editing a text field or activating another control.
- `02_triage/criteria.json` is the job-level source of truth for both triage criteria and rework-output constraints. Keep its source URL and evidence lineage with the job.
- Do not confuse production constraints with selection triggers. A simple or lightly decorated slide stays `keep` when its essential content is readable and its hierarchy and context are clear.
- Rework selection is limited to material failures in readability, density, hierarchy, content integrity, context communication, or missing visual evidence; show the triggered criterion IDs beside the decision.
- Rework only slides explicitly selected by a human reviewer.
- A selected slide rework is a raster-image generation/edit task. Use the built-in `imagegen` workflow with the current original-resolution reference PNG as the edit target; do not substitute PowerPoint shape editing, HTML/CSS/canvas reconstruction, or a newly authored PPT slide for the requested image generation.
- Load every local reference PNG with `view_image` before its imagegen call. Issue one built-in imagegen call per requested slide or variant and label the reference as the edit target in the prompt.
- Save generated rework images non-destructively under `04_rework/slide-####/v###.png` with their prompt, source slide, version, and review state. Never overwrite the original reference or a previously reviewed version.
- The review dashboard must show the original reference and the exact generated version together as Before/After. A rejected version and its reason remain in lineage and the next attempt uses a new version.
- Imagegen text drift, altered numbers, replaced logos/photos, invented evidence, cropped objects, blur, or non-16:9 output are hard failures. Directly inspect the generated full-size image and regenerate failures before presenting them for approval.
- When imagegen improves the layout but re-renders dense screenshot text or figures incorrectly, keep the imagegen-created composition and pixel-lock the affected evidence by compositing an exact crop from the original reference PNG. Record source and destination crop geometry with the version. Do not substitute PPT editing for this imagegen-plus-source-evidence workflow.
- Treat the deck's top header chrome and right vertical rail as immutable template content on every slide, not optional decoration. Preserve the course/instructor text, horizontal rule, top-right icon, vertical rule, and `Digital Nomad High Class` text from the original PNG exactly; missing or re-rendered chrome is a hard failure and must be repaired non-destructively with recorded source pixel-lock crops.
- Every selected rework must preserve the original wording, numbers, sources, photos, logos, existing illustrations, and intentional emphasis. Use the current slide as the editing reference.
- Rework outputs stay 16:9 at 1920x1080. Use 40pt or larger for essential body copy by default; split or add a readable evidence inset instead of shrinking long text or screenshots.
- Lock the job's primary color before batch production. Add only context-relevant icons, frames, lines, and emphasis; improve design density by one step without creating new clutter, and keep line/arrow weight, spacing, direction, crops, and joins clean.
- Approved slide versions are immutable unless the reviewer explicitly reopens them.
- Do not assemble a final deck while selected slides remain unreviewed or rejected.
- PPTX editing or assembly starts only after the image-generated replacement versions are approved; it is not the rework-generation mechanism.
- Persist queue and review state after every slide so an interrupted 500-slide job can resume.
- The triage dashboard in this same Local Project must list the job's rework/modification criteria directly and provide add/edit/delete/save controls that persist to `02_triage/criteria.json`; a source hyperlink alone is not an editable criteria surface.

## Workspace boundaries

- Shared application code lives at the repository root.
- Each deck lives under one isolated `jobs/<job-id>` folder.
- Move or install the repository and its active `jobs/<job-id>` folders together. Job launchers must resolve the pipeline and job from their own relative location, never from a setup-PC absolute path.
- During routine deck production on the operator PC, treat repository-level application code, scripts, templates, and documentation as read-only; create and update production artifacts only inside the active `jobs/<job-id>`. Change the shared pipeline only when the user explicitly requests pipeline maintenance.
- Generated source previews, review decisions, and final outputs stay inside that job folder.
- Large source decks and extracted slide images must not be committed to Git.

## Verification

- Verify source count, aspect ratio, image dimensions, and reference coverage from the actual files.
- Visual acceptance requires direct review of the current HTML dashboard and current slide renders.
- A script exit code or generated filename is not visual approval.
