# PPT 선택 재작업 파이프라인

최대 500장 PPT를 전부 다시 만드는 대신, 먼저 전체 슬라이드를 분류하고 사람이 선택한 페이지만 재작업하기 위한 로컬 파이프라인입니다.

## 설치·운영 구조

- 개발 PC용과 직원 PC용을 따로 만들지 않습니다. 이 저장소 하나가 양쪽 PC에서 사용하는 동일한 Codex Desktop Local Project입니다.
- 준비 PC에서 검증한 저장소 전체(`app`, `scripts`, `templates`, `jobs`)를 작업자 PC에 그대로 설치·복사하고, 작업자는 그 루트 폴더를 Codex 데스크톱 앱에서 Local Project로 엽니다.
- 작업자도 같은 Codex 규칙, `$imagegen` 흐름, 분류·검수 화면, 저장된 작업 상태를 그대로 사용합니다. 별도 직원용 앱이나 기능을 줄인 배포본은 만들지 않습니다.
- `jobs/<job-id>/검수화면_열기.cmd`는 같은 프로젝트 안의 HTML 검수 화면을 여는 편의 실행 파일일 뿐, 별도 제품이 아닙니다. 저장소 위치가 바뀌어도 상대 경로로 같은 파이프라인을 찾습니다.
- 직원 PC 설치 순서는 [INSTALL-WINDOWS.md](INSTALL-WINDOWS.md)에 정리되어 있습니다.

## 현재 구현 범위

1. PPTX 실제 발표 순서와 장수 확인
2. PNG ZIP을 압축 내 순서로 표준 슬라이드 번호에 매핑
3. 원본 PNG와 저용량 썸네일 생성
4. PPTX 텍스트·명시 폰트 크기·개체 수 인벤토리
5. 공유 대화에서 확정된 분류 기준과 재작업 결과물 계약을 작업별 `02_triage/criteria.json`으로 고정
6. 재작업 후보 신호·전체 시각 판정·컬러 후보 생성
7. 자동 판정과 적용 기준이 보이는 브라우저에서 `유지 / 재작업 / 판단 필요`를 작업자가 수정·확정
8. 반려 또는 분류 메모 저장
9. 프라이머리 컬러 선택·확정

## 작업별 상태

원본 자료, 실제 슬라이드 판정, imagegen 생성본과 검수 상태는 `jobs/<job-id>`에만 저장되며 GitHub에는 올라가지 않습니다.

HTML은 처음 열 때부터 해당 작업의 실제 판정 상태를 표시합니다. 작업자가 상태나 사유를 바꾸면 출처가 `직원 수정`으로 전환되고, 인벤토리나 자동 판정을 다시 실행해도 그 수정은 보존됩니다.
슬라이드 이미지를 클릭하면 1920×1080 원본 크게 보기가 열립니다. 화면 맞춤·50~200% 확대, 스크롤, 이전/다음 이동, `Esc` 닫기를 지원합니다.
검토 화면 상단에는 `분류 기준`과 `재작업 결과물 계약`이 분리되어 표시되고, 재작업 카드에는 실제로 걸린 기준이 표시됩니다. 40pt, 원문 보존, 색상 고정 같은 제작 조건 때문에 읽을 수 있는 단순 슬라이드까지 재작업으로 늘리지는 않습니다.

## 기존 작업 접수

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ingest-job.ps1 `
  -JobRoot .\jobs\sample-project `
  -DisplayName "고객명 프로젝트명"
```

## 새 작업 생성

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\new-job.ps1 `
  -SourcePptx "C:\Users\사용자\Downloads\deck.pptx" `
  -SourcePngZip "C:\Users\사용자\Downloads\deck-png.zip" `
  -JobsRoot ".\jobs" `
  -JobId "client-project" `
  -DisplayName "고객명 프로젝트명"
```

## 검수 화면 실행

작업자는 Codex 데스크톱 앱에서 동일한 프로젝트를 열어 작업하며, 필요할 때 작업 폴더의 `검수화면_열기.cmd`를 더블클릭해 같은 프로젝트의 검수 화면을 열 수 있습니다. 브라우저가 자동으로 열리고, 검수를 마치면 함께 열린 안내 창에서 Enter를 눌러 서버를 종료합니다.

CLI에서 직접 실행할 때만 아래 명령을 사용합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-review.ps1 `
  -JobRoot .\jobs\sample-project
```

기본 주소는 `http://127.0.0.1:4173`입니다. 서버가 실행 중인 터미널을 닫거나 `Ctrl+C`를 누르면 종료됩니다.

## 이번 단계의 완료 경계

현재 재작업 제작 방식은 `원본 PNG를 edit target으로 한 built-in imagegen 호출 → 생성본 버전 저장 → HTML Before/After 검수 → 승인 또는 반려 사유 기반 새 버전 생성`입니다. PPTX 편집은 이미지 재작업을 대신하지 않으며, 승인된 생성 이미지를 최종 복사본에 조립하는 마지막 단계에서만 수행합니다.
