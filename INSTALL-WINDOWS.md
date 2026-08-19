# 직원 PC 설치 안내

이 프로젝트는 별도의 직원용 앱이 아닙니다. 준비 PC에서 검증한 동일한 공개 GitHub 저장소를 직원 PC에 복제하고, 그 폴더를 Codex 데스크톱 앱의 Local Project로 열어 사용합니다.

## 1. 한 번만 준비할 것

- Windows용 Codex 데스크톱 앱에 작업자 ChatGPT 계정으로 로그인
- Git 또는 GitHub Desktop 설치
- Node.js 20 이상 설치

Python과 Playwright는 개발용 대시보드 QA를 실행할 때만 필요하며, 일반 슬라이드 분류·imagegen·HTML 검수에는 필요하지 않습니다.

## 2. 공개 저장소 받기

GitHub 로그인이 없어도 아래 주소에서 `Code > Download ZIP`을 눌러 압축을 풀 수 있습니다.

```text
https://github.com/krroki/ppt-selective-rework
```

업데이트를 쉽게 받으려면 공개 저장소를 Git으로 복제합니다. 이 명령도 GitHub 로그인이 필요하지 않습니다.

```powershell
git clone https://github.com/krroki/ppt-selective-rework.git D:\dev\ppt-selective-rework
cd D:\dev\ppt-selective-rework
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-environment.ps1
```

## 3. Codex에서 동일 프로젝트 열기

Codex 데스크톱 앱에서 `Add project` 또는 폴더 선택을 눌러 방금 복제한 저장소 루트를 선택합니다. [OpenAI Codex 시작 안내](https://openai.com/codex/get-started/)처럼 Codex가 작업할 로컬 폴더 또는 Git 저장소를 선택하는 방식입니다.

첫 대화에는 아래 문장을 그대로 입력합니다.

```text
AGENTS.md와 README.md를 먼저 읽고, scripts/check-environment.ps1로 환경을 확인한 뒤 결과만 알려줘. 아직 새 작업은 시작하지 마.
```

## 4. 새 PPT 작업 시작

원본 PPTX와 PNG ZIP은 GitHub 저장소에 올리지 않습니다. 작업자 PC에 별도로 내려받은 뒤 Codex에 실제 파일 경로와 작업명을 알려줍니다.

```text
다운로드 폴더의 PPTX와 PNG ZIP으로 새 작업을 만들어줘. 작업 ID는 client-project이고 표시 이름은 고객명 프로젝트명이야. AGENTS.md의 분류, 프라이머리 컬러 승인, imagegen, Before/After 검수 규칙을 그대로 적용해.
```

Codex는 새 작업을 이 저장소의 `jobs/<job-id>` 아래에 만들고 상태를 슬라이드별로 저장해야 합니다. 작업 폴더의 `검수화면_열기.cmd`는 동일 프로젝트의 HTML 검수 화면을 여는 단축 실행 파일입니다.

## 5. 업데이트와 백업

- 파이프라인 업데이트는 GitHub Desktop의 `Fetch origin`/`Pull origin` 또는 `git pull`로 받습니다.
- `jobs/`는 원본 PPTX, 참조 이미지, 생성 이미지와 검수 상태를 포함하므로 Git에서 제외됩니다.
- 진행 중인 `jobs/<job-id>`는 별도 사내 저장소나 외장 드라이브에 폴더 단위로 백업합니다.
- 작업 중에는 `app`, `scripts`, `templates`, `AGENTS.md`를 임의로 수정하지 않습니다. 파이프라인 변경이 필요하면 준비 PC에서 수정·검증한 뒤 GitHub로 배포합니다.
