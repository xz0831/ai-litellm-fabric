# fabric Dashboard — 유지보수 가이드

Last updated: 2026-06-20
Branch: `feat/fabric-dash` (PR #2)
Status: 구현 완료 · CI green · 23개 테스트 통과

이 문서는 `fabric` 대시보드 서브시스템의 **유지보수자용 정본 가이드**다. "무엇이고, 어떻게 띄우며, 어떻게 계층이 나뉘고, 각 모듈이 무엇을 책임지며, 안전 모델의 load-bearing 불변식이 무엇이고, 어떻게 개발·실행·테스트하는가"를 다룬다. 설계 *이유*(반론 포함)는 `DESIGN_RATIONALE.md`가, 전체 운영 절차는 `AI_AGENT_LITELLM_ARCHITECTURE.md`가, 원래 설계 의도는 `docs/superpowers/specs/2026-06-18-fabric-dashboard-tui-design.md`(=PLAN)가 맡는다. 이 문서는 **실제로 빌드된 것**을 코드에 근거해 기술하며, PLAN에서 갈라지거나 확장된 지점은 표시한다.

근거의 인식론적 지위 표기는 다른 문서와 동일하다: **[기록]** = 커밋/주석/플랜에 명시 · **[실증]** = 테스트로 검증 · **[재구성]** = 코드에서 강하게 복원 가능하나 기록 없음 · **[근거 불명]** = 정직하게 모름.

---

## 1. 무엇인가 (What it is)

`fabric`은 기존 `ai-litellm` CLI 위에 얹은 **얇은 read-then-act 관제층 TUI**다. Textual(Python) 기반이며, 새 백엔드 로직을 한 줄도 추가하지 않는다. 상태는 전부 기존 CLI의 `--json` 출력으로 *읽고*, 액션은 전부 기존 CLI를 *호출*한다.

- **본다(SEE):** 좌측 concept Tree(Proxy / Harnesses / Models·Routes / Runtimes / Budget·Policy / Keys)와 상단 status header, 우측 패널(텍스트 또는 DataTable), 하단 결과 로그.
- **한다(DO):** start/doctor(무료·즉시 실행), sync/restart/stop(중단성 → 확인 모달), harness launch(과금성 → 확인 모달 후 터미널 hand-off).
- 기본은 **read-only**. mutating 액션은 확인 모달 뒤에 게이트된다: 중단성(RESTART) 및 파괴적(DESTRUCTIVE) 등급은 Cancel-우선(Cancel-포커스), 과금성(BILLABLE) launch는 Confirm-우선(Confirm-포커스).

진입점은 두 가지이며 동일한 코드로 수렴한다:

```
fabric                # bin/fabric 셔임
ai-litellm dash       # lib.zsh dispatch (셔임이 결국 이걸 exec)
```

`config/ai-litellm/fabric_dash/__main__.py`의 `USAGE`는 `fabric --help`만 문서화하므로, `fabric` 단독 실행이 사실상 정본 진입점이다. [기록]

---

## 2. 띄우는 법 (Launch)

설치본 기준:

```
fabric                # 대시보드
fabric --help         # 사용법만 출력하고 종료 (Textual 불필요)
ai-litellm dash       # 동일. dash 뒤 인자는 fabric_dash로 그대로 전달
```

부팅 경로(`bin/fabric`, lib.zsh `dash)` 케이스에서 검증):

1. `bin/fabric`(zsh 셔임)이 nvm을 부트스트랩(launchd/cron 같은 PATH-최소 환경에서 node 확보용)하고 `AI_LITELLM_FABRIC_HOME`을 해석한 뒤 `exec "$AI_LITELLM_FABRIC_HOME/bin/ai-litellm" dash "$@"` 한다. [기록]
2. lib.zsh의 `dash)` 케이스(라인 ~6176)가 `"$AI_LITELLM_STATE_HOME/dash-venv/bin/python" -m fabric_dash "$@"`를 실행한다. `PYTHONPATH`에 `$AI_LITELLM_CONFIG_HOME/ai-litellm`을 prepend해 `fabric_dash` 패키지를 import 가능하게 한다. [기록]
   - venv가 없으면 actionable loud-fail: venv 생성 + `pip install textual` 안내를 stderr로 찍고 `return 1`. [기록]
   - **주의(주석에 명시):** main dispatcher가 이미 그룹 단어를 shift했으므로 `dash)` 안에서 다시 shift하면 안 된다. 한 번 그렇게 해서 `--help`가 먹히고 TUI가 떠버린 회귀가 있었다. [기록]

Textual이 venv에 없을 때: `__main__.main()`이 `ModuleNotFoundError`를 잡아 `fabric requires Textual: python3 -m pip install textual`를 stderr로 출력하고 `return 1`. [기록]

---

## 3. 계층 구조 (Layered architecture)

```
        Textual TUI (Python; fabric_dash/)        ← 이 서브시스템이 새로 만든 유일한 코드
              │  FabricClient = subprocess 호출 + JSON 파싱 (직접 로직 없음)
              ▼
   ai-litellm <group> <verb> --json               ← additive·비파괴 출력 포매터 (읽기 명령에만)
   ai-litellm <group> <verb>                       ← 액션은 기존 명령을 그대로 호출 (ActionRunner)
              │
              ▼
        기존 lib.zsh  (로직 불변)
              ▼
   LiteLLM 프록시 / state 파일 / Keychain / runtimes
```

**제1원칙: TUI는 상태를 재계산하지 않는다.** 모든 상태는 `--json` 출력으로 읽고, 모든 액션은 기존 CLI를 호출한다. 이렇게 해야 백엔드가 단일 진실 원천으로 남고, TUI가 lib.zsh 내부에 결합되지 않는다. [기록 — spec §4]

`--json` 표면은 별도 서브시스템(이 PR에서 함께 추가됨)이며, 그 상세는 아키텍처 가이드와 `DESIGN_RATIONALE.md`에 있다. 여기서는 **fabric이 소비하는** 명령만 정리한다(`FabricClient`에서 직접 확인):

| FabricClient 메서드 | 호출하는 명령 | 반환 |
|---|---|---|
| `proxy_status()` | `proxy status --json` | dict |
| `key_status()` | `key status --json` | dict |
| `model_list()` | `model list --json` | list |
| `model_limits([model])` | `model limits [model] --json` | list |
| `route_list()` | `route list --json` | list |
| `runtime_status()` | `runtime status --json` | list |
| `reasoning_matrix()` | `reasoning matrix --json` | list |
| `context_matrix()` | `context matrix --json` | list |
| `harness_list()` | `harness list --json` | list |

> **PLAN과의 차이/주의:** `client.py`는 위 9개 read 메서드를 모두 제공하지만, `app.py`가 실제로 패널에 *와이어*하는 것은 일부다. "Budget & Policy" 패널은 `reasoning_matrix()`를 그린다(app.py `_panel_rows`, 라인 ~196) — `context_matrix()`와 `route_list()`는 client에 존재하나 현재 어떤 패널도 호출하지 않는다(향후 확장 여지). 이 불일치는 의도된 것이 아니라 "client가 표면을 넓게 덮고 app은 그중 일부만 노출"하는 상태로 보는 것이 정확하다. [재구성]

`--json` 계약의 핵심 보증(소비 측이 의존하는 부분):

- **출력 포매터 전용:** 상태를 재계산하지 않으며, 기본 텍스트 출력은 바이트 동일하게 유지. [기록]
- camelCase 키, valid JSON, exit 0. 읽을 수 없으면 `{}` / `[]`를 반환. [기록]
- `FabricClient`는 여기에 한 겹 더 방어한다: rc≠0이거나 JSON 파싱 실패면 빈 컨테이너 반환 → TUI는 traceback 대신 "empty"를 보여준다. [실증 — `test_client.py`]

---

## 4. 모듈 지도 (`fabric_dash/`)

각 파일은 단일 책임을 가진다. 경로는 `config/ai-litellm/fabric_dash/`.

### `client.py` — read-only 상태 게이트웨이
`FabricClient`. 주입 가능한 `runner: Callable[[list], (rc, stdout)]`(기본은 `subprocess.run`, timeout 15s)를 통해 `ai-litellm … --json`만 호출한다. mutating/billable 명령은 **호출하지 않는다**(메서드 자체가 없음). 모든 메서드는 실패 시 빈 dict/list를 반환(`_obj`/`_arr`가 타입까지 검사). runner 주입 덕에 테스트는 실제 바이너리 없이 가짜 출력으로 구동된다. [실증 — `test_client.py`]

### `safety.py` — 순수 위험 분류
부수효과 없는 순수 모듈. 두 가지를 제공한다:
- `classify(argv) -> SAFE|RESTART|BILLABLE|DESTRUCTIVE`: `uninstall`→DESTRUCTIVE, `probe`/`route check`→BILLABLE, `sync`/`proxy restart`/`proxy stop`→RESTART, 그 외 SAFE.
- `ACTIONS`: 액션 바 레지스트리(`Action` namedtuple: key, label, argv, grade, needs_confirm, consequence).

**keybinding 규약(load-bearing safety affordance):** 소문자 = safe/read-only(`s` start, `d` doctor), 대문자 = mutating/disruptive(`S` sync, `R` restart, `X` stop). 그래서 Shift 오타는 항상 *게이트된*(확인 모달) 쪽으로 움직이지, disruptive 액션을 조용히 발사하지 않는다. 과거 레이아웃은 `s`=sync(위험)였고 case가 risk에 매핑되지 않았다 — 그 회귀를 막는 규약이다. [기록 — safety.py 주석][실증 — `test_keybinding_case_maps_to_risk`]

### `actions.py` — 줄 단위 결과 실행기
`ActionRunner`. 주입 가능한 `spawn`(기본 `subprocess.run`, timeout 600s)로 `ai-litellm <argv>`를 실행하고 — 명령이 완료된 뒤 — stdout+stderr를 줄 단위로 `on_line` 콜백에 전달한다(라이브 스트리밍이 아닌 완료 후 순차 전달). **스스로 분류하지 않는다** — 호출자가 `safety.classify` + `ConfirmModal`로 먼저 게이트해야 한다(파일 docstring에 명시). [기록]

### `modal.py` — 확인 게이트
`ConfirmModal(ModalScreen)`. consequence 문구·title·grade를 받는다. `_GUARDED = {"restart", "destructive"}` grade는 **Cancel-우선**(버튼 순서·포커스 모두 Cancel) 이라, 반사적 Enter가 disruptive 액션을 발사할 수 없다. 전역 enter→confirm 바인딩이 없고, Enter는 *포커스된* 버튼만 활성화한다. `escape`=cancel. destructive 전용 빨강 스타일은 제거됨(현재 surface된 destructive 액션이 없어서) — 단 grade는 guard set에 남아, 미래에 destructive 액션이 wire되면 자동으로 Cancel-우선이 된다. [실증 — `test_restart_modal_defaults_focus_to_cancel`, `test_destructive_modal_renders_and_is_cancel_first`]

### `footer.py` — color-graded 액션 바
`StatusFooter(Static)` + `FooterItem` namedtuple. 스톡 Textual Footer는 모든 키를 단색으로 그려 restart/billable이 read-only refresh와 시각적으로 구분되지 않는다. 이 footer는 status 색 시스템(green=safe / amber=disruptive / red=billable·destructive)을 재사용하고, read-only 그룹과 mutating 그룹을 `│` divider로 분리한다. plain `Static`이라 렌더된 텍스트가 그대로 테스트 가능. [실증 — `test_footer_color_grades_keys_by_safety`]

### `app.py` — TUI 본체 (`FabricApp`)
- **레이아웃(`compose`):** Header → status `Static` → Horizontal(concept Tree + content `Static` + 공유 `DataTable`) → results `RichLog` → `StatusFooter`. 넓은 표 뷰(harnesses/models/runtimes/budget)는 **하나의 재사용 DataTable**을 공유한다(컬럼 자동 폭·스크롤).
- **status header(`refresh_status`):** proxy health 점(green o / red x / yellow ?), config currency 배지(stale→`STALE -> sync`), launch 타깃. 타깃 미선택 시 `[open Harnesses]`로 신규 사용자를 유도(Rich 마크업 파싱을 피하려 `\[`로 이스케이프).
- **패널(`show_panel`):** proxy/keys는 색칠된 텍스트, 나머지는 DataTable. 빈 데이터는 패널별 빈-상태 문구.
- **셀 색칠(`_cell`):** `valid`/`cliInstalled` 같은 readiness 컬럼은 False→빨강 ✗ / True→초록 ✓. key `source`가 missing/unset/none/""이면 빨강. billable launch 전에 위험을 *색으로* 신호하는 것이 load-bearing. [실증 — `test_invalid_harness_cells_render_red_check_marks`, `test_missing_key_renders_red`]
- **launch 타깃:** Harnesses 패널을 열면 첫 행이 타깃을 시드하고, 행 하이라이트가 타깃을 갱신한다. DataTable 행 키는 `"<label>#<i>"`(인덱스 suffix) — model limits/list 행은 `name`이 없어 `name`만으로 키하면 ""가 충돌해 Textual `DuplicateKey`로 앱이 무너졌던 회귀를 막는다. 하이라이트 핸들러가 `rsplit("#",1)`로 bare name을 복원. [실증 — `test_models_panel_with_multiple_nameless_rows_does_not_crash`, `test_harness_row_key_with_index_suffix_resolves_to_name`]
- **auto-refresh:** `set_interval(4.0, self.refresh_status)` — **read-only인 status만** 갱신. mutating 액션은 절대 자동 발사되지 않는다. [기록 — 주석 "safe/read-only auto-refresh only"]
- **액션 실행(`_run_action`, `@work`):** needs_confirm이면 `push_screen_wait(ConfirmModal(...))`로 먼저 게이트, 취소면 로그만 남기고 return. 통과해야 `ActionRunner.run`이 돈다.
- **launch hand-off(`action_launch`, `@work`):** 타깃 없으면 Harnesses 패널로 데려가고 테이블에 포커스(발사하지 않음). 있으면 billable 확인 모달 후 `self.exit(result=("launch", [harness]))`.

### `__main__.py` — 진입 + hand-off
`--help`/`-h` 단축. Textual import 실패를 잡아 안내. `FabricApp().run()`이 `("launch", [harness])` 튜플을 반환하면 `os.execvp("ai-litellm", ["ai-litellm", "harness", "launch", harness])`로 **현재 프로세스를 대체**해 터미널을 하니스에 넘긴다. [기록]

### `app.tcss` — status 색 시스템
`.ok/.warn/.bad → $success/$warning/$error`. 레이아웃(상단 status dock, 좌측 Tree 폭 28, 하단 footer/results dock)과 ConfirmModal 스타일(amber `round $warning` 보더, 뒤 배경 60% dim)을 정의. 색은 app.py에서 인라인 Rich 태그로도 적용되며, 이 클래스들은 위젯이 같은 팔레트에 opt-in하게 한다. [기록 — 파일 상단 주석]

---

## 5. venv 격리 (왜·어디·언제 제거)

- **왜:** macOS Homebrew Python은 외부 관리(PEP 668)라 시스템/유저 site에 pip가 막힌다. litellm을 pipx 격리 venv로 운영하는 것과 같은 패턴으로, `textual`을 **패키지 소유 venv**에 격리해 시스템 Python을 오염시키지 않는다. dependency-light ethos("쓸 때만 필요한 선택 의존성")를 유지한다. [기록 — spec §3]
- **어디:** `$AI_LITELLM_STATE_HOME/dash-venv` = `~/.local/share/ai-litellm-fabric/state/dash-venv`. `dash)` dispatch가 이 venv의 python을 쓴다.
- **언제 만드나:** `scripts/install.zsh`의 `ensure_dash_venv()`가 venv 생성 + `pip install textual`. 모두 non-fatal 가드(install.zsh는 `set -e`이므로 offline pip 실패가 전체 install을 중단시키면 안 됨). `python3` 부재 시 graceful skip.
- **escape hatch:** `AI_LITELLM_SKIP_DASH_VENV`가 set이면 venv 빌드를 건너뛴다(network·느림 회피). `check.zsh`가 이걸 set해 throwaway HOME 설치를 빠르고 offline-safe하게 유지한다. [기록]
- **언제 제거되나:** state/ 하위라 `ai-litellm uninstall`(→ `scripts/uninstall.zsh`의 `rm -rf "$prefix"`)이 패키지 디렉터리를 통째로 지울 때 venv도 함께 사라진다. 별도 정리 로직 불필요. [재구성 — uninstall이 prefix 전체를 rm하고 venv가 그 하위임을 코드에서 확인]

---

## 6. 안전 모델 (Safety model)

분류 → 게이트 → 실행의 3단계. 등급은 4종이지만 **현재 surface된 액션은 SAFE/RESTART/BILLABLE 3종뿐**(DESTRUCTIVE는 정의·테스트만 존재, 액션 바에 없음).

| 등급 | 의미 | surface된 액션 | 게이트 |
|---|---|---|---|
| SAFE | read-only/무해 | `s` start, `d` doctor | 없음(즉시 실행) |
| RESTART | 활성 세션 중단 | `S` sync, `R` restart, `X` stop | Cancel-우선 확인 모달 |
| BILLABLE | 과금 provider 요청 | `l` launch (probe류 분류만) | 확인 모달 (Confirm-포커스) |
| DESTRUCTIVE | 영구 변경 | (없음) | (정의만; wire되면 Cancel-우선) |

**load-bearing 불변식: needs_confirm 액션은 확인 없이는 절대 runner에 닿지 않는다.** 구현은 `_run_action`/`action_launch`에서 `push_screen_wait`가 `True`를 돌려줄 때만 `ActionRunner.run`/`self.exit`이 실행되는 구조. 보강 방어선:
- **Cancel-우선 모달:** 반사적 Enter가 default 버튼(=Cancel)을 누르므로 disruptive 액션이 안 나간다. [실증 — `test_restart_action_blocked_until_confirm`: S→모달 → (아무것도 안 돔) → Enter(=Cancel) → 여전히 안 돔 → Tab→Enter(=Confirm) → 그제야 `sync` 실행]
- **keybinding case→risk 매핑:** Shift 오타가 항상 게이트된 쪽으로 향함(§4 safety.py).
- **read-only auto-refresh:** 주기 타이머는 status만 갱신, mutating 절대 자동 발사 안 함.
- **launch hand-off:** `os.execvp`로 프로세스를 대체해 터미널을 하니스에 깔끔히 넘김(TUI가 자식으로 남지 않음). [실증 — `test_launch_exits_with_handoff`: 확인 후 `return_value == ("launch", ["claude"])`]
- **선택 없는 launch는 발사 금지:** 타깃 미선택 시 모달도 exit도 없이 안내만. [실증 — `test_launch_without_selection_does_not_default`]

이 불변식이 깨지면(예: confirm을 우회하는 코드 경로 추가) `test_actions_app.py`의 위 테스트들이 빨개진다.

---

## 7. 테스트

총 **23개** 테스트, 4개 파일. 패키지 소유 venv의 pytest로 구동(`textual`·`pytest`·`pytest-asyncio` 필요).

| 파일 | 커버 |
|---|---|
| `tests/test_client.py` | JSON 파싱, 실패 시 빈 컨테이너 |
| `tests/test_safety.py` | classify 4등급, ACTIONS 레지스트리, case→risk 규약 |
| `tests/test_actions_app.py` | ActionRunner 줄 단위 전달, confirm 게이트, Cancel-우선(RESTART/DESTRUCTIVE), safe 무모달 실행, launch hand-off(Confirm-포커스), destructive 모달 |
| `tests/test_app.py` | 부팅·헤더, harness 타깃 시딩, DataTable 렌더(nameless 행 충돌 회귀), 셀/키/proxy 색칠, footer 색 등급, 신규-사용자 힌트 |

UI 테스트는 Textual `app.run_test()` + `pilot`으로 실제 키 입력을 구동하며, 주입된 가짜 runner/spawn으로 실제 바이너리 없이 돈다.

**스냅샷-렌더 리뷰 루프(ship-quality 경화):** 외부 UX/TUI-design 리뷰어가 실제 렌더 스냅샷을 보고 채점(최종 90)하는 반복으로 다듬어졌다. 위 테스트 중 다수가 "raw 마크업이 아니라 *렌더된 가시 텍스트*"를 단언하는 이유가 이것이다 — 예: `test_status_bar_points_newcomer_to_harnesses_when_unselected`는 `[open Harnesses]`가 마크업 태그로 파싱되어 조용히 사라지는 false-pass를 막으려 `from_markup`으로 렌더한다. [기록 — 테스트 주석][근거 불명 — "score 90"의 1차 산출물/리뷰 로그는 이 리포에 커밋되어 있지 않아 코드만으로는 재구성 불가]

**CI:** `scripts/check.zsh`가 (1) dash venv+textual이 있으면 `fabric_dash --help`를 모듈로 구동(없으면 graceful skip), (2) venv에 textual+pytest가 있으면 `fabric_dash/tests/`를 pytest로 실행. 별도 CI job `dash-tests`가 textual을 provision하고 테스트를 돌려, 대시보드 회귀가 조용히 CI를 통과하지 못하게 한다. [기록 — check.zsh 라인 ~76·627; PLAN 기록]

---

## 8. 개발·실행·테스트 (유지보수자용)

`fabric_dash`는 패키지 소유 venv에서 돈다. 정확한 명령:

```sh
# venv 경로
VENV="$HOME/.local/share/ai-litellm-fabric/state/dash-venv"

# 1) venv 없으면 생성 + 의존성
python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install textual pytest pytest-asyncio

# 2) 테스트 실행 (config/ai-litellm 에서; PYTHONPATH가 곧 cwd)
cd /Users/xz0831/ai-litellm-fabric/config/ai-litellm
"$VENV/bin/python" -m pytest fabric_dash/tests/ -q

# 3) 모듈 직접 실행 (리포 소스로)
cd /Users/xz0831/ai-litellm-fabric/config/ai-litellm
PYTHONPATH=. "$VENV/bin/python" -m fabric_dash --help
PYTHONPATH=. "$VENV/bin/python" -m fabric_dash          # 실제 TUI (proxy 살아있어야 의미)

# 4) 설치본 전체 점검
AI_LITELLM_SKIP_DASH_VENV=1 scripts/check.zsh          # 빠르게(대시보드 모듈 체크는 skip)
scripts/check.zsh                                       # venv 있으면 dash 테스트까지
```

빌드 산물 위치 주의:
- **리포 소스:** `config/ai-litellm/fabric_dash/` (편집 대상)
- **설치본:** install.zsh가 `**/*.py`(tests 제외) + `app.tcss`를 `$prefix/config/ai-litellm/fabric_dash/`로 렌더. **tests는 설치되지 않는다** — 테스트는 리포 체크아웃에서만 돈다.
- `dash)` dispatch는 `$AI_LITELLM_CONFIG_HOME/ai-litellm`을 PYTHONPATH로 쓰므로, 설치본은 거기서 `fabric_dash`를 찾는다.

새 read 패널을 추가하려면: `client.py`에 `--json` 메서드 → `app.py` `CONCEPTS`/`_panel_rows`/`_EMPTY` 와이어. 새 액션을 추가하려면: `safety.py` `ACTIONS`에 등록(case→risk 규약 지킬 것; needs_confirm이면 consequence 문구 필수) → `app.py`에 `action_do_<key>` 추가. 두 경우 모두 백엔드(lib.zsh)는 건드리지 않는다 — read는 새 `--json` 에미터를 추가할 뿐.

---

## 9. 설계 결정 (요약 — 상세·반론은 DESIGN_RATIONALE)

- **read-then-act 분리:** read(`FabricClient`)와 act(`ActionRunner`)를 별 클래스로 둔다. read는 mutating 명령을 호출할 수단이 아예 없고, act는 분류하지 않고 실행만 한다 — 게이트는 app이 강제. 책임이 섞이지 않아 "TUI가 실수로 disruptive 명령을 read 경로로 호출"하는 부류의 버그가 구조적으로 불가능. [재구성 — 두 클래스의 메서드 표면에서]
- **venv 격리:** §5. PEP 668 + dependency-light ethos. 시스템 Python 무오염, uninstall이 자동 회수. [기록]
- **스냅샷-리뷰 루프:** 단위 테스트만으로는 "사용자가 실제로 보는 화면"의 색·정렬·마크업-드롭을 못 잡는다. 렌더 스냅샷을 외부 리뷰어가 보고 채점하는 루프로 ship-quality(90)까지 경화. 그 흔적이 "가시 텍스트를 단언하는" 테스트들로 코드에 남았다. [기록 — 테스트][근거 불명 — 리뷰 산출물 미커밋]
- **HARD CONSTRAINT:** native 하니스(codex/claude)는 litellm/fabric 때문에 절대 영향받지 않는다. fabric은 read-only `--json` + 기존 CLI 호출만 하고, launch는 `os.execvp`로 자기를 대체할 뿐 native 상태를 건드리지 않는다. [기록]

---

## 10. 알려진 한계 / [근거 불명]

- `client.context_matrix()`·`route_list()`는 구현·테스트 가능하나 현재 어떤 app 패널도 호출하지 않는다(§3). 죽은 코드가 아니라 미노출 표면으로 보는 게 정확.
- "Budget & Policy" 패널은 이름과 달리 `reasoning_matrix()`를 그린다(context/budget 매트릭스가 아님). [재구성 — app.py `_panel_rows`]
- 스냅샷-리뷰의 "score 90" 및 리뷰 산출물은 이 리포에 커밋되어 있지 않다 — 코드에 남은 흔적(가시-텍스트 단언 테스트)으로만 간접 확인된다. [근거 불명]
- DESTRUCTIVE 등급은 `safety`/`modal`에 정의·테스트되어 있으나 액션 바에 wire된 destructive 액션은 없다. uninstall을 TUI에서 노출하려면 `ACTIONS`에 추가하면 자동으로 Cancel-우선 게이트가 걸린다. [실증 — `test_destructive_modal_*`]
