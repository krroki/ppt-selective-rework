import argparse
import json
import sys
from pathlib import Path
from urllib.request import Request, urlopen

from playwright.sync_api import sync_playwright


BASE_URL = ""
JOB_ROOT = Path()
OUTPUT_DIR = Path()
BROWSER_PATH = ""


def api_json(path: str, method: str = "GET", payload=None):
    data = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = Request(
        BASE_URL + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def main() -> int:
    global BASE_URL, JOB_ROOT, OUTPUT_DIR, BROWSER_PATH

    parser = argparse.ArgumentParser(description="Verify the local PPT review dashboard.")
    parser.add_argument("--url", default="http://127.0.0.1:4173")
    parser.add_argument("--job", required=True)
    parser.add_argument("--browser-executable", required=True)
    args = parser.parse_args()

    BASE_URL = args.url.rstrip("/")
    JOB_ROOT = Path(args.job).resolve()
    OUTPUT_DIR = JOB_ROOT / "05_review" / "dashboard-qa"
    BROWSER_PATH = str(Path(args.browser_executable).resolve())
    if not (JOB_ROOT / "project.json").is_file():
        raise FileNotFoundError(f"job is not ingested: {JOB_ROOT}")
    if not Path(BROWSER_PATH).is_file():
        raise FileNotFoundError(f"browser executable not found: {BROWSER_PATH}")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    original_bootstrap = api_json("/api/bootstrap")
    original_rubric = original_bootstrap["rubric"]
    original_criteria = original_rubric["reworkContract"]["criteria"]
    original_description = original_criteria[0]["description"]
    report = {
        "url": BASE_URL,
        "slides": len(original_bootstrap["slides"]),
        "criteriaBefore": len(original_criteria),
        "checks": {},
        "consoleErrors": [],
        "screenshots": [],
    }
    criteria_roundtrip_started = False

    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True, executable_path=BROWSER_PATH)
            page = browser.new_page(viewport={"width": 1600, "height": 1000}, device_scale_factor=1)
            page.on(
                "console",
                lambda message: report["consoleErrors"].append(message.text)
                if message.type == "error"
                else None,
            )
            try:
                page.goto(BASE_URL, wait_until="networkidle")
                page.wait_for_selector("#criteria-board:not([hidden])")

                rows = page.locator("#rework-criteria-editor-list .criterion-editor-row")
                assert rows.count() == 9, f"expected 9 criteria, got {rows.count()}"
                assert page.locator("#rework-criteria-state").inner_text().startswith("9개")
                report["checks"]["criteriaListed"] = 9

                criteria_shot = OUTPUT_DIR / "criteria-editor.png"
                page.locator("#criteria-board").screenshot(path=str(criteria_shot))
                report["screenshots"].append(str(criteria_shot))

                page.locator("#add-rework-criterion").click()
                assert rows.count() == 10
                added_row = rows.nth(9)
                added_row.locator('[data-criterion-field="label"]').fill("임시 QA 기준")
                added_row.locator('[data-criterion-field="description"]').fill("저장하지 않고 추가·삭제 동작만 확인")
                added_row.locator('[data-criterion-action="delete"]').click()
                assert rows.count() == 9
                report["checks"]["criteriaAddDelete"] = "pass"

                marker_description = original_description + " [QA roundtrip]"
                first_description = rows.nth(0).locator('[data-criterion-field="description"]')
                first_description.fill(marker_description)
                criteria_roundtrip_started = True
                page.locator("#save-rework-criteria").click()
                page.wait_for_function(
                    "document.querySelector('#rework-criteria-state').textContent.includes('저장됨')"
                )
                persisted = api_json("/api/bootstrap")["rubric"]["reworkContract"]["criteria"][0]["description"]
                assert persisted == marker_description

                rows.nth(0).locator('[data-criterion-field="description"]').fill(original_description)
                page.locator("#save-rework-criteria").click()
                page.wait_for_function(
                    "document.querySelector('#rework-criteria-state').textContent.includes('저장됨')"
                )
                restored = api_json("/api/bootstrap")["rubric"]["reworkContract"]["criteria"][0]["description"]
                assert restored == original_description
                criteria_roundtrip_started = False
                report["checks"]["criteriaSaveRestore"] = "pass"

                page.locator('[data-tab="rework"]').click()
                page.wait_for_selector('#rework-panel.is-active .rework-card[data-slide="13"]')
                slide_13 = page.locator('.rework-card[data-slide="13"]')
                assert "AFTER · V004" in slide_13.inner_text()
                assert slide_13.locator('img[alt="슬라이드 13 원본"]').count() == 1
                assert slide_13.locator('img[alt="슬라이드 13 imagegen 재작업본"]').count() == 1
                report["checks"]["beforeAfterSlide13"] = "V004"

                compare_shot = OUTPUT_DIR / "slide-0013-before-after.png"
                slide_13.screenshot(path=str(compare_shot))
                report["screenshots"].append(str(compare_shot))

                slide_13.locator('[data-kind="after"]').click()
                page.wait_for_selector("#image-lightbox[open]")
                assert "V004" in page.locator("#lightbox-kicker").inner_text()
                after_src = page.locator("#lightbox-image").get_attribute("src")
                assert after_src and after_src.endswith("/04_rework/slide-0013/v004.png")
                after_shot = OUTPUT_DIR / "slide-0013-after-fullscreen.png"
                page.screenshot(path=str(after_shot))
                report["screenshots"].append(str(after_shot))
                page.locator("#lightbox-close").click()

                page.locator('[data-tab="triage"]').click()
                page.locator("#slide-search").fill("13")
                page.wait_for_selector('.slide-card[data-slide="13"]')
                page.locator('.slide-card[data-slide="13"] .slide-image-wrap').click()
                page.wait_for_selector("#image-lightbox[open]")
                assert page.locator("#lightbox-kicker").inner_text().startswith("SLIDE 013")
                assert page.locator("#lightbox-rework-toggle").is_visible()
                assert "체크됨" in page.locator("#lightbox-rework-state").inner_text()
                assert page.locator("#lightbox-checked-count").inner_text() == "36"
                page.keyboard.press("ArrowRight")
                assert page.locator("#lightbox-kicker").inner_text().startswith("SLIDE 014")
                page.keyboard.press("ArrowLeft")
                assert page.locator("#lightbox-kicker").inner_text().startswith("SLIDE 013")
                report["checks"]["fullscreenArrows"] = "13->14->13"
                report["checks"]["spaceControlVisible"] = True
                report["checks"]["checkedSlides"] = 36

                triage_shot = OUTPUT_DIR / "slide-0013-triage-fullscreen.png"
                page.screenshot(path=str(triage_shot))
                report["screenshots"].append(str(triage_shot))
                page.locator("#lightbox-close").click()

                report["checks"]["consoleErrors"] = len(report["consoleErrors"])
            finally:
                browser.close()
    finally:
        if criteria_roundtrip_started:
            api_json("/api/criteria", method="PUT", payload={"reworkCriteria": original_criteria})

    final_bootstrap = api_json("/api/bootstrap")
    final_rubric = final_bootstrap["rubric"]
    final_criteria = final_rubric["reworkContract"]["criteria"]
    assert final_criteria == original_criteria
    assert final_rubric["source"] == original_rubric["source"]
    assert final_rubric["classification"] == original_rubric["classification"]
    assert final_rubric["reworkContract"]["templateChrome"] == original_rubric["reworkContract"]["templateChrome"]
    report["criteriaAfter"] = len(final_criteria)
    report["checks"]["criteriaSiblingPreservation"] = "pass"
    report_path = OUTPUT_DIR / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"QA failed: {error}", file=sys.stderr)
        raise
