# Design Rationale — 왜 이렇게 만들었는가

Last updated: 2026-06-12

이 문서는 ai-litellm-fabric의 모든 비자명한 설계 결정에 대해 **무엇을, 왜, 어떤 대안을 기각했고, 어디서 반박할 수 있는지**를 기록한다. 운영 절차는 `AI_AGENT_LITELLM_ARCHITECTURE.md`(정본 가이드)가, 경계 계약은 `README.md`가, 강제는 `scripts/check.zsh`와 doctor가 맡는다. 이 문서의 역할은 그 셋이 답하지 않는 단 하나의 질문 — "왜?" — 이다.

읽는 법:

- 각 결정에는 근거의 인식론적 지위를 붙였다. **[기록]** = 날짜 있는 결정 로그/커밋/주석에 이유가 남아 있음. **[실증]** = mock 백엔드/실제 바이너리 실험으로 검증됨. **[재구성]** = 코드·테스트·제약에서 강하게 복원 가능하나 기록은 없음. **[근거 불명]** = 정직하게 모름(§10에 모아둠).
- 거의 모든 결정에 **반론** 단락이 있다. 이 문서를 읽고 "이렇게 하지 않아도 될 것 같은데?"라는 생각이 들었다면, 그 반론이 이미 적혀 있는지 먼저 확인하라. 적혀 있고 전제가 그대로라면 결정은 유효하다. **전제가 바뀌었다면 결정을 다시 열어야 하며, 그것이 이 문서의 존재 이유다.**
- 본 문서의 상당 부분은 2026-06-12의 전수 감사(4개 서브시스템 × 결정 추출 + 근거 불명 항목 별도 조사)로 작성되었다. 감사가 "이유 없음"으로 판정한 것은 합리화하지 않고 §10에 그대로 두었다.

---

## 1. 정체성: 무엇이고, 무엇이 아닌가

**결정: claude-litellm은 "비-Anthropic 모델로 Claude Code를 돌리는 도구"다. Anthropic 모델은 native `claude`(구독)의 영역이다.** [기록]

Root 커밋(56babc5)의 tier 구성(DeepSeek/Kimi/GLM)이 원래 의도였고, 한때 direct tier가 `~anthropic/claude-*-latest`로 향했던 것(8a507e1~3ee3e6d)은 드리프트로 판정되어 제거되었다(2026-06-12 결정 로그). 이 분업이 모든 하위 결정의 제1전제다: Anthropic 모델을 OpenRouter로 사는 것은 구독이 있는 한 돈 낭비이고, native claude는 first-party OAuth/세션/기능을 온전히 누린다.

**결정: 기본 모드는 proxy(LiteLLM), direct(OpenRouter Anthropic-호환 직결)는 `--direct` 보조 경로.** [기록]

- proxy만 로컬 oMLX 라우트에 닿는다 (direct는 Claude Code↔OpenRouter 직결 와이어라 경로상 LiteLLM이 없음 — 로컬 모델이 구조적으로 불가능).
- proxy 경로의 Anthropic→OpenAI tool-calling 변환은 eval 15/15로 검증됐다. OpenRouter의 Anthropic 호환 엔드포인트가 비-Anthropic 모델을 받는 것은 실측했지만(kimi/glm/deepseek 응답 확인) 변환 품질은 미검증이다.
- haiku tier = 완전 로컬 모델이므로 백그라운드 호출까지 무료가 되는 것은 proxy에서만 성립한다.

> **반론**: 듀얼 모드는 런치 경로를 두 배로 만든다(오버레이 2개, alias 맵 2개, env 레시피 2개). direct를 실제로 쓰지 않는다면 유지비가 삭제를 정당화하고, 쓴다면 tool-calling을 같은 15/15 기준으로 eval해야 한다. OpenRouter skin이 검증되거나 완전 로컬 운영이 표준이 되면 재론하라.

**결정: tier 간접화 — 사용자는 opus/sonnet/haiku를 고르고, 실제 모델은 `ANTHROPIC_DEFAULT_<TIER>_MODEL` env로 흐르며, tier 요청 시 `--model <tier>`를 그대로 넘긴다.** [재구성]

세 가지가 수렴한다: (1) Claude Code는 tier 이름을 네이티브로 이해한다 — 세션 내 `/model opus` 전환, 백그라운드 호출의 haiku 자동 선택이 그대로 동작하고, 그 haiku가 로컬 모델로 매핑되는 것이 "백그라운드까지 무료" 정책의 전달 경로다. (2) tier id는 바이너리가 아는 이름이라 미인식-모델-200K-윈도우 문제를 우회한다. (3) 장기 관리 원칙 — registry에서 자유롭게 실험하되 harness가 보는 facade는 작고 안정적으로. tier가 그 facade다.

> **반론**: settings.json 안의 이중 장부(aliases/directAliases/displayNames×2/capabilities×2)는 반만 고치기 쉽다. tier alias가 registry에 존재하는지는 런치 시점에야 검증된다 — doctor에서 정적으로 검사하게 만들 수 있다.

**결정: direct alias는 OpenRouter 원형 id(`deepseek/deepseek-v4-pro`)를 쓰고, `openrouter/` 접두사 입력은 관용 수용 후 전송 시 벗긴다.** [기록] — direct는 OpenRouter 자신과 대화하므로 model 필드는 그들의 어휘여야 한다. 접두사 관용은 registry 백엔드 문자열 복붙이 "proxy에선 되는데 direct에선 404"가 되는 종이베임을 막기 위해서다.

---

## 2. 경계의 진화: "절대 건들지 마"에서 정밀 절단선으로

이 절은 이 repo에서 가장 중요한 서사다. 초기 개발 단계의 지시는 **"native를 절대 건들지 마"**였고, 그것은 신뢰가 확립되지 않은 시점의 올바른 보수적 기본값이었다 — 그래서 root 커밋은 완전 격리(별도 CLAUDE_CONFIG_DIR, 별도 모든 것)로 시작했다.

그러나 완전 격리는 실제 비용을 드러냈다: 두 변형이 서로 다른 권한 allowlist, 다른 메모리, 다른 plugins/skills로 갈라져 "하나처럼 움직여야 하는 부분"이 깨졌다. 2026-06-11, 완전 통합(단일 config dir)과 완전 격리 사이에서 **실증으로** 절단선을 그었다. mock 백엔드 + 실제 claude v2.1.173 바이너리로 확인된 7가지 사실이 결정 로그에 있다(아키텍처 문서 2026-06-11 로그). 요지:

| 공유하면 깨지는 것 (→ 격리 유지) | 격리하면 깨지는 것 (→ 공유) |
|---|---|
| 트랜스크립트 교차 resume: 미인식 모델 id는 200K 윈도우로 간주되어 1M 세션이 즉사; tool 블록은 재생되어 LiteLLM 변환 결함을 밟음; 죽은 백엔드 resume은 합성 턴을 영구 기록 | settings/권한 allowlist의 분기 |
| auto-memory: 약한 모델이 쓴 "사실"이 native 세션을 오염 | plugins/skills/CLAUDE.md의 분기 |
| 자격증명: CLAUDE_CONFIG_DIR가 Keychain 서비스명을 해시 접미 — 통합 시 정체성 분열 | 도구용 API 키(env 블록)의 분기 |

**구현: 격리된 config dir 안에서 user-scope 6개 항목(settings.json, settings.local.json, plugins, skills, keybindings.json, CLAUDE.md)만 `~/.claude`로 symlink.** [기록+실증]

- **왜 symlink인가(복사/동기화가 아니라)**: 쓰기를 수행하는 것은 fabric이 아니라 Claude Code 자신이다 — 권한 결정, plugin 상태가 native 세션과 똑같이 누적되고, 동기화 단계도 병합 충돌도 없다. dangling link는 의도된 동작이다(native 파일이 생기면 자동 점등; fabric은 `~/.claude`를 절대 생성하지 않으며 check가 이를 단언한다).
- **마이그레이션 안전**: 기존 실파일은 `.isolated.bak`으로 보존(삭제 금지). `AI_LITELLM_SHARED_ENV=0`은 유지보수만 멈추고 기존 link를 되돌리지 않는다 — 격리 복귀는 link 제거 + bak 복원.

**구현: 백엔드 라우팅은 오직 per-invocation process env + 모드별 `--settings` 오버레이로만 흐른다.** [실증]

이 불변식은 두 개의 실증 사실 위에 서 있다: settings env 블록은 시작 시 `Object.assign(process.env, ...)`로 **process env를 덮어쓰고**(즉 공유 settings에 라우팅 키가 들어가면 모든 변형이 조용히 하이재킹된다), `--settings`(flagSettings)는 userSettings를 **이긴다**(즉 오버레이만이 공유 설정을 모드별로 하향할 수 있는 검증된 메커니즘이다). 그래서:

- **launch-time lint가 hard-fail한다**: 공유 settings env 블록에서 라우팅 키(ANTHROPIC_BASE_URL/AUTH_TOKEN/API_KEY/MODEL/DEFAULT_*, CLAUDE_CODE_의 라우팅·예산 스위치, OPENROUTER_*, LITELLM_*)를 발견하면 실행 거부. 경고가 아닌 이유: 조용한 전면 재라우팅은 경고로 막을 수 있는 부류가 아니다. telemetry/OTel 류 무해 키는 의도적으로 통과시킨다(과차단은 사용자를 전역 우회 스위치로 몰아간다).
- **`permissions.defaultMode=default`는 양 모드 공통 generatedSettings에 있다**: native의 `bypassPermissions`가 비-Anthropic 모델 세션에 상속되지 않게 하는 장치. 처음에는 proxy 오버레이에만 있었다 — 당시엔 direct=Anthropic 모델이라 모드↔모델계급이 1:1이었기 때문이다. 2026-06-12 tier 재구성으로 direct도 비-Anthropic이 되면서 그 등가성이 깨졌고, 감사가 이를 "기록되지 않은 누락"으로 판정해 공통 베이스로 이동했다. **불변식은 모드가 아니라 모델 계급 기준이다.**
- **오버레이 렌더는 재귀적 결손 채움**: 사용자가 오버레이에 `permissions.allow`를 추가해도 `defaultMode` 안전 기본값이 소실되지 않는다(상위 키 단위 병합이었다면 조용히 사라졌을 것이다). 기존 값은 절대 덮어쓰지 않는다. **이것이 곧 운영자 override 채널이다**: 불변식의 정확한 문장은 "defaultMode가 default로 *렌더*된다"(신규 상태 기준 — check가 검사하는 것)이지 "운영 머신의 오버레이가 영원히 default다"가 아니다. 운영자가 렌더된 오버레이에서 `defaultMode`를 `bypassPermissions`로 명시적으로 올린 것은 **의도된 선택이며 버그가 아니다** — fill-only 렌더가 그 값을 보존하는 것이 사양이다. 미래의 감사는 라이브 오버레이의 상향을 위반으로 판정하지 말 것.
- **`/model`이 남기는 모델 pin은 경고만 한다**: wrapper는 항상 `--model`을 명시하므로(CLI가 settings를 이김) fabric 쪽은 구조적으로 면역이고, 남는 피해는 native 쪽뿐인데 그것은 fabric이 프로그램적으로 고칠 수 없다(공유 파일에 쓰기 금지). native 세션에서 /model을 다시 실행하라는 경고가 정확한 대응이다.

> **반론**: settings.local.json까지 공유하면 약한 모델 세션에서 내린 권한 허용이 즉시 native에도 적용된다. lint는 라우팅 키만 막고 권한 규칙은 막지 않는다. 신뢰 수준별 권한을 원한다면 settings.local.json을 공유 목록에서 빼는 재분리가 자연스러운 수정이다. / lint 정규식은 denylist다 — 미래의 새 라우팅 env는 누군가 갱신할 때까지 통과한다. claude 바이너리 업그레이드 시 재점검 대상.

**scrubEnv의 3계급 분류** [재구성]: wrapper가 주입하는 모든 변수(부재의 결정성 — direct 모드에서 MAX_OUTPUT_TOKENS는 사용자 셸이 export했어도 반드시 unset), 자식이 자기 이름으로 가질 필요 없는 시크릿(최소 권한 — 세션 안에서 에이전트가 실행하는 셸 명령이 provider 키를 읽을 수 없다), 교차-harness 상태(CODEX_HOME 등 — 세션 안에서 native codex를 부르면 native 기본값을 봐야 한다).

> **반론**: scrub 목록은 lint 정규식보다 좁다(예: ANTHROPIC_SMALL_FAST_MODEL은 lint는 막지만 scrub은 안 함). "셸 ambient env는 사용자의 의도적 행위"라는 해석이면 의도된 비대칭이고, 아니면 갭이다 — 어느 쪽인지 기록이 없으므로, 건드릴 때 결정하고 기록하라.

---

## 3. 이름의 철학

**결정: LiteLLM surface model_name이 유일한 정본 식별자다. 백엔드 id는 입력 설탕으로 수용하되 즉시 정본명으로 정규화한다.** [기록]

한도 앵커, 런타임 매핑, 예약 정책, harness 설정 전부가 단 하나의 문자열을 키로 쓴다. git에 중복 라우트를 넣는 대신 resolver가 입력층에서 흡수한다.

**결정: 네이밍 컨벤션 = `<모델>-<프로바이더 소문자>`, picker 표시명 = `<모델> (<프로바이더 소문자>)`.** [기록, 사용자 확정]

브랜드 케이싱(oMLX/OpenRouter)을 거부한 이유는 미학이 아니라 기계적 파생이다: suffix가 런타임 이름에서 자동 생성되려면(`omlx`→`-omlx`, 미래의 `ollama`→`-ollama`) 케이싱 테이블이 없어야 한다. 표시명이 어차피 cosmetic 계층을 따로 가지므로 브랜드 케이싱은 어떤 정보도 운반하지 않는다.

**결정: 모델→런타임 멤버십은 api_base 동등성만으로 결정된다. 이름은 결코 멤버십을 결정하지 않는다.** [기록]

modelPrefix(이름 접두사 멤버십)는 06-12 리네임에서 개념째 제거됐다. "이 모델을 어느 엔드포인트가 서빙하는가"는 이름이 아니라 api_base가 운반하는 사실이기 때문이다. 로컬 라우트의 분류 마커는 `api_key: none`이다(발견 라우트 생성기와 승격 엔트리 모두 이를 방출). 이 매핑의 건전성은 런타임 간 apiBase 유일성 검사에 의존한다 — 코드 주석에 명시.

> **반론**: 미래의 런타임이 한 엔드포인트 뒤에서 path 기반으로 여러 모델군을 다중화하면 api_base 동등성이 그들을 한 런타임으로 뭉뚱그린다. 그때는 멤버십 키를 (api_base, path-prefix)로 확장해야 한다.

**결정: tier에 매핑된 로컬 모델은 discovered route가 아니라 x-limits 앵커를 가진 정식 registry 엔트리로 승격한다.** [기록] — discovered는 "이 컴퓨터가 지금 서빙 중인 것"이라는 기계 진실이고 reinstall/디스커버리에서 증발한다. tier가 증발물에 의존하면 harness가 조용히 깨진다. 승격 엔트리와 같은 backend(model+api_base)를 서빙하는 discovered route는 dedup으로 생성이 차단된다.

**결정: codex surface는 번들 슬러그 facade(gpt-5.5 등)를 유지한다 — claude와 정반대의, 의도된 비대칭.** [기록]

codex는 자기 카탈로그로 모델을 검증·구동한다: 카탈로그는 번들 카탈로그의 clone-and-patch로 생성되고, 카탈로그에 없는 원시 이름은 그냥 실패할 수 있으며, `review` 기능은 `codex-auto-review` 슬러그를 하드코딩 요청한다. surface명==번들 슬러그면 codex 제품 표면 전체(picker, 기본값, 슬러그별 reasoning level)가 무수정으로 동작하고 라우팅만 밑에서 바뀐다. claude는 카탈로그 제약이 없으므로 정직한 실명이 이긴다.

> **반론**: "gpt-5.4가 사실은 Kimi"는 호환성을 위한 의도된 거짓말이다. 완화 장치는 인접한 `-openrouter` 실명 엔트리(같은 앵커 공유)와 `ai-litellm route info`. codex가 일급 커스텀 모델 지원(profile-v2 시대)을 얻으면 실명 이전을 재론하라.

**결정: /model picker의 게이트웨이 디스커버리는 휴면 상태로 둔다.** [기록+실증] — 바이너리는 id가 `^(claude|anthropic)`인 항목만 목록화한다(표시명이 아니라 **id**, 즉 surface명 기준 — 실증). 컨벤션을 굽혀 `anthropic-<surface>` alias를 만드는 것은 기각. tier 외 모델은 런치 인자 또는 `/model <surface명>` 타이핑으로 쓴다. proxy에서 discovery=1을 유지하는 것은 무해하며, 미래에 필터가 풀리면 공짜로 점등된다.

---

## 4. 토큰 정책 3계층

이 스택 전체가 하나의 실증된 공포에서 나왔다: **공유 윈도우 프로바이더는 input + 예약 output을 한 윈도우로 회계한다.** Kimi는 output 능력치가 윈도우와 같아서(262142), 능력치를 예약으로 보내면 입력 예산이 0이 되고, ~240K 입력에서 400이 재현됐다(C2 감사).

**1층 — 능력치(x-limits 앵커)** [기록]: underlying 모델당 앵커 1개, 모든 surface는 `model_info: *alias` 참조(인라인 숫자 금지, doctor가 강제). 여러 facade가 같은 백엔드로 수렴하므로(DeepSeek 하나가 3개 surface를 서빙) 앵커 1개 수정이 전부를 갱신한다. 모든 수치는 출처 라벨(provider/observed/owned-policy)을 달아야 한다 — C6 감사가 "추측 숫자와 프로바이더 공표 숫자가 구분 불가"한 상태를 부정직으로 판정했기 때문. `x-limits`가 LiteLLM이 무시하는 최상위 키인 것은 의도다: LiteLLM이 이미 읽는 파일 안에 fabric 소유 정책이 동거하면서 앵커가 model_info와 같은 문서에서 해석된다. **discovered route만 인라인 model_info를 갖는 예외**는: 그 숫자들이 능력치가 아니라 런타임 정책(보수 기본값/override)이고, 관리 블록이 통째로 재생성되기 때문이다.

**2층 — harness 예약(adapterConfig.outputReservation)** [기록]: 예약은 모델 능력치가 아니라 **harness 정책**이다 — 같은 모델에 두 harness가 다르게 예약할 수 있고, 능력치 메타데이터(OpenCode/Goose가 파생하는)를 오염시키면 안 되므로 x-limits가 아닌 descriptor에 산다. 32000/8192/32768 삼중값: 32000은 C5 감사의 표준화 권고(관측된 codex 암묵 출력 ≈22K에 여유를 더한 값), minimumInput 32768은 입력 예산 바닥. 파생물: claude proxy의 `CLAUDE_CODE_MAX_OUTPUT_TOKENS=예약`/`AUTO_COMPACT_WINDOW=유효입력`(컴팩션이 프로바이더 거절보다 먼저 발화하도록), codex 카탈로그의 윈도우 축소(codex는 출력 예약 레버가 **없어서** — model_max_output_tokens는 파싱되고 무시됨이 검증됨 — 믿음 형성이 예약을 대신한다), goose/opencode env 주입. 로컬 모델은 카탈로그 축소에서 면제(이미 정책 캡이 훨씬 낮아 이중 낭비).

**3층 — gateway 강제(clamp + cost guardrail)** [기록+실증]: `async_pre_call_deployment_hook` 커스텀 콜백인 이유는 측정이다(verify_litellm_token_clamp.py, LiteLLM 1.81.14): `litellm_params.max_tokens`는 더 큰 클라이언트 값을 못 낮추고, `modify_params:true`는 max_tokens만 잡고 max_completion_tokens(codex의 responses 경로!)를 놓친다. 오직 이 훅만 둘 다 낮추며, deployment 선택 후라 model_info 인지 캡이 가능하다. clamp는 **lower-only**(키 부재 시 주입하지 않음 — 예약 도입은 harness 층의 일). guardrail은 청구서 등급이 아니라 사전 차단이다($1.06짜리 단일 요청 실측 + `--max-budget-usd`가 이 경로에서 하드 리밋이 아님이 확인된 후 만들어짐). 순서는 clamp→guardrail(가드레일이 클램프 후 요청을 가격하도록). doctor는 두 정책의 `enabled:false`를 설정 선택이 아니라 **고장**으로 취급한다 — 방어층은 공격이 아니라 "임시로 꺼둔 것"으로 죽는다.

> **반론(이 층의 가장 강한 것들)**: ① guardrail 전역 200K는 Kimi의 적법한 221950 유효 입력보다 작다 — 스택이 정성껏 보존한 능력을 가드레일이 깨문다. 첫 실제 >200K 워크플로우가 나타나면 perModel 한도를 구현하라(권고 문서에 이미 스펙됨). ② 같은 예산 공식이 **세 언어(Node/Ruby/Python)에 3중 구현**되어 있다 — M5 로그가 blast-radius를 이유로 통합을 보류했고, check의 221950/3277 고정 단언이 유일한 드리프트 방지선이다. 이 서브시스템 최대의 잠재 버그원. ③ 발견은 LiteLLM 1.81.14에 핀되어 있다 — 업그레이드마다 verify 스크립트를 재실행하라(스크립트의 recommended_policy는 modify_params가 충분해지면 훅 제거를 권하도록 짜여 있다: "검증되는 가장 단순한 메커니즘을 써라").

**drop_params: true** [재구성, pre-git]: N개 harness가 자기 방언(thinking/betas/effort)을 M개 백엔드에 過광고하는 구조에서, 끄면 거의 모든 라우트 조합이 400으로 하드 실패한다. 가용성-우선을 선택하고 그 비용(조용한 드롭)을 관측 가능하게 만들었다: reasoning matrix의 drop_risk 컬럼, 그리고 모델별 교정은 flag 반전이 아니라 `SUPPORTED_CAPABILITIES` 선언으로 한다(기본 미설정 — 현 동작 불변이 기록된 결정). 추론 품질이 이유 없이 낮으면 이 flag가 제1용의자다.

**관측은 증거이지 진실이 아니다** [기록]: GLM이 204800을 받은 관측과 프로바이더 공표 202752는 **둘 다 참일 수 있다**(OpenRouter는 멀티플렉서다). 그래서 관측은 `>=N`으로 표시만 하고 강제는 보수값을 유지하며, 모순되는 관측은 해소하지 않고 보존한다(F2.5 규칙). probe는 돈이 들므로 절대 자동 실행하지 않는다.

---

## 5. 시크릿 계층

| 계층 | 보관처 | 흐름 | 강제 |
|---|---|---|---|
| 라우팅/프로바이더 키 (OpenRouter, LiteLLM master, 향후 provider) | Keychain (`ai-litellm key set --keychain`; env 파일은 포터블 폴백) | per-invocation 주입. proxy 모드의 자식은 master key만 본다 — provider 키는 proxy 프로세스에만 존재하므로 **세션 안의 에이전트가 자기 env에서 provider 키를 읽을 수 없다** | lint가 공유 settings 유입을 hard-fail; check가 `$(touch PWNED)` 주입 공격을 단언; repo 전체 키-형태 grep |
| 세션 도구 키 (Bash에서 curl로 쓰는 Brave 등, MCP env) | 공유 `~/.claude/settings.json` env 블록 | symlink로 native/litellm 자동 공유 → Claude Code가 process env에 적용 → Bash 서브프로세스 상속 ([실증]: 로컬 Qwen 세션에서 `BRAVE_SEARCH_API_KEY` 존재 확인) | scrub/lint 의도적 통과 (check에 BRAVE 통과 단언) |
| 외부 시스템 (openclaw 등) | 각자 설정; Keychain source 패턴 권장 | 비공유 | — |

설계 원칙: **도구 키는 "claude native 기준" 한 곳에서 관리하면 양쪽에 흐른다** — 세션 경계 재설계가 의도한 동작이다. 트레이드오프: 도구 키는 비-Anthropic 모델이 모는 세션에도 노출된다(그래서 권한 하향이 존재한다). Claude Code 자체는 Brave 키를 모른다(바이너리에 참조 없음 — 소비자는 allowlist된 Bash curl 패턴이다). master key가 평문 0600 env 파일에 생성되는 것은 첫 실행 UX를 위한 선택이고, localhost:4000에만 유효한 로컬 자격증명이라 수용했다.

---

## 6. harness 비대칭의 이유

네 harness가 네 가지 다른 격리 전략을 쓰는 것은 비일관성이 아니라 **각 CLI의 설정 표면이 강제한 결과**다.

- **claude — 공유 환경 + 격리 세션** (§2): config dir가 알갱이 단위라 symlink 절단선이 가능했다.
- **codex — 완전 격리 CODEX_HOME.** [기록] 세 가지가 claude식 처리를 막는다: CODEX_HOME이 monolithic(세션/메모리/설정이 한 뿌리 — 알갱이 절단 불가), memories sqlite에 provider 컬럼이 없음(약한 모델 메모리를 사후 필터링 불가), generator가 config.toml을 통째 교체(공유 시 native 파괴). 미래 경로는 profile-v2인데, codex 0.138.0에서 **미명시 키가 native의 `approval=never`/`danger-full-access`를 상속하는 함정이 실증**되어 있다 — profile 파일은 approval_policy/sandbox_mode/model_catalog_json을 반드시 명시해야 한다. 생성 config가 on-request/workspace-write/home-untrusted로 고정되는 것은 같은 원칙(약한·미지 모델은 관대한 모드를 상속받지 않는다)의 codex 버전이다. `shell_environment_policy inherit="core"`는 모델이 실행하는 셸 명령이 master key를 못 읽게 하는 장치다.
- **goose — env-injector만, 생성 파일 없음.** [기록] goose는 provider 설정을 env로 받으므로 주입이 본질적으로 비파괴적이다. 단 `goose configure`는 wizard가 native config.yaml에 litellm provider를 영구 기록하므로 blockedSubcommands로 차단한다(모델-선행 호출형 `goose-litellm <model> configure`까지 잡도록 검사가 모델 소비 **후**에 위치 — 한 번 우회당한 뒤 수정된 이력이 check에 양 형태로 박제됨). `GOOSE_DISABLE_SESSION_NAMING=true`는 세션 제목 하나를 위해 게이트웨이 완료 호출 1회를 몰래 쓰는 것을 끄는 것이다[재구성 — 상류 문서로 메커니즘 확인, repo 내 동기 기록은 없음].
- **opencode — OPENCODE_CONFIG 파일 포인터 + XDG 리디렉션.** [기록] config 경로를 env로 받으므로 생성 파일이 native 트리 밖에 있으면 끝. per-model limit 블록은 opencode의 32000 절단 기본값을 교정한다.

---

## 7. 설치/검증 철학

**copy-and-render 패키지 (symlink 농장 금지)** [기록+재구성]: 네 가지가 겹친다 — ① JSON/TOML은 env 확장이 없어 절대 경로가 렌더 시점에 박혀야 한다(`__HOME__`/`__FABRIC_HOME__`), ② 패키지는 checkout 사후 생존해야 한다(uninstall.zsh를 패키지 안에 복사), ③ 설치본은 가변 런타임 상태다(`reasoning set`이 descriptor를 수정 — symlink면 git checkout에 쓰게 됨), ④ state가 prefix 안에 산다. repo 루트에 실존하는 `__FABRIC_HOME__/` 디렉토리가 렌더 없이 checkout에서 wrapper를 실행하면 무슨 일이 나는지의 물증이다. 멱등성+변경 시 백업(`cmp -s` 동일이면 무백업 — check가 "동일 재설치 시 백업 0"을 단언).

**check.zsh = 집행 척추**: 일회용 mktemp HOME에 **진짜 설치**를 수행하고 마지막에 `~/.claude`/`~/.codex`가 생성되지 않았음을 단언한다 — 경계 계약을 개발자의 실제 native 설치를 위험에 빠뜨리지 않고 매 CI에서 검증. master key 소스를 의도적으로 눈멀게 해(LITELLM_MASTER_KEY= + 미스 보장 keychain 계정) 자동 생성 경로를 결정론적으로 태운다. stub claude 패턴: wrapper의 산출물은 자식 프로세스가 받는 env+argv 계약이므로, 그 계약 자체를 echo로 관측한다(네트워크/과금/실바이너리 불요). **`set -e` 사건**: 내부 `zsh -fc` 블록은 마지막 명령의 종료코드만 전파하므로, d1c4edd 이전의 모든 중간 단언은 조용히 무효였다 — 모든 green run이 보이는 것보다 적게 증명하고 있었다. 적대적 테스트: PWNED 주입(시크릿이 어느 층에서도 셸 평가되지 않음), 외부 pid 보호(pid 파일의 프로세스가 litellm이어야만 신뢰 — pid 재활용 시 무고한 프로세스 kill 방지), 공백 포함 prefix 전체 수명주기.

> **반론**: 단일 순차 스크립트는 첫 실패가 나머지를 가리고, claude만 stub이 있다(codex/goose/opencode 런치 계약은 간접 검증) — stub 패턴 확장이 자명한 다음 투자다.

---

## 8. 불변식 → 강제 장치 매핑 (수정 제한 권고)

"이건 수정 제한을 하는 게 낫겠는데?"에 대한 현황표. **강제됨**은 깨면 check/doctor가 빨갛게 된다는 뜻이고, **무방비**는 조용히 깨진다는 뜻이다.

| 불변식 | 강제 |
|---|---|
| 앵커 참조 강제(인라인 model_info 금지, 관리 블록 제외) | ✅ doctor + check |
| 기본 모드/디스패치/alias 해석/wire-strip | ✅ check |
| 공유 settings env 라우팅 키 금지 | ✅ launch lint + check |
| 양 오버레이의 defaultMode=default **렌더 기본값** (라이브 오버레이의 운영자 상향은 사양임 — §2) | ✅ check (06-12 추가; throwaway HOME의 신규 렌더만 검사) |
| symlink 존재·대상·`~/.claude` 비생성·멱등 | ✅ check |
| 예약 수치(221950/3277) 3중 구현 lockstep | ✅ check (수치 고정 — 바꾸려면 의식적 동시 수정 강요) |
| gateway 정책 enabled=true | ✅ doctor ("must stay true") |
| codex 카탈로그 신선도 | ✅ doctor limit-sync |
| dedup(빈 출력 단언 — 네이밍 변경에 면역) | ✅ check (06-12 수정: 종전 단언은 옛 이름을 검사해 무효였음) |
| 경계 계약(native 디렉토리 비생성, 시크릿 비평가, uninstall prefix 안전) | ✅ check |
| **scrub 실효성**(scrub된 var가 자식 env에서 실제로 사라지는지) | ⚠️ 무방비 — codex/goose/opencode용 stub 테스트 권고 |
| **harness 예약 ↔ gateway clamp 수치 정렬** | ⚠️ 무방비 — doctor warn 권고 (주석으로만 선언됨) |
| **codex 생성 config의 안전 키 존재**(approval/sandbox/trust) | ⚠️ 무방비 — 렌더 결과 grep 권고 |
| **앵커 ↔ modelInfoOverrides 동족 글롭 수치 일치** | ⚠️ 무방비 — 저위험, doctor warn 후보 |
| **lint denylist의 신선도**(새 라우팅 env) | ⚠️ 구조적 한계 — claude 업그레이드 시 수동 재점검 |
| general_settings 위치(생성 블록 삽입 landmark) | ⚠️ 실패는 loud — yaml 주석으로 선언 |

생성물 표식: codex config.toml/model-catalog.json, opencode.json, discovered routes 블록은 **손편집 금지**다(매 런치/sync에 전량 재생성). discovered 블록은 BEGIN/END 마커와 배너가 있고, codex config.toml에도 생성 배너 추가를 권고한다(§10).

---

## 9. 근거 불명·미해결·단순화 후보 (정직한 목록)

감사가 "방어 가능한 근거 없음" 또는 "기록 없음"으로 판정한 것들. 합리화하지 않고 그대로 둔다 — **이 목록의 항목을 지우는 올바른 방법은 측정하거나, 기록하거나, 단순화하는 것이다.**

1. **tokenizerHeadroom=8192** — 기능(하니스↔프로바이더 토크나이저 오차 패드)은 구조적으로 필요함이 입증됐지만(Kimi 경계 ±1 토큰에서 200↔400 실측), **수치 8192는 측정 없는 2^13 라운드 넘버**다. 절대값이라 보호율도 비일관(Kimi ~3.6%, DeepSeek 1M ~0.8%). 예산 내 경계 400이 한 번이라도 나면 그 관측으로 재유도하라.
2. **소형 윈도우 스케일링 10%/50%** — 목적(정책 상수가 8K 윈도우를 잡아먹지 않게)은 명확하나 비율 자체는 미측정.
3. **subagentModel이 direct 전용** — 출생(8a507e1: main=sonnet, subagent=opus 품질 핀) 후 proxy로 이식되지 않았다. 바이너리 분석 결과 proxy에서 핀 부재는 사실상 옳다(미핀 subagent는 main 모델을 상속하며, 핀은 세션의 /model·로컬 tier 선택을 짓밟는 전역 override다). 현 기본값에서는 no-op이기도 하다. 의도였는지는 미기록 — 현 상태로 두되 주석으로 범위를 선언했다.
4. **CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK가 direct 전용** — OpenRouter 레시피의 일부로 재구성되나 proxy 부재의 이유는 미확인.
5. **gpt-5.4-mini가 카탈로그 클론 베이스인 이유** — "가장 중립적인 소형 템플릿"으로 추정될 뿐 기록 없음. 번들에서 사라지면 models[0] 폴백이 놀라운 기본값을 가질 수 있다.
6. **harness별 기본 모델 분배(codex=DeepSeek+xhigh, goose/opencode=Kimi)** — codex만 reasoning-effort 레버가 있어 최강 추론 백엔드와 짝지은 것으로 재구성되나, 정확한 가중(비용? eval?)은 미기록. 다음에 만질 때 기록하라.
7. **shell.zsh의 하드코딩 폴백들**(env 이름, tier 목록, 모드별 default의 화석화된 opus/sonnet 종단) — descriptor가 검증 필수라 건강한 설치에서 도달 불가능한 사실상 죽은 코드. loud-fail로 교체가 방어 가능한 정리다.
8. **deprecated alias 테이블에 일몰 기준이 없다** — 무해하나 영생할 것이다.
9. **availabilityNux** — 의미는 상류 소스로 확정(모델 광고 툴팁의 표시 횟수 카운터, 상한 4). 값 3은 작성자의 라이브 카운터 복사로 추정되며 **기능적으로 틀려서**(3<4 + 매 런치 재렌더로 증분 소실 → 툴팁 매번 재출현) 4로 수정했다(06-12).
10. **nvm 부트스트랩 비대칭** — 드리프트로 판정(npm 배포 CLI 시대의 잔재). PATH-최소 컨텍스트에서 goose/opencode가 hard-fail하고 key-status가 **조용히 "키 없음"으로 오보고**하던 것을 7개 shim 통일로 수정했다(06-12).
11. **`__FABRIC_HOME__/` 리터럴 디렉토리가 repo 루트에 생긴다** — checkout에서 wrapper를 직접 실행하면 미렌더 경로에 상태를 쓴다는 살아있는 풋건. 해석된 경로에 placeholder가 남아 있으면 loud-fail하는 lib.zsh 가드가 싼 보호다.
12. **관측의 무기한 표시** — 2026년의 lower bound가 2027년에도 신뢰를 빌려준다. 프로바이더 믹스가 유동적이 되면 타임스탬프 표시/노화를 고려하라.

---

## 10. 반론 초대 (전제 감시 목록)

각 결정이 의존하는 전제와, 그것이 바뀌었을 때 열어야 할 문:

| 전제 | 깨지면 재론할 결정 |
|---|---|
| OpenRouter Anthropic skin의 tool-calling 미검증 | direct 보조 경로 지위 (검증되면 승격 또는 듀얼 모드 자체의 단순화) |
| LiteLLM 1.81.14의 clamp 결함 | C4 커스텀 훅 (verify가 modify_params 충분을 보고하면 훅 제거) |
| codex의 카탈로그 검증 + profile-v2 상속 함정 | codex facade 네이밍, CODEX_HOME 완전 격리 |
| claude 바이너리의 `^(claude\|anthropic)` picker 필터 | discovery 휴면 (필터 완화 시 picker가 갑자기 채워짐 — 양성이나 놀람) |
| 미인식 모델 id = 200K 윈도우 믿음 | tier 간접화의 근거 일부, AUTO_COMPACT 주입 수치 |
| 단일 사용자 로컬 머신 | pid 지문의 관대함(`*litellm*`), guardrail의 전역 단일 한도, 콜백의 요청당 YAML 재파싱 |
| 런타임 1개(omlx) | 런타임 kind 기계의 사변적 일반성, 반쯤-다운된 멀티런타임의 stale 블록 보존 |
| OpenRouter가 id 어휘를 유지 | direct wire-strip의 단일 리터럴 접두사 |

---

*이 문서를 갱신하는 규칙: 결정을 바꾸면 해당 절의 전제·반론을 함께 갱신하고, 새 "근거 불명"을 만들지 말 것 — 만들었다면 §9에 자수하라. 날짜 있는 사건 기록은 아키텍처 문서의 결정 로그가 정본이고, 이 문서는 그 로그들의 "왜"를 종합한 살아있는 뷰다.*
