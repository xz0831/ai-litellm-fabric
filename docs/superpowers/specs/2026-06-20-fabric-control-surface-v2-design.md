# Design Spec — `fabric` v2: 진짜 control surface

Date: 2026-06-20
Status: Draft (브레인스토밍 합의안, 구현 계획 전)
Author: xz0831 + Claude (brainstorming session)
Supersedes/extends: docs/superpowers/specs/2026-06-18-fabric-dashboard-tui-design.md (v1)

---

## 0. v1 회고 (왜 v2가 필요한가)

v1 `fabric`는 **읽기 위주 대시보드 + 라이프사이클 액션 몇 개**(proxy start/stop/restart/sync, harness launch, doctor)로 출시됐다. 실사용 피드백에서 드러난 결함:

- **발견성 실패** — 액션이 하단 footer에 키로만 숨어, "여기서 뭘 할 수 있는지" 안 보인다.
- **변경 불가** — 모델 tier 매핑·reasoning effort·키 같은 **실제 값을 바꾸는 기능이 없다**(v1이 의도적으로 비목표로 미룸). 원래 의도("명령이 너무 많으니 총괄하는 UI")에 못 미침.
- **거친 디자인** — 패널 구분선·테두리 없음, Models 패널 "Sources" 컬럼이 raw 파이썬 dict를 덤프, 기본 monokai 테마.

매체(TUI)는 한계가 아니다(k9s·lazygit는 풍부한 변경 제어를 한다). v2는 **범위 + 발견성 + 완성도**를 고쳐 fabric을 "보는 대시보드"에서 "명령을 발견·실행·변경하는 control surface"로 끌어올린다.

## 1. 목적 (Goals)

1. **발견성** — 사용자가 화면을 보는 것만으로 "지금 무엇을 할 수 있는지" 안다(숨은 키 금지). + 전체 명령을 검색해 실행하는 **커맨드 팔레트**로 "외울 필요"를 제거.
2. **변경(mutating) 제어** — reasoning effort, 키, 그리고 **모델 tier/facade 매핑**까지 TUI에서 안전하게 바꾼다.
3. **완성도** — 패널 구분선/테두리, 컬럼 포맷(특히 Sources raw-dict 제거), 의도된 테마/상태색.

성공 기준: 신규 사용자가 10초 안에 "뭘 할 수 있는지" 파악하고, 자주 쓰는 mutating 명령(reasoning set·launch·sync·tier 매핑)을 CLI 없이 수행할 수 있다. 외부 UX 리뷰어가 다시 통과.

## 2. 비목적 (Non-Goals)

- **네이티브 Mac 앱 / 로컬 웹 UI로의 전환** — 매체는 TUI 유지(얇은 ethos, served surface 없음). 검토했고 기각.
- **native harness 결합** — 어떤 기능도 native codex/claude의 상태에 의존하거나 그것을 변경해선 안 된다. (codex active-카탈로그 소싱 등은 영구 배제.)
- **TUI가 config 파일을 직접 편집** — 변경 로직은 backend 명령이 소유; TUI는 호출자.

## 3. 제약 (Constraints)

- 매체 = Textual TUI (v1 패키지 `config/ai-litellm/fabric_dash/` 확장). Python은 패키지 소유 venv.
- **backend가 로직 소유, TUI는 control surface** — 모든 변경은 기존 또는 신규 `ai-litellm` 명령을 호출해 수행(TUI가 YAML/JSON을 직접 쓰지 않음). 신규 backend 명령은 doctor로 검증된다.
- 읽기는 `--json` 표면(v1). 액션은 `ai-litellm <command>` 호출(v1 ActionRunner).
- native harness 불가침 (위 §2).
- 모든 위험(restart-causing)·과금(billable) 작업은 결과를 명시하는 확인 모달을 거친다(v1 ConfirmModal 패턴; 중단성=Cancel-포커스, 과금=Confirm-포커스).

## 4. 전체 형태 (인터랙션 모델)

```
┌ fabric ─────────  ● proxy ok   ◆ config STALE→s   omlx ●        :cmd  ? help ┐
│ Concepts          ║  Models / Routes                          [선택: GLM-5.2]│
│ ▸ Proxy           ║  ┌────────────┬─────────┬────────┬──────────┐           │
│ ▸ Harnesses       ║  │ Model      │ Context │ Output │ Eff.Input │           │
│ ▸ Models/Routes ◀ ║  │ GLM-5.2    │ 1048576 │ 131072 │  917504   │           │
│ ▸ Runtimes        ║  │ DeepSeek   │ 1048576 │ 384000 │  664576   │           │
│ ▸ Budget&Policy   ║  └────────────┴─────────┴────────┴──────────┘           │
│ ▸ Keys            ║  Sources: provider/provider   (raw dict 덤프 제거)        │
│ ▸ Mappings ★NEW   ║                                                          │
├───────────────────╨──── 선택 항목 액션 (라벨로 보임) ────────────────────────┤
│  [enter] info   [e] reasoning set   [p] probe ⚠과금   [l] launch   [/] 필터   │
├──────────────────────────── 결과 로그 ──────────────────────────────────────┤
│ $ ai-litellm reasoning set GLM-5.2 high … ok                                 │
└─ : 커맨드 팔레트  ·  ? 도움말  ·  q 종료  ·  ⚠위험/과금 = 확인 모달 ──────────┘
```

세 축:
- **커맨드 팔레트(`:` 또는 Ctrl-P)** — 전체 `ai-litellm` 명령 레지스트리를 fuzzy 검색 → 실행. 인자가 필요하면 generic 인자 폼(명령 usage를 힌트로). 위험/과금 명령은 확인 게이트.
- **맥락 액션 바** — 현재 패널·선택 항목의 가능한 동작을 **라벨로 항상 표시**(예: Models에서 모델 선택 시 [reasoning set] [probe] [info] [limits]).
- **Mappings 패널(신규)** — tier/facade ↔ 모델 매핑을 보고 편집.

## 5. 컴포넌트

1. **CommandPalette** (모달 overlay) — 명령 레지스트리(그룹·verb·인자·safety grade·mutating 여부 메타데이터를 가진 정적 큐레이션 목록, fabric_dash 내) 위에서 검색. Enter→인자 폼 또는 즉시 실행→ActionRunner. mutating/billable은 ConfirmModal 경유. 결과는 로그 패널로.
2. **PanelActionBar** — 패널/선택별 액션을 라벨로 렌더(숨은 footer 키 → 가시화). 키 바인딩은 유지하되 화면에 보인다.
3. **MappingsPanel + MappingEditor** — claude tier(fable/opus/sonnet/haiku, proxy+direct)와 codex facade의 현재 매핑 표시. 항목 선택 → 등록된 모델 목록에서 선택 → 확인(결과 명시) → 신규 backend 명령 호출 → 재-doctor 결과 표시.
4. **HelpOverlay(`?`)** — 전체 키맵.
5. **디자인 오버홀** — 패널 테두리/구분선(Textual border + 영역 분리), 컬럼 포맷터(Sources를 "provider/provider"처럼 정리, EffectiveInput 표현 정리), 의도된 테마/상태색 시스템(기본 monokai 탈피, 일관된 green/amber/red).

## 6. 단계 분해 (각 단계 독립 출시, 위험 낮은 순)

| Phase | 내용 | 해결 |
|---|---|---|
| **P1** 디자인+발견성 | 패널 테두리/구분선, 컬럼 포맷(Sources raw-dict 제거), 의도된 테마, 맥락 액션 바 가시화(기존 액션), `?` 도움말 | 투박·발견성 |
| **P2** 커맨드 팔레트 | `:` 전체 명령 검색·실행(인자 폼·확인 게이트)·결과 로그 | "명령 외우기 힘듦" |
| **P3** 튜닝 변경 | reasoning set/unset, key set 등 자주 쓰는 mutating을 맥락 액션·모달로(기존 CLI 명령 호출) | "실제 값 변경" |
| **P4a** claude tier 매핑 | `harness tier set` (settings.json·JSON) + Mappings 패널의 claude 편집 | "총괄(claude)" |
| **P4b** codex facade 매핑 | `model facade set` (litellm_config.yaml·앵커보존 YAML) + Mappings 패널의 codex 편집 | "총괄(codex)" |

각 Phase는 별도 implementation plan(writing-plans) 사이클을 받는다. 첫 plan = P1.

## 7. P4 안전장치 (모델 매핑 에디터)

TUI는 config를 직접 안 쓴다. 신규 backend 명령이 검증·기록·sync·doctor를 소유한다.

- **신규 backend 명령** (lib.zsh, doctor 검증):
  - `ai-litellm harness tier set <harness> <tier> <model>` — claude tier alias(proxy `aliases.<tier>` + direct `directAliases.<tier>` + displayNames) 편집. settings.json은 평문 JSON이라 비교적 단순. 검증: `<model>`이 등록된 model_name인가(proxy) / 유효 OpenRouter slug인가(direct); 로컬 모델을 direct에 넣으면 loud-warn(구조적 도달 불가).
  - `ai-litellm model facade set <facade> <backend>` — codex facade의 litellm_config model_list 라우트(`litellm_params.model` + `model_info: *anchor`) 편집. **앵커·주석 보존**이 어려움 → `refresh-capabilities --apply`가 쓰는 앵커보존 정규식 라인에디터 패턴 재사용. 검증: `<facade>`가 codex `--bundled` 카탈로그 슬러그인가; `<backend>`가 x-limits 앵커를 가지는가.
- **변경 흐름**: 사전검증(실패=loud-error, 절대 깨진 config 미기록) → 원자적 쓰기(tmp+rename) + `.bak` 스냅샷(되돌리기) → 확인 모달이 *전체 결과 명시*(파일 기록 + 프록시 재시작 + 도는 doctor) → `sync` → **재-doctor(audit model-policy·context doctor·verify_budget_consistency)가 사후 가드** → 실패 시 TUI 표시 + `.bak` 되돌리기 제안.
- 보호된 단일소스의 무결성은 **신규 명령의 사전검증 + 기존 doctor**가 지킨다. 변경 로직은 backend(테스트=check.zsh + 차등테스트)에 있고 TUI는 얇은 호출자.

## 8. 데이터 흐름

- **읽기**: FabricClient → `ai-litellm <…> --json` (v1, 변경 없음). 매핑 표시는 `harness list/info --json` + claude settings + litellm_config 읽기(읽기 전용; 신규 read helper나 기존 --json 확장).
- **쓰기**: ActionRunner → `ai-litellm <mutating command>` (기존: reasoning set/unset, key set, sync, restart…; 신규: tier set, facade set). 변경 후 영향 패널 갱신 + 결과/doctor 로그 표시.

## 9. 디자인/시각 (P1 핵심)

- Textual `border`/구분선으로 header·tree·content·action bar·log·footer 영역 분리.
- 컬럼 포맷터: dict/list 값을 사람이 읽는 형태로(예 Sources `{context,output}` → `provider/provider`); None/0 경계 표현 정리.
- 의도된 테마: 기본 monokai 대신 일관 팔레트 + 상태색(green=ok/ready, amber=stale/disruptive, red=fail/missing/billable)을 v1처럼 load-bearing하게.
- 맥락 액션 바는 항상 라벨 표시(키 + 동작명 + ⚠위험/과금 표식).

## 10. 테스트

- Pilot 테스트(venv): 팔레트(필터·실행·확인 게이트), 맥락 액션, MappingEditor(backend mock), 컬럼 포맷터(raw-dict 비노출 회귀), 디자인은 스냅샷 렌더 리뷰.
- 신규 backend 명령: check.zsh 단언(검증 loud-error, 앵커보존 쓰기, sync/doctor 통과) + 매핑 변경 후 audit/context doctor green. 실제 과금/네트워크 호출 0(mock).

## 11. 미해결 / 결정 필요 (구현 계획에서 확정)

- 커맨드 레지스트리: 정적 큐레이션 목록 vs `ai-litellm` introspection 생성 — 정적+메타데이터로 시작(확인 게이팅 위해). **→ P2 확정(§12).**
- 팔레트 인자 폼의 깊이(자유 텍스트 vs 타입별 위젯). **→ P2 확정: 자유 텍스트 + usage 힌트(§12).**
- 매핑 변경 후 `sync`를 자동으로 할지(프록시 재시작=중단) vs "config 변경됨 → sync 액션 제시"로 둘지 — 후자(확인 모달 경유)가 기본. *(P4에서 확정)*
- 테마: 직접 정의 vs Textual 내장 테마 커스터마이즈. **→ P1에서 직접 정의 테마(`_FABRIC_THEME`)로 확정·구현·머지됨(PR #2).**

## 12. P2 확정 설계 (브레인스토밍 2026-06-20 합의, P1 머지 후)

P1(디자인+발견성)은 구현·리뷰·**머지 완료**(PR #2, 머지 커밋 `55cf688`). P2 커맨드 팔레트의 확정 사항:

- **트리거:** `:` (주; mockup `:cmd`와 일치) + `ctrl+p` alias. `esc`/`:`로 닫기.
- **UX:** `CommandPalette(ModalScreen)` — 상단 `Input` + 하단 필터 `ListView`. group+verb+label을 fuzzy/부분일치 필터, ↑/↓ 이동, Enter 선택. 무인자 명령=즉시 실행; 인자 필요 명령=입력창이 "인자 모드"로 전환하고 명령 **usage를 placeholder 힌트**로 표시 → 자유텍스트 입력 → Enter. *(타입별 위젯 등 rich 가이드 변경 UX는 P3/P4.)*
- **게이트(단일 진실원천):** 실행 직전 **`safety.classify(full_argv)`로 등급 산출** → RESTART/BILLABLE/DESTRUCTIVE면 ConfirmModal(P1의 Cancel-first/과금-포커스 규칙 재사용), SAFE면 즉시. 팔레트와 맥락 액션 바가 같은 오라클을 공유해 등급 드리프트 불가(P1 하드닝의 `classify(argv)==grade` drift-guard와 동일 원리).
- **실행/결과:** 기존 `ActionRunner` + `_run_action`의 게이트·async-offload 경로 **재사용**(로직 중복 금지) → 결과는 기존 `#results` 로그 패널로(이벤트 루프 비블로킹 유지).
- **레지스트리:** `fabric_dash/commands.py`(신규)의 **정적 큐레이션 목록**. 각 항목 `{group, label, argv(베이스), takes_args, usage}` — **등급은 저장하지 않고 실행 시 classify로 도출.** 초기 구성은 **단일키가 없는 명령 위주로 발견성 극대화**(lifecycle start/stop/restart/sync, doctor, launch, 그리고 단일키 없는 mutating reasoning set/unset·key set 등). **registry-only**(자유 passthrough 없음 → 게이팅 안전 단순). 읽기 명령·패널 네비게이션은 P2 비목표(후속).
- **안전:** 인자 모드 자유텍스트는 shell이 아니라 `shlex`로 **argv 리스트 분할**(injection 없음); 빈/잘못된 인자는 실행 전 usage 재표시(깨진 호출 방지).
- **컴포넌트:** `commands.py`(레지스트리), `palette.py`(`CommandPalette` 모달), `app.py`(`:`/`ctrl+p` 바인딩 + `action_palette`).
- **테스트(Pilot, venv, 실제 호출 0):** 열기/닫기, 필터 부분일치, 무인자 즉시 실행, 인자 모드+usage 힌트, mutating은 ConfirmModal 경유(게이트 회귀), classify 등급 산출, 결과 로그 반영, shlex 분할(injection 방지).

## 13. P3 확정 설계 (브레인스토밍 2026-06-20 합의, P2 머지 후)

P2(커맨드 팔레트)는 구현·리뷰·**머지 완료**(PR #3, 머지 커밋 `7b9d0b7`). P3는 **reasoning effort 변경**으로 좁힌다(key set은 보안상 더 무거워 **P3b**로 분리: 백엔드 `key set --stdin` + ActionRunner stdin 지원 + 마스킹 입력 모달 — TUI ActionRunner는 capture_output이라 시크릿이 argv/로그/`ps`에 남지 않게 stdin 경로가 필수).

- **레벨:** **모델 + 하니스 둘 다.** Models 패널 → `model reasoning set/unset <model> <effort>`; Harnesses 패널 → `harness reasoning set/unset <name> <effort>`. 두 레벨은 UX 패턴(행 선택 → `e` → effort 셀렉터 → 적용)을 공유한다.
- **인터랙션:** 행 선택 후 `e` → 해당 선택의 **허용 effort 목록 + "unset"**을 띄우는 `EffortSelector(ModalScreen)` → 선택/취소 → 적용 → 결과 로그 + 패널 갱신. `e`는 전역 바인딩이되 `action_effort`가 패널·선택을 가드(launch 패턴). 맥락 액션 바(`_actions_for`)에 Models/Harnesses일 때 `[e] reasoning` 노출, `?` 도움말에 `e` 추가.
- **게이트(단일 오라클 유지):** `classify(... reasoning set ...)` = SAFE → **즉시 실행**(effort 선택이 곧 의도적 행동, 별도 ConfirmModal 없음). 실행은 **기존 `_run_argv` 재사용**(게이트+offload+로그) — 새 실행 경로 없음.
- **적용 의미 차이:** 모델 레벨은 litellm_config 편집 → **프록시 실행 중이면** 로그에 "config 변경됨 — `S`/sync로 적용" **안내**(자동 sync 안 함, §11). 하니스 레벨은 하니스 어댑터 편집 → 다음 launch에 반영(프록시 sync 무관, 안내 없음).
- **허용 effort 읽기:** 셀렉터가 **유효 effort만** 보이도록, `ai_litellm_model_reasoning_allowed_efforts`(모델) / 어댑터별 목록(하니스)을 **작은 additive `--json` 읽기**로 노출(`model/harness reasoning allowed <x> --json` → `["low","high",…]`; v1 `--json` 철학, 읽기 전용, doctor 무영향). **구현 시 reasoning matrix `--json`이 이미 allowed를 담는지 먼저 확인해 재사용 우선.** Models 패널이 선택 모델을 추적(`_selected_model`, 현재 harnesses만 추적 → 동일 패턴 추가).
- **컴포넌트:** `effort_modal.py`(`EffortSelector`), `app.py`(`e` 바인딩 + `action_effort` + `_selected_model` 추적 + `_actions_for`/help 확장), FabricClient에 allowed-efforts 읽기, lib.zsh에 `reasoning allowed --json`(matrix 재사용 불가 시).
- **보안/비목표:** effort는 시크릿 아님 → 특수 처리 없음. TUI가 config 직접 편집 안 함(백엔드 명령 호출). key set 일체는 P3b.
- **테스트(Pilot, venv, 실제 호출 0):** EffortSelector(허용목록+unset, 선택/취소 dismiss), Models/Harnesses의 `e`(셀렉터→선택→`_run_argv` set/unset→refresh), 모델 레벨 sync 안내(프록시 실행 시), 허용-effort 읽기(빈/실패 graceful), 선택 없을 때 `e` 가드. 신규 `--json` 읽기는 check.zsh 단언.

## 14. P3b 확정 설계 (브레인스토밍 2026-06-20 합의, P3 머지 후)

P3(reasoning) 머지 완료(PR #4 `ef54d4e`). P3b는 **키 설정(마스킹 입력)**.

**§13 정정 — 백엔드 변경 불필요:** §13은 "`key set --stdin` 신설 + ActionRunner stdin이 필요"라고 가정했으나, 코드를 추적하니 기존 `ai_litellm_key_set`이 값 인자를 생략하면 이미 `IFS= read -rs value`(lib.zsh:2613)로 **stdin에서 시크릿을 silent하게 읽고** keychain/env-file에 저장한다(2621-2633). 따라서 `printf '%s' "$SECRET" | ai-litellm key set --keychain openrouter`만으로 시크릿이 argv·로그·`ps`에 남지 않는다. **P3b는 백엔드 무변경, TUI 전용.**

- **흐름:** Keys 패널에서 `k` → `KeySetModal` (1단계: `key status`의 provider 목록(openrouter/master, 동적)에서 선택 → 2단계: 마스킹 `Input(password=True)` 시크릿 입력) → 제출 → 저장 → key status 갱신. esc 단계별 취소. `k`는 전역 바인딩이되 `action_key`가 keys 패널을 가드.
- **보안(load-bearing):** 시크릿은 메모리 → **subprocess stdin**으로만. argv = `["key","set","--keychain",<provider>]`(시크릿 없음)이라 `_run_argv`의 echo가 안전; 시크릿은 로그·argv·`ps` 어디에도 없고, 마스킹 입력이라 화면에도 안 보인다. 저장은 `--keychain`(macOS 보안 기본; 기존 키도 keychain source).
- **게이트:** `key set`은 classify상 SAFE → 마스킹 입력+제출이 곧 의도적 행위, 별도 ConfirmModal 없음. 실행은 **기존 `_run_argv` 재사용 + `stdin_input` 파라미터 추가**(단일 실행경로 유지). 백엔드가 echo하는 "Run sync" 안내는 결과 로그에 자동 표시(DRY, §13과 동일).
- **컴포넌트:** `ActionRunner.run(argv, on_line, stdin_input=None)` → `subprocess.run(input=stdin_input)`; `_run_argv(..., stdin_input=None)`(시크릿 전달하되 로그엔 안 씀); `key_modal.py` `KeySetModal`(provider 피커 → 마스킹 입력, dismiss `(provider, secret)` | None); `k` 바인딩 + `action_key` + `_actions_for`/help 확장.
- **테스트(Pilot, venv, 실제 호출 0):** stdin이 spawn에 전달되고 로그/argv엔 시크릿 없음; 모달 provider선택→마스킹→`(provider,secret)` 반환; `k`가 keys에서 모달 열고 `key set --keychain <p>`를 secret stdin으로 실행·refresh; keys 외 패널에서 `k` 가드.
- **비목표/후속:** env-file 옵션 노출, provider 추가(2개 외)는 후속. 키 삭제(unset)도 후속.

## 15. P4a 확정 설계 (브레인스토밍 2026-06-20 합의, P3b 머지 후)

P3b 머지 완료(PR #5 `c800d25`). P4a는 **claude 티어 매핑 에디터**. 한 티어(fable/opus/sonnet/haiku)는 `config/claude-litellm/settings.json`의 세 곳에 매핑된다: `aliases.<tier>`(proxy용 litellm model_name), `directAliases.<tier>`(direct용 provider model), 표시 라벨. 백엔드는 `ai_litellm_json_file "$settings" "aliases.$tier"`로 **읽기만** 한다(쓰기 명령 없음 → 신설 필요).

- **백엔드(신규, 로직 소유):** `claude alias --json`(읽기 → `[{tier, model, direct, label}]`); `claude alias set <tier> <model_name>`(쓰기 → model_name이 model_list에 존재하는지 검증, **cloud 타깃이면** litellm_params(`openrouter/X`)에서 direct(`X`)·label 도출, **local 타깃이면**(omlx, `openai/local-*`) directAlias를 그대로 두고 경고 — direct 모드엔 local 레인이 없다는 §model-remap의 의도적 분리 보존, aliases/directAliases/label을 settings.json에 원자적·일관 기록). check.zsh 단언.
- **게이트:** `claude alias set`은 classify상 **SAFE**(config 편집, 비-restart/billable) → 즉시 실행, 기존 `_run_argv` 재사용. 백엔드가 echo하는 "run sync" 안내는 결과 로그에 자동(DRY).
- **TUI:** Harnesses 패널에서 **claude 선택 → `m`** → `TierMapModal`(2-mode, KeySetModal 패턴 재사용): ① 4티어+현재 매핑 표시 → 티어 선택 → ② `model list --json`의 model_name 피커 → 선택 → dismiss `(tier, model_name)` → 앱이 `_run_argv(["...","alias","set",tier,model])` → refresh. `m`는 전역 바인딩이되 `action_map`이 harnesses+claude를 가드(비-claude/타패널이면 힌트; **codex는 P4b**). 액션바 `[m] mapping`(harnesses, SAFE), `?` 도움말 `m`.
- **컴포넌트:** lib.zsh `claude alias get/set` + dispatch + check.zsh; FabricClient 티어-매핑 읽기; `tier_modal.py` `TierMapModal`; `app.py` `m`/`action_map` + `_actions_for`/help.
- **재사용/비목표:** 피커 모달·`_run_argv`·model_list 재사용. 시크릿 없음. codex facade 매핑은 P4b(같은 harness→`m` 패턴 확장). 티어 추가/삭제는 비목표(기존 4티어 리맵만).
- **테스트(Pilot, venv, 실호출 0):** 백엔드 get/set --json + check 단언(cloud 도출, local 분리 보존); FabricClient 읽기; TierMapModal(티어 선택→모델 피커→`(tier,model)` 반환, 취소); `m`(claude에서 모달→alias set→refresh; 비-claude/타패널 가드).

## 16. P4b 확정 설계 (브레인스토밍 2026-06-20 합의, P4a 머지 후) — v2 최종 phase

P4a 머지 완료(PR #6 `929a1e1`). P4b는 **codex facade → 백엔드 매핑 에디터**. **구조가 claude와 다름:** codex facade(gpt-5.5/gpt-5.4/gpt-5.4-mini/gpt-5.2/gpt-5.3-codex)는 `claude-litellm/settings.json` 같은 하니스 alias가 아니라 **`config/litellm_config.yaml`의 model_list 엔트리**이고, 각 엔트리는 `litellm_params.model`(백엔드) + `model_info: *anchor`(caps, YAML alias)로 구성된다. (codex-litellm/settings.json의 `aliases`는 닉네임→facade 단축어일 뿐 — 비목표.) "facade 매핑"은 = 이 엔트리의 백엔드를 바꾸는 것.

- **핵심 제약(anchor 보존):** facade를 다른 백엔드로 바꾸면 `litellm_params.model`과 `model_info: *anchor`를 함께 바꿔야 한다(안 그러면 caps/예산 stale). 그리고 litellm_config을 YAML load/dump하면 anchor가 펼쳐져 깨지므로 **라인 기반 편집 필수**(기존 `ai_litellm_model_reasoning_update`가 litellm_config을 라인 편집하는 이유와 동일).
- **편집 모델(알려진 번들 = 기존 model_name 복사):** `codex facade set <facade> <source_model_name>`은 litellm_config을 라인 스캔해 **소스 model_name 엔트리의 `litellm_params:` 블록 + `model_info: *anchor` 줄을 facade 엔트리에 그대로 복사**한다(model+api(cloud는 api_key, local은 api_base+api_key:none)+anchor 일괄; caps/anchor 자동 동행). facade·소스 존재 검증, 원자적 쓰기로 anchor와 나머지 키 보존. 소스 피커 = `model list --json`의 model_name(P4a와 동일).
- **백엔드(신규):** `codex facade get --json`(→ `[{facade, model, info}]`); `codex facade set <facade> <source_model_name>`. classify상 **SAFE**(config 편집) → 즉시, 기존 `_run_argv` 재사용. 백엔드가 echo하는 "run sync"는 로그에 자동(DRY).
- **TUI:** Harnesses 패널에서 **codex 선택 → `m`** → `FacadeMapModal`(facade 피커 → source model_name 피커, P4a `TierMapModal` 2-mode 패턴 재사용) → `_run_argv(["codex","facade","set",facade,model])` → refresh. `m`/`action_map` 가드를 codex로 확장(claude→TierMapModal, codex→FacadeMapModal). 액션바 `[m] mapping`는 이미 harnesses, `?` 도움말 `m` 갱신.
- **추가(P4a 이월 TODO):** P4a의 `ai_litellm_harness_alias_set` proxy-label 도출이 LOCAL 타깃에서 부정확(`"Gemma4-12B-omlx (openai)"`) — 표시 전용. P4b에서 `model.rsplit("-",1)` 기반으로 수정(cloud+local 모두 맞음).
- **재사용/비목표:** 피커·`_run_argv`·model_list 재사용. 시크릿 없음. codex 닉네임 alias 편집·facade 추가/삭제는 비목표.
- **테스트(Pilot, venv, 실호출 0):** 백엔드 get/set --json + check 라운드트립 + **anchor 보존 검증**(set 후 `model_info: *glm52` 등 alias가 펼쳐지지 않고 유지); FabricClient 읽기; FacadeMapModal(facade→source→`(facade,model)` 반환); `m`(codex에서 모달→facade set→refresh; claude는 여전히 TierMapModal). label-fix는 cloud+local 라벨 단언.

---

*이 spec은 2026-06-20 브레인스토밍 합의안이다. phase(P1→P2→P3→P3b→P4a→P4b)는 각각 writing-plans 사이클을 받는다. P1·P2·P3·P3b·P4a 머지 완료, P4b(최종 phase) 진행 중(§16).*
