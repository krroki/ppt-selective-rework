const state = {
  data: null,
  filter: "all",
  search: "",
  page: 1,
  pageSize: 24,
  reworkFilter: "all",
  reworkCriteriaDraft: null,
  reworkCriteriaDirty: false,
  reworkCriteriaSaving: false,
  lightbox: {
    slideNumber: null,
    order: [],
    zoom: "fit",
    assetKind: "before",
    context: "triage",
    updating: false,
  },
};

const lightboxZoomLevels = [50, 75, 100, 125, 150, 200];
let lightboxOpener = null;

const signalLabels = {
  reference_missing: "PNG 누락",
  dense_text: "텍스트 과밀",
  many_text_runs: "텍스트 조각 다수",
  small_text_ratio: "작은 글자 비율",
  low_global_contrast: "낮은 전체 대비",
};

const statusLabels = {
  unreviewed: "미분류",
  keep: "유지",
  rework: "재작업",
  uncertain: "판단 필요",
};

const sourceLabels = {
  human: "직원 수정",
  auto_visual: "AI 시각 판정",
  auto_heuristic: "규칙 자동판정",
};

const reworkReviewLabels = {
  pending: "검수 대기",
  approved: "확정",
  rejected: "반려 · 재작업 대기",
  queued: "생성 대기",
  internal_rejected: "내부 반려",
};

const byId = (id) => document.getElementById(id);

function effectiveDecisionSource(slide) {
  if (slide.source === "human") return "human";
  if (slide.updatedAt && slide.autoUpdatedAt && slide.updatedAt !== slide.autoUpdatedAt) return "human";
  return slide.source;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function rubricItems(value) {
  if (!Array.isArray(value)) return [];
  return value.map((item, index) => typeof item === "string"
    ? { id: `criterion-${index + 1}`, label: item, description: "" }
    : {
        id: item.id || item.code || `criterion-${index + 1}`,
        label: item.label || item.title || item.name || item.id || `기준 ${index + 1}`,
        description: item.description || item.detail || item.rule || item.reason || "",
      });
}

function normalizedRubric() {
  const rubric = state.data?.rubric;
  if (!rubric) return null;
  const source = rubric.source || rubric.reference || {};
  const classification = rubric.classification || {};
  const reworkContract = rubric.reworkContract || {};
  const style = rubric.style || rubric.primaryColor || rubric.primary || {};
  const reworkCriteria = rubricItems(
    reworkContract.criteria
      || reworkContract.reworkCriteria
      || reworkContract.modificationCriteria
      || rubric.reworkCriteria,
  );
  return {
    classification: rubricItems(classification.criteria || rubric.classificationCriteria || rubric.triageCriteria || rubric.criteria),
    output: rubricItems(reworkContract.criteria || rubric.reworkOutputContract || rubric.outputContract || rubric.reworkCriteria),
    reworkCriteria,
    classificationPrinciple: classification.principle || "",
    keepRule: classification.keepRule || "",
    uncertainRule: classification.uncertainRule || "",
    reworkPrinciple: reworkContract.principle || "",
    sourceTitle: typeof source === "string" ? source : source.title || source.label || "최초 작업 기준",
    sourceUrl: typeof source === "object" ? source.url || source.href || rubric.sourceUrl : rubric.sourceUrl,
    reviewedAt: typeof source === "object" ? source.reviewedAt : "",
    provenance: rubric.provenance || rubric.method || (typeof source === "object" ? source.summary || source.provenance || source.note : "") || "작업 기준 원문에서 정리",
    primaryCandidate: typeof style === "string" ? style : style.primaryCandidate || style.candidate || style.hex || style.value || rubric.primaryCandidate,
    primaryConfirmed: typeof style === "object" ? Boolean(style.primaryConfirmed) : false,
    primaryNote: typeof style === "object" ? style.note || "" : "",
  };
}

function safeExternalUrl(value) {
  try {
    const url = new URL(value);
    return ["http:", "https:"].includes(url.protocol) ? url.href : "";
  } catch {
    return "";
  }
}

function criterionLabel(id) {
  const rubric = normalizedRubric();
  const item = [...(rubric?.classification || []), ...(rubric?.output || []), ...(rubric?.reworkCriteria || [])]
    .find((criterion) => criterion.id === id);
  return item?.label || id;
}

function copyCriteria(items) {
  return items.map((item) => ({
    id: String(item.id || ""),
    label: String(item.label || ""),
    description: String(item.description || ""),
  }));
}

function renderReworkCriteriaEditorState() {
  const status = byId("rework-criteria-state");
  const save = byId("save-rework-criteria");
  const add = byId("add-rework-criterion");
  if (!status || !save || !add) return;

  const count = state.reworkCriteriaDraft?.length || 0;
  if (state.reworkCriteriaSaving) {
    status.textContent = `${count}개 · 저장 중…`;
    status.className = "criteria-editor-state is-saving";
  } else if (state.reworkCriteriaDirty) {
    status.textContent = `${count}개 · 저장 전 변경사항`;
    status.className = "criteria-editor-state is-dirty";
  } else {
    status.textContent = `${count}개 · 저장됨`;
    status.className = "criteria-editor-state is-saved";
  }
  save.disabled = state.reworkCriteriaSaving || !state.reworkCriteriaDirty;
  save.textContent = state.reworkCriteriaSaving ? "저장 중…" : "수정 기준 저장";
  add.disabled = state.reworkCriteriaSaving;
  byId("rework-criteria-editor-list")
    ?.querySelectorAll("input, textarea, button")
    .forEach((control) => { control.disabled = state.reworkCriteriaSaving; });
}

function renderReworkCriteriaEditor(rubric) {
  if (!Array.isArray(state.reworkCriteriaDraft)) {
    state.reworkCriteriaDraft = copyCriteria(rubric.reworkCriteria);
  }

  const list = byId("rework-criteria-editor-list");
  list.innerHTML = state.reworkCriteriaDraft.length
    ? state.reworkCriteriaDraft.map((item, index) => `
        <article class="criterion-editor-row" data-rework-criterion-index="${index}">
          <div class="criterion-editor-row-head">
            <span>RULE ${String(index + 1).padStart(2, "0")}</span>
            <button class="criterion-delete" type="button" data-criterion-action="delete" aria-label="${escapeHtml(item.label || item.id || `기준 ${index + 1}`)} 삭제">삭제</button>
          </div>
          <div class="criterion-editor-fields">
            <label class="criterion-field criterion-field-id">
              <span>기준 ID</span>
              <input type="text" value="${escapeHtml(item.id)}" data-criterion-field="id" autocomplete="off" required />
            </label>
            <label class="criterion-field criterion-field-label">
              <span>기준명</span>
              <input type="text" value="${escapeHtml(item.label)}" data-criterion-field="label" autocomplete="off" required />
            </label>
            <label class="criterion-field criterion-field-description">
              <span>적용 설명</span>
              <textarea rows="2" data-criterion-field="description" required>${escapeHtml(item.description)}</textarea>
            </label>
          </div>
        </article>
      `).join("")
    : `
        <div class="criteria-editor-empty">
          <strong>등록된 수정 기준이 없습니다.</strong>
          <span>‘+ 기준 추가’를 눌러 첫 기준을 만드세요.</span>
        </div>
      `;
  renderReworkCriteriaEditorState();
}

function nextReworkCriterionId() {
  const used = new Set((state.reworkCriteriaDraft || []).map((item) => item.id.trim().toUpperCase()));
  let number = state.reworkCriteriaDraft.length + 1;
  while (used.has(`REWORK-${String(number).padStart(2, "0")}`)) number += 1;
  return `REWORK-${String(number).padStart(2, "0")}`;
}

function addReworkCriterion() {
  state.reworkCriteriaDraft.push({ id: nextReworkCriterionId(), label: "", description: "" });
  state.reworkCriteriaDirty = true;
  renderReworkCriteriaEditor(normalizedRubric());
  const row = byId("rework-criteria-editor-list").lastElementChild;
  row?.querySelector('[data-criterion-field="label"]')?.focus();
  row?.scrollIntoView({ behavior: "smooth", block: "nearest" });
}

function validateReworkCriteria() {
  const criteria = copyCriteria(state.reworkCriteriaDraft).map((item) => ({
    id: item.id.trim(),
    label: item.label.trim(),
    description: item.description.trim(),
  }));
  const invalidIndex = criteria.findIndex((item) => !item.id || !item.label || !item.description);
  if (invalidIndex >= 0) {
    const row = byId("rework-criteria-editor-list").querySelector(`[data-rework-criterion-index="${invalidIndex}"]`);
    const missingField = !criteria[invalidIndex].id
      ? "id"
      : !criteria[invalidIndex].label
        ? "label"
        : "description";
    row?.querySelector(`[data-criterion-field="${missingField}"]`)?.focus();
    throw new Error("기준 ID, 기준명, 적용 설명을 모두 입력하세요.");
  }
  const ids = criteria.map((item) => item.id.toUpperCase());
  const duplicateIndex = ids.findIndex((id, index) => ids.indexOf(id) !== index);
  if (duplicateIndex >= 0) {
    byId("rework-criteria-editor-list")
      .querySelector(`[data-rework-criterion-index="${duplicateIndex}"] [data-criterion-field="id"]`)
      ?.focus();
    throw new Error("기준 ID는 서로 달라야 합니다.");
  }
  return criteria;
}

async function saveReworkCriteria() {
  let criteria;
  try {
    criteria = validateReworkCriteria();
  } catch (error) {
    toast(error.message);
    return;
  }

  state.reworkCriteriaSaving = true;
  renderReworkCriteriaEditorState();
  try {
    const response = await api("/api/criteria", {
      method: "PUT",
      body: JSON.stringify({ reworkCriteria: criteria }),
    });
    const returnedRubric = response?.rubric || response || {};
    const returnedCriteria = Array.isArray(returnedRubric)
      ? returnedRubric
      : returnedRubric?.reworkContract?.criteria || returnedRubric?.reworkCriteria || criteria;
    const returnedRubricFields = returnedRubric && typeof returnedRubric === "object" && !Array.isArray(returnedRubric)
      ? returnedRubric
      : {};
    const baseRubric = { ...(state.data.rubric || {}), ...returnedRubricFields };
    delete baseRubric.reworkCriteria;
    baseRubric.reworkContract = {
      ...(state.data.rubric?.reworkContract || {}),
      ...(returnedRubric?.reworkContract || {}),
      criteria: copyCriteria(rubricItems(returnedCriteria)),
    };
    state.data.rubric = baseRubric;
    state.reworkCriteriaDraft = copyCriteria(baseRubric.reworkContract.criteria);
    state.reworkCriteriaDirty = false;
    toast("수정 기준을 저장했습니다.");
  } catch (error) {
    toast(error.message);
  } finally {
    state.reworkCriteriaSaving = false;
    renderCriteriaBoard();
  }
}

function renderCriteriaBoard() {
  const board = byId("criteria-board");
  const rubric = normalizedRubric();
  if (!rubric) {
    board.hidden = true;
    return;
  }

  board.hidden = false;
  const renderItems = (items) => items.length
    ? items.map((item) => `
        <article class="criterion" data-criterion="${escapeHtml(item.id)}">
          <span class="criterion-id">${escapeHtml(item.id)}</span>
          <div><strong>${escapeHtml(item.label)}</strong>${item.description ? `<p>${escapeHtml(item.description)}</p>` : ""}</div>
        </article>
      `).join("")
    : '<p class="criteria-empty">등록된 기준이 없습니다.</p>';
  byId("classification-criteria").innerHTML = renderItems(rubric.classification);
  byId("rework-contract").innerHTML = renderItems(rubric.output);
  renderReworkCriteriaEditor(rubric);
  byId("classification-policy").innerHTML = `
    ${rubric.classificationPrinciple ? `<p class="policy-principle">${escapeHtml(rubric.classificationPrinciple)}</p>` : ""}
    ${rubric.keepRule ? `<p><strong>KEEP</strong>${escapeHtml(rubric.keepRule)}</p>` : ""}
    ${rubric.uncertainRule ? `<p><strong>UNCERTAIN</strong>${escapeHtml(rubric.uncertainRule)}</p>` : ""}
  `;
  byId("rework-policy").innerHTML = rubric.reworkPrinciple
    ? `<p class="policy-principle">${escapeHtml(rubric.reworkPrinciple)}</p>`
    : "";

  const sourceUrl = safeExternalUrl(rubric.sourceUrl);
  const source = sourceUrl
    ? `<a href="${escapeHtml(sourceUrl)}" target="_blank" rel="noreferrer">${escapeHtml(rubric.sourceTitle)} ↗</a>`
    : `<strong>${escapeHtml(rubric.sourceTitle)}</strong>`;
  const savedPrimary = state.data.style?.primary;
  const palettePrimary = state.data.palette?.candidates?.[0]?.hex;
  const primary = savedPrimary || rubric.primaryCandidate || palettePrimary || "미정";
  const confirmed = state.data.style ? Boolean(state.data.style.confirmed) : rubric.primaryConfirmed;
  const sourceDate = rubric.reviewedAt ? ` · ${rubric.reviewedAt} 확인` : "";
  byId("criteria-provenance").innerHTML = `
    <div class="criteria-source"><span>SOURCE${escapeHtml(sourceDate)}</span>${source}<small>${escapeHtml(rubric.provenance)}</small></div>
    <div class="primary-state ${confirmed ? "is-confirmed" : "is-candidate"}">
      <span class="primary-dot" style="--primary-preview:${/^#[0-9A-Fa-f]{6}$/.test(primary) ? primary : "#d9ff57"}"></span>
      <span><small>PRIMARY ${confirmed ? "CONFIRMED" : "CANDIDATE"}</small><strong>${escapeHtml(primary)}</strong>${rubric.primaryNote ? `<em title="${escapeHtml(rubric.primaryNote)}">기준 메모</em>` : ""}</span>
    </div>
  `;
}

async function api(url, options = {}) {
  const response = await fetch(url, {
    headers: { "content-type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || `Request failed: ${response.status}`);
  return payload;
}

async function optionalJobJson(relativePath) {
  const response = await fetch(`/job/${relativePath}`, { cache: "no-store" });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error(`작업 기준을 불러오지 못했습니다: ${response.status}`);
  return response.json();
}

async function loadRubricFallback() {
  if (state.data.rubric) return;
  const [rubric, autoAudit] = await Promise.all([
    optionalJobJson("02_triage/criteria.json"),
    optionalJobJson("02_triage/auto-audit.json"),
  ]);
  state.data.rubric = rubric;
  const auditBySlide = new Map((autoAudit?.slides || []).map((item) => [item.slide, item]));
  state.data.slides.forEach((slide) => {
    const criteria = auditBySlide.get(slide.slide)?.criteria;
    if (Array.isArray(criteria)) slide.criteria = criteria;
  });
}

function toast(message) {
  const element = byId("toast");
  element.textContent = message;
  element.classList.add("is-visible");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.classList.remove("is-visible"), 2200);
}

function filteredSlides() {
  if (!state.data) return [];
  return state.data.slides.filter((slide) => {
    if (state.filter !== "all" && slide.status !== state.filter) return false;
    if (state.search && String(slide.slide) !== state.search.trim()) return false;
    return true;
  });
}

function canonicalSlides() {
  return [...(state.data?.slides || [])].sort((a, b) => a.slide - b.slide);
}

function checkedReworkSlides() {
  return canonicalSlides().filter((slide) => slide.status === "rework");
}

function checkedSlideMarkup(slide, activeSlide = null) {
  const number = String(slide.slide).padStart(3, "0");
  const title = slide.text?.split("\n").find(Boolean)?.slice(0, 70) || `슬라이드 ${slide.slide}`;
  return `<button class="checked-slide-chip ${slide.slide === activeSlide ? "is-current" : ""}" type="button" data-checked-slide="${slide.slide}" title="${escapeHtml(title)}" aria-label="재작업 체크된 슬라이드 ${slide.slide}로 이동"><span aria-hidden="true">✓</span>${number}</button>`;
}

function renderCheckedSlideLists() {
  const checked = checkedReworkSlides();
  const listMarkup = checked.length
    ? checked.map((slide) => checkedSlideMarkup(slide)).join("")
    : '<p class="checked-list-empty">아직 체크된 슬라이드가 없습니다. 전체화면에서 <kbd>SPACE</kbd>를 눌러 체크하세요.</p>';
  const pageList = byId("checked-slide-list");
  if (pageList) pageList.innerHTML = listMarkup;
  const pageCount = byId("checked-slide-count");
  if (pageCount) pageCount.textContent = `${checked.length}장`;

  const lightboxList = byId("lightbox-checked-list");
  if (lightboxList) {
    lightboxList.innerHTML = checked.length
      ? checked.map((slide) => checkedSlideMarkup(slide, state.lightbox.slideNumber)).join("")
      : '<p class="checked-list-empty">체크된 슬라이드 없음</p>';
  }
  const lightboxCount = byId("lightbox-checked-count");
  if (lightboxCount) lightboxCount.textContent = String(checked.length);

  document.querySelectorAll("[data-checked-slide]").forEach((button) => {
    button.addEventListener("click", () => {
      const slideNumber = Number(button.dataset.checkedSlide);
      const dialog = byId("image-lightbox");
      if (dialog.open && button.closest(".lightbox-check-panel")) {
        state.lightbox.slideNumber = slideNumber;
        renderLightbox();
        dialog.focus({ preventScroll: true });
        return;
      }
      openLightbox(slideNumber, button, "before", "triage");
    });
  });
}

async function updateSlideStatus(slideNumber, status) {
  const slide = state.data.slides.find((item) => item.slide === slideNumber);
  if (!slide) throw new Error(`슬라이드 ${slideNumber}을 찾을 수 없습니다.`);
  const updated = await api(`/api/slides/${slideNumber}`, {
    method: "PATCH",
    body: JSON.stringify({ status }),
  });
  Object.assign(slide, updated);
  renderHeader();
  renderSlides();
  renderCheckedSlideLists();
  if (byId("image-lightbox")?.open && state.lightbox.slideNumber === slideNumber) renderLightbox();
  return slide;
}

function currentReworkVersion(slide) {
  if (!slide?.rework?.currentVersion) return null;
  return slide.rework.versions?.find((version) => version.version === slide.rework.currentVersion) || null;
}

function effectiveReworkStatus(slide) {
  const version = currentReworkVersion(slide);
  if (!version) return "queued";
  if (version.reviewStatus) return version.reviewStatus;
  if (version.status === "internal_rejected") return "internal_rejected";
  return "pending";
}

function reworkSlides() {
  const selected = state.data?.slides.filter((slide) => slide.rework) || [];
  if (state.reworkFilter === "all") return selected;
  return selected.filter((slide) => effectiveReworkStatus(slide) === state.reworkFilter);
}

function currentLightboxSlide() {
  return state.data?.slides.find((slide) => slide.slide === state.lightbox.slideNumber) || null;
}

function setLightboxZoom(zoom) {
  const slide = currentLightboxSlide();
  const image = byId("lightbox-image");
  if (!slide || !image) return;

  state.lightbox.zoom = zoom;
  image.classList.toggle("is-fit", zoom === "fit");
  if (zoom === "fit") {
    image.style.width = "";
  } else {
    image.style.width = `${Math.round((image.naturalWidth || slide.imageWidth || 1920) * zoom / 100)}px`;
  }

  byId("lightbox-zoom-label").textContent = zoom === "fit" ? "화면 맞춤" : `${zoom}%`;
  byId("lightbox-fit").classList.toggle("is-active", zoom === "fit");
  byId("lightbox-zoom-out").disabled = zoom !== "fit" && zoom <= lightboxZoomLevels[0];
  byId("lightbox-zoom-in").disabled = zoom !== "fit" && zoom >= lightboxZoomLevels.at(-1);
  byId("lightbox-canvas").scrollTo({ top: 0, left: 0 });
}

function renderLightbox() {
  const slide = currentLightboxSlide();
  if (!slide) return;

  const version = currentReworkVersion(slide);
  const isAfter = state.lightbox.assetKind === "after";
  const assetPath = isAfter ? version?.path : slide.referenceImage;
  const triageMode = state.lightbox.context === "triage" && !isAfter;
  const isMarked = triageMode && slide.status === "rework";
  const isMissing = !assetPath;
  const dialog = byId("image-lightbox");
  dialog.classList.toggle("is-triage-mode", triageMode);
  dialog.classList.toggle("is-rework-marked", isMarked);
  dialog.classList.toggle("is-reference-missing", isMissing);

  const orderIndex = state.lightbox.order.indexOf(slide.slide);
  const source = sourceLabels[effectiveDecisionSource(slide)] || "자동 판정";
  const assetLabel = isAfter ? `AFTER · V${String(version.version).padStart(3, "0")}` : isMissing ? "BEFORE · PNG 누락" : "BEFORE · 원본";
  byId("lightbox-kicker").textContent = `SLIDE ${String(slide.slide).padStart(3, "0")} · ${assetLabel}`;
  byId("lightbox-title").textContent = slide.text?.split("\n").find(Boolean)?.slice(0, 90) || `슬라이드 ${slide.slide}`;
  byId("lightbox-meta").textContent = isAfter
    ? `1920 × 1080 imagegen 재작업본 · ${reworkReviewLabels[effectiveReworkStatus(slide)]}`
    : isMissing ? `원본 PNG가 없는 PPTX 슬라이드 · ${source}` : `${slide.imageWidth || "–"} × ${slide.imageHeight || "–"} 원본 PNG · ${source}`;
  byId("lightbox-position").textContent = `${orderIndex + 1} / ${state.lightbox.order.length}`;
  byId("lightbox-prev").disabled = orderIndex <= 0;
  byId("lightbox-next").disabled = orderIndex < 0 || orderIndex >= state.lightbox.order.length - 1;

  const toggle = byId("lightbox-rework-toggle");
  toggle.hidden = !triageMode;
  toggle.disabled = state.lightbox.updating;
  toggle.classList.toggle("is-checked", isMarked);
  byId("lightbox-rework-state").textContent = isMarked ? "재작업 체크됨" : "재작업 체크";
  byId("lightbox-check-panel").hidden = !triageMode;

  const image = byId("lightbox-image");
  const missing = byId("lightbox-missing");
  image.hidden = isMissing;
  missing.hidden = !isMissing;
  if (isMissing) {
    image.removeAttribute("src");
    missing.innerHTML = `<strong>REFERENCE PNG MISSING</strong><span>PPTX ${slide.slide}번은 원본 이미지가 없어 시각 판단이 불가능합니다.</span><small>누락 자체를 재작업 대상으로 체크할 수 있습니다.</small>`;
    byId("lightbox-fit").disabled = true;
    byId("lightbox-zoom-out").disabled = true;
    byId("lightbox-zoom-in").disabled = true;
  } else {
    image.alt = `슬라이드 ${slide.slide} ${isAfter ? "재작업" : "원본"} 이미지`;
    image.src = `/job/${encodeURI(assetPath)}`;
    byId("lightbox-fit").disabled = false;
    setLightboxZoom("fit");
  }
  renderCheckedSlideLists();
}

function openLightbox(slideNumber, opener, assetKind = "before", context = "triage") {
  const slide = state.data.slides.find((item) => item.slide === slideNumber);
  const version = currentReworkVersion(slide);
  const assetPath = assetKind === "after" ? version?.path : slide?.referenceImage;
  if (!slide) return toast("슬라이드를 찾을 수 없습니다.");
  if (!assetPath && context !== "triage") return toast("크게 볼 이미지가 아직 없습니다.");

  state.lightbox.context = context;
  state.lightbox.assetKind = assetKind;
  const candidates = context === "rework" ? reworkSlides() : canonicalSlides();
  state.lightbox.order = candidates
    .filter((item) => context === "triage" || (assetKind === "after" ? currentReworkVersion(item)?.path : item.referenceImage))
    .map((item) => item.slide);
  if (!state.lightbox.order.includes(slideNumber)) state.lightbox.order = [slideNumber];
  state.lightbox.slideNumber = slideNumber;
  lightboxOpener = opener || document.activeElement;

  const dialog = byId("image-lightbox");
  if (!dialog.open) dialog.showModal();
  document.body.classList.add("lightbox-open");
  renderLightbox();
  dialog.focus({ preventScroll: true });
  if (context === "triage" && !document.fullscreenElement && dialog.requestFullscreen) {
    dialog.requestFullscreen().catch(() => {});
  }
}

function closeLightbox() {
  const dialog = byId("image-lightbox");
  if (document.fullscreenElement === dialog && document.exitFullscreen) document.exitFullscreen().catch(() => {});
  if (dialog.open) dialog.close();
}

async function toggleCurrentLightboxRework() {
  const slide = currentLightboxSlide();
  if (!slide || state.lightbox.context !== "triage" || state.lightbox.assetKind !== "before" || state.lightbox.updating) return;
  state.lightbox.updating = true;
  renderLightbox();
  const nextStatus = slide.status === "rework" ? "keep" : "rework";
  try {
    await updateSlideStatus(slide.slide, nextStatus);
    const dialog = byId("image-lightbox");
    dialog.classList.remove("decision-pulse");
    requestAnimationFrame(() => dialog.classList.add("decision-pulse"));
    setTimeout(() => dialog.classList.remove("decision-pulse"), 420);
    toast(nextStatus === "rework" ? `${slide.slide}번 · 재작업 체크` : `${slide.slide}번 · 재작업 체크 해제`);
  } catch (error) {
    toast(error.message);
  } finally {
    state.lightbox.updating = false;
    renderLightbox();
  }
}

function moveLightbox(direction) {
  const currentIndex = state.lightbox.order.indexOf(state.lightbox.slideNumber);
  const nextIndex = currentIndex + direction;
  if (nextIndex < 0 || nextIndex >= state.lightbox.order.length) return;
  state.lightbox.slideNumber = state.lightbox.order[nextIndex];
  renderLightbox();
}

function changeLightboxZoom(direction) {
  if (state.lightbox.zoom === "fit") {
    setLightboxZoom(direction > 0 ? 100 : 75);
    return;
  }
  const currentIndex = lightboxZoomLevels.indexOf(state.lightbox.zoom);
  const nextIndex = Math.max(0, Math.min(lightboxZoomLevels.length - 1, currentIndex + direction));
  setLightboxZoom(lightboxZoomLevels[nextIndex]);
}

function renderHeader() {
  const { project, slides } = state.data;
  byId("project-title").textContent = project.displayName;
  byId("deck-facts").innerHTML = `
    <div class="deck-fact"><span>SLIDES</span><strong>${project.deck.slideCount}</strong></div>
    <div class="deck-fact"><span>REFERENCE</span><strong>${project.deck.referenceImageCount}</strong></div>
    <div class="deck-fact"><span>RATIO</span><strong>16 : 9</strong></div>
    <div class="deck-fact"><span>PHASE</span><strong>${escapeHtml(project.phase.toUpperCase())}</strong></div>
  `;

  const counts = Object.fromEntries(Object.keys(statusLabels).map((status) => [status, slides.filter((slide) => slide.status === status).length]));
  const reviewed = slides.length - counts.unreviewed;
  const percentage = slides.length ? Math.round((reviewed / slides.length) * 100) : 0;
  byId("progress-label").textContent = `${reviewed} / ${slides.length} 분류 완료`;
  byId("progress-percent").textContent = `${percentage}%`;
  byId("progress-fill").style.width = `${percentage}%`;
  const humanCount = slides.filter((slide) => effectiveDecisionSource(slide) === "human").length;
  const automaticCount = slides.length - humanCount;
  byId("status-counts").innerHTML = Object.entries(statusLabels)
    .map(([status, label]) => `<span class="count-badge">${label} <strong>${counts[status]}</strong></span>`)
    .join("") + `<span class="count-badge origin-count">자동 <strong>${automaticCount}</strong></span><span class="count-badge origin-count">직원 수정 <strong>${humanCount}</strong></span>`;

  const missing = project.deck.missingReferenceSlides || [];
  const notice = byId("reference-notice");
  if (missing.length) {
    notice.hidden = false;
    notice.textContent = `PPTX ${project.deck.slideCount}장 중 PNG 기준 이미지가 없는 슬라이드: ${missing.join(", ")}. 해당 페이지는 자동으로 판단 필요 후보입니다.`;
  } else {
    notice.hidden = true;
  }
}

function slideCard(slide) {
  const signals = (slide.autoSignals || []).length
    ? slide.autoSignals.map((signal) => `<span class="signal">${escapeHtml(signalLabels[signal] || signal)}</span>`).join("")
    : '<span class="signal">자동 위험 신호 없음</span>';
  const effectiveSource = effectiveDecisionSource(slide);
  const source = sourceLabels[effectiveSource] || "자동 판정";
  const sourceClass = effectiveSource === "human" ? "source-human" : "source-auto";
  const baseline = effectiveSource === "human" && slide.autoStatus
    ? `<span class="signal auto-baseline">자동 기준 ${statusLabels[slide.autoStatus]}</span>`
    : "";
  const auditCriteria = Array.isArray(slide.criteria) && slide.criteria.length
    ? `<div class="audit-criteria" aria-label="적용된 검수 기준">${slide.criteria.map((id) => `<span class="criterion-chip" title="${escapeHtml(id)}">${escapeHtml(criterionLabel(id))}</span>`).join("")}</div>`
    : "";
  const image = slide.thumbnail
    ? `<img loading="lazy" src="/job/${encodeURI(slide.thumbnail)}" alt="슬라이드 ${slide.slide} 썸네일" />`
    : `<div class="missing-reference"><div><strong>REFERENCE MISSING</strong><span>PPTX 텍스트는 확인됐지만 PNG가 없습니다.</span></div></div>`;

  return `
    <article class="slide-card" data-slide="${slide.slide}" data-status="${slide.status}">
      <div class="slide-image-wrap ${slide.referenceImage ? "is-zoomable" : ""}" ${slide.referenceImage ? `role="button" tabindex="0" aria-label="슬라이드 ${slide.slide} 원본 크게 보기"` : ""}>
        ${image}
        <span class="slide-number">${String(slide.slide).padStart(3, "0")}</span>
        ${slide.referenceImage ? '<span class="zoom-hint" aria-hidden="true">원본 크게 보기 ↗</span>' : ""}
      </div>
      <div class="slide-body">
        <div class="signal-row">
          ${signals}
          ${baseline}
          <span class="signal decision-origin ${sourceClass}">${source}</span>
        </div>
        ${auditCriteria}
        <div class="slide-metrics">
          <span>${slide.textChars} chars</span>
          <span>${slide.shapeCount} shapes</span>
          <span>${slide.minExplicitFontPt ?? "–"}pt min*</span>
        </div>
        <p class="slide-text">${escapeHtml(slide.text || "텍스트 없음")}</p>
        <div class="status-actions">
          ${["keep", "rework", "uncertain"].map((status) => `<button class="status-button ${slide.status === status ? "is-selected" : ""}" data-value="${status}">${statusLabels[status]}</button>`).join("")}
        </div>
        <textarea class="reason-input" placeholder="재작업 또는 판단 사유를 간단히 입력">${escapeHtml(slide.reason || "")}</textarea>
      </div>
    </article>
  `;
}

function renderSlides() {
  const slides = filteredSlides();
  const pageCount = Math.max(1, Math.ceil(slides.length / state.pageSize));
  state.page = Math.min(state.page, pageCount);
  const start = (state.page - 1) * state.pageSize;
  const visible = slides.slice(start, start + state.pageSize);
  byId("slide-grid").innerHTML = visible.length
    ? visible.map(slideCard).join("")
    : '<p class="notice">현재 조건에 맞는 슬라이드가 없습니다.</p>';
  byId("page-label").textContent = `${state.page} / ${pageCount} · ${slides.length}장`;
  byId("previous-page").disabled = state.page <= 1;
  byId("next-page").disabled = state.page >= pageCount;
  bindSlideCards();
}

function bindSlideCards() {
  document.querySelectorAll(".slide-card").forEach((card) => {
    const slideNumber = Number(card.dataset.slide);
    const slide = state.data.slides.find((item) => item.slide === slideNumber);
    const preview = card.querySelector(".slide-image-wrap.is-zoomable");
    if (preview) {
      preview.addEventListener("click", () => openLightbox(slideNumber, preview));
      preview.addEventListener("keydown", (event) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault();
          openLightbox(slideNumber, preview);
        }
      });
    }
    card.querySelectorAll(".status-button").forEach((button) => {
      button.addEventListener("click", async () => {
        try {
          await updateSlideStatus(slideNumber, button.dataset.value);
        } catch (error) { toast(error.message); }
      });
    });
    const reason = card.querySelector(".reason-input");
    reason.addEventListener("change", async () => {
      try {
        const updated = await api(`/api/slides/${slideNumber}`, {
          method: "PATCH",
          body: JSON.stringify({ reason: reason.value }),
        });
        Object.assign(slide, updated);
        renderHeader();
        renderSlides();
        toast(`${slideNumber}번 메모 저장`);
      } catch (error) { toast(error.message); }
    });
  });
}

function reworkCard(slide) {
  const rework = slide.rework;
  const version = currentReworkVersion(slide);
  const reviewStatus = effectiveReworkStatus(slide);
  const statusLabel = reworkReviewLabels[reviewStatus] || reviewStatus;
  const before = slide.referenceImage
    ? `<button class="comparison-image is-zoomable" type="button" data-kind="before" aria-label="슬라이드 ${slide.slide} 원본 크게 보기">
        <img loading="lazy" src="/job/${encodeURI(slide.referenceImage)}" alt="슬라이드 ${slide.slide} 원본" />
        <span class="comparison-badge">BEFORE</span><span class="comparison-zoom">클릭해서 확대 ↗</span>
      </button>`
    : '<div class="comparison-missing">원본 PNG 없음</div>';
  const after = version?.path
    ? `<button class="comparison-image is-zoomable" type="button" data-kind="after" aria-label="슬라이드 ${slide.slide} 재작업본 크게 보기">
        <img loading="lazy" src="/job/${encodeURI(version.path)}" alt="슬라이드 ${slide.slide} imagegen 재작업본" />
        <span class="comparison-badge is-after">AFTER · V${String(version.version).padStart(3, "0")}</span><span class="comparison-zoom">클릭해서 확대 ↗</span>
      </button>`
    : '<div class="comparison-missing"><strong>IMAGEGEN QUEUED</strong><span>아직 생성본이 등록되지 않았습니다.</span></div>';
  const lineage = (rework.versions || []).map((item) => {
    const itemStatus = item.reviewStatus || (item.status === "internal_rejected" ? "internal_rejected" : "pending");
    return `<span class="version-chip ${item.version === rework.currentVersion ? "is-current" : ""}">V${String(item.version).padStart(3, "0")} · ${escapeHtml(reworkReviewLabels[itemStatus] || itemStatus)}</span>`;
  }).join("");
  const locked = reviewStatus === "approved";
  const reviewDisabled = !version || version.status === "internal_rejected" || locked;
  const reason = version?.reviewReason || rework.reviewReason || "";

  return `
    <article class="rework-card" data-slide="${slide.slide}" data-review-status="${reviewStatus}">
      <header class="rework-card-header">
        <div><span class="rework-slide-number">${String(slide.slide).padStart(3, "0")}</span><strong>재작업 비교 검수</strong></div>
        <span class="review-status status-${reviewStatus}">${escapeHtml(statusLabel)}</span>
      </header>
      <div class="comparison-grid">
        <figure><figcaption>원본 근거</figcaption>${before}</figure>
        <figure><figcaption>imagegen 생성본</figcaption>${after}</figure>
      </div>
      <div class="rework-card-footer">
        <div class="version-lineage" aria-label="버전 이력">${lineage || '<span class="version-chip">버전 없음</span>'}</div>
        ${version?.reason ? `<p class="generation-note"><strong>제작 메모</strong>${escapeHtml(version.reason)}</p>` : ""}
        <label class="review-reason-label">반려 사유
          <textarea class="rework-reason" placeholder="예: 우측 캡처 글자가 깨져 읽히지 않음" ${locked ? "disabled" : ""}>${escapeHtml(reason)}</textarea>
        </label>
        <div class="review-actions">
          <button class="approve-action" type="button" data-review="approved" ${reviewDisabled ? "disabled" : ""}>${locked ? "확정 완료" : "확정"}</button>
          <button class="reject-action" type="button" data-review="rejected" ${reviewDisabled ? "disabled" : ""}>반려 · 다음 버전 요청</button>
        </div>
      </div>
    </article>
  `;
}

function renderRework() {
  const all = state.data?.slides.filter((slide) => slide.rework) || [];
  const visible = reworkSlides();
  const counts = ["pending", "approved", "rejected", "queued", "internal_rejected"]
    .map((status) => [status, all.filter((slide) => effectiveReworkStatus(slide) === status).length]);
  byId("rework-summary").innerHTML = counts
    .map(([status, count]) => `<span><small>${escapeHtml(reworkReviewLabels[status])}</small><strong>${count}</strong></span>`)
    .join("");
  byId("rework-grid").innerHTML = visible.length
    ? visible.map(reworkCard).join("")
    : '<p class="notice">현재 조건에 맞는 재작업 슬라이드가 없습니다.</p>';
  bindReworkCards();
}

function bindReworkCards() {
  document.querySelectorAll(".rework-card").forEach((card) => {
    const slideNumber = Number(card.dataset.slide);
    const slide = state.data.slides.find((item) => item.slide === slideNumber);
    card.querySelectorAll(".comparison-image.is-zoomable").forEach((button) => {
      button.addEventListener("click", () => openLightbox(slideNumber, button, button.dataset.kind, "rework"));
    });
    card.querySelectorAll("[data-review]").forEach((button) => {
      button.addEventListener("click", async () => {
        const version = currentReworkVersion(slide);
        if (!version) return toast("생성본이 아직 없습니다.");
        const status = button.dataset.review;
        const reasonInput = card.querySelector(".rework-reason");
        const reason = reasonInput.value.trim();
        if (status === "rejected" && !reason) {
          reasonInput.focus();
          toast("반려 사유를 입력하세요.");
          return;
        }
        try {
          const result = await api(`/api/rework/slides/${slideNumber}/versions/${version.version}/review`, {
            method: "POST",
            body: JSON.stringify({ status, reason }),
          });
          slide.rework = result.slide;
          renderRework();
          toast(status === "approved" ? `${slideNumber}번 확정` : `${slideNumber}번 반려 · 재작업 대기열 등록`);
        } catch (error) {
          toast(error.message);
        }
      });
    });
  });
}

function renderPalette() {
  const candidates = state.data.palette?.candidates || [];
  byId("palette-grid").innerHTML = candidates.map((candidate) => `
    <button class="palette-swatch" data-hex="${candidate.hex}">
      <span class="palette-color" style="background:${candidate.hex}"></span>
      <span class="palette-copy"><strong>${candidate.hex}</strong><span>${(candidate.share * 100).toFixed(1)}%</span></span>
    </button>
  `).join("");
  document.querySelectorAll(".palette-swatch").forEach((swatch) => {
    swatch.addEventListener("click", () => {
      byId("primary-color").value = swatch.dataset.hex;
      document.querySelectorAll(".palette-swatch").forEach((item) => item.classList.toggle("is-selected", item === swatch));
      renderStylePreview();
    });
  });

  if (state.data.style) {
    byId("primary-color").value = state.data.style.primary;
    byId("background-color").value = state.data.style.background;
    byId("text-color").value = state.data.style.text;
    byId("muted-color").value = state.data.style.muted;
  } else {
    const candidate = normalizedRubric()?.primaryCandidate;
    if (/^#[0-9A-Fa-f]{6}$/.test(candidate || "")) byId("primary-color").value = candidate;
  }
  renderStylePreview();
}

function renderStylePreview() {
  const primary = byId("primary-color").value;
  const background = byId("background-color").value;
  const text = byId("text-color").value;
  const muted = byId("muted-color").value;
  const preview = byId("style-preview");
  preview.style.background = `linear-gradient(110deg, ${background} 0 68%, ${primary} 68%)`;
  preview.style.color = text;
  preview.querySelector("small").style.color = muted;
}

async function saveStyle(confirmed) {
  const style = await api("/api/style", {
    method: "POST",
    body: JSON.stringify({
      primary: byId("primary-color").value,
      background: byId("background-color").value,
      text: byId("text-color").value,
      muted: byId("muted-color").value,
      confirmed,
    }),
  });
  state.data.style = style;
  renderCriteriaBoard();
  toast(confirmed ? "프라이머리 컬러 확정" : "컬러 임시 저장");
}

function bindPageControls() {
  document.querySelectorAll(".mode-tab").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll(".mode-tab").forEach((item) => item.classList.toggle("is-active", item === button));
      document.querySelectorAll(".panel").forEach((panel) => panel.classList.remove("is-active"));
      byId(`${button.dataset.tab}-panel`).classList.add("is-active");
      if (button.dataset.tab === "rework") renderRework();
    });
  });
  document.querySelectorAll(".filter-chip").forEach((button) => {
    button.addEventListener("click", () => {
      state.filter = button.dataset.filter;
      state.page = 1;
      document.querySelectorAll(".filter-chip").forEach((item) => item.classList.toggle("is-active", item === button));
      renderSlides();
    });
  });
  byId("slide-search").addEventListener("input", (event) => {
    state.search = event.target.value.replace(/\D/g, "");
    event.target.value = state.search;
    state.page = 1;
    renderSlides();
  });
  byId("quick-triage-start").addEventListener("click", (event) => {
    const visible = filteredSlides();
    const startIndex = Math.max(0, (state.page - 1) * state.pageSize);
    const firstSlide = visible[startIndex] || canonicalSlides()[0];
    if (!firstSlide) return toast("검수할 슬라이드가 없습니다.");
    openLightbox(firstSlide.slide, event.currentTarget, "before", "triage");
  });
  byId("add-rework-criterion").addEventListener("click", addReworkCriterion);
  byId("save-rework-criteria").addEventListener("click", saveReworkCriteria);
  byId("rework-criteria-editor-list").addEventListener("input", (event) => {
    const field = event.target.closest("[data-criterion-field]");
    const row = event.target.closest("[data-rework-criterion-index]");
    if (!field || !row) return;
    const criterion = state.reworkCriteriaDraft[Number(row.dataset.reworkCriterionIndex)];
    if (!criterion) return;
    criterion[field.dataset.criterionField] = field.value;
    state.reworkCriteriaDirty = true;
    renderReworkCriteriaEditorState();
  });
  byId("rework-criteria-editor-list").addEventListener("click", (event) => {
    const button = event.target.closest('[data-criterion-action="delete"]');
    const row = event.target.closest("[data-rework-criterion-index]");
    if (!button || !row) return;
    state.reworkCriteriaDraft.splice(Number(row.dataset.reworkCriterionIndex), 1);
    state.reworkCriteriaDirty = true;
    renderReworkCriteriaEditor(normalizedRubric());
  });
  document.querySelectorAll(".rework-filter-chip").forEach((button) => {
    button.addEventListener("click", () => {
      state.reworkFilter = button.dataset.reworkFilter;
      document.querySelectorAll(".rework-filter-chip").forEach((item) => item.classList.toggle("is-active", item === button));
      renderRework();
    });
  });
  byId("previous-page").addEventListener("click", () => { state.page--; renderSlides(); window.scrollTo({ top: 250, behavior: "smooth" }); });
  byId("next-page").addEventListener("click", () => { state.page++; renderSlides(); window.scrollTo({ top: 250, behavior: "smooth" }); });
  byId("finalize-triage").addEventListener("click", async () => {
    try {
      const result = await api("/api/triage/finalize", { method: "POST", body: "{}" });
      state.data.finalizedAt = result.finalizedAt;
      toast("페이지 분류 확정");
    } catch (error) {
      toast("미검수 페이지를 먼저 분류하세요.");
    }
  });
  ["primary-color", "background-color", "text-color", "muted-color"].forEach((id) => byId(id).addEventListener("input", renderStylePreview));
  byId("save-style").addEventListener("click", () => saveStyle(false).catch((error) => toast(error.message)));
  byId("style-form").addEventListener("submit", (event) => {
    event.preventDefault();
    saveStyle(true).catch((error) => toast(error.message));
  });

  const lightbox = byId("image-lightbox");
  byId("lightbox-close").addEventListener("click", closeLightbox);
  byId("lightbox-prev").addEventListener("click", () => moveLightbox(-1));
  byId("lightbox-next").addEventListener("click", () => moveLightbox(1));
  byId("lightbox-rework-toggle").addEventListener("click", () => toggleCurrentLightboxRework());
  byId("lightbox-fit").addEventListener("click", () => setLightboxZoom("fit"));
  byId("lightbox-zoom-out").addEventListener("click", () => changeLightboxZoom(-1));
  byId("lightbox-zoom-in").addEventListener("click", () => changeLightboxZoom(1));
  byId("lightbox-image").addEventListener("dblclick", () => setLightboxZoom(state.lightbox.zoom === "fit" ? 100 : "fit"));
  lightbox.addEventListener("click", (event) => {
    if (event.target === lightbox) closeLightbox();
  });
  lightbox.addEventListener("cancel", (event) => {
    event.preventDefault();
    closeLightbox();
  });
  lightbox.addEventListener("close", () => {
    document.body.classList.remove("lightbox-open");
    state.lightbox.slideNumber = null;
    state.lightbox.order = [];
    state.lightbox.assetKind = "before";
    state.lightbox.context = "triage";
    state.lightbox.updating = false;
    if (lightboxOpener?.isConnected) lightboxOpener.focus();
    lightboxOpener = null;
  });
  document.addEventListener("keydown", (event) => {
    if (!lightbox.open) return;
    const target = event.target;
    const editable = target instanceof HTMLElement && (target.matches("input, textarea, select") || target.isContentEditable);
    if (editable) return;
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      event.stopImmediatePropagation();
      moveLightbox(-1);
      return;
    }
    if (event.key === "ArrowRight") {
      event.preventDefault();
      event.stopImmediatePropagation();
      moveLightbox(1);
      return;
    }
    if (event.code === "Space" && state.lightbox.context === "triage" && state.lightbox.assetKind === "before") {
      const onActionControl = target instanceof Element && Boolean(target.closest("button, a, [role='button']"));
      if (!onActionControl && !event.repeat) {
        event.preventDefault();
        event.stopImmediatePropagation();
        toggleCurrentLightboxRework();
        return;
      }
    }
    if (event.key === "+" || event.key === "=") {
      event.stopImmediatePropagation();
      changeLightboxZoom(1);
    }
    if (event.key === "-") {
      event.stopImmediatePropagation();
      changeLightboxZoom(-1);
    }
    if (event.key === "0") {
      event.stopImmediatePropagation();
      setLightboxZoom("fit");
    }
  });
  window.addEventListener("beforeunload", (event) => {
    if (!state.reworkCriteriaDirty) return;
    event.preventDefault();
    event.returnValue = "";
  });
}

async function start() {
  bindPageControls();
  state.data = await api("/api/bootstrap");
  await loadRubricFallback();
  renderHeader();
  renderCriteriaBoard();
  renderSlides();
  renderCheckedSlideLists();
  renderPalette();
  renderRework();
}

start().catch((error) => {
  byId("project-title").textContent = "작업을 불러오지 못했습니다";
  toast(error.message);
  console.error(error);
});
