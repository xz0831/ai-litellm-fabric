# Design Rationale — 왜 이렇게 만들었는가

Last updated: 2026-06-29

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

**결정: 'fable'을 4번째 Claude Code tier로 추가한다 — opus/sonnet/haiku와 동급의 일급 tier이지, 우리가 만든 가짜 이름이 아니다.** [실증, 2026-06-19/20]

`ANTHROPIC_DEFAULT_FABLE_MODEL`(+`_NAME`/`_SUPPORTED_CAPABILITIES`)은 **Claude Code 바이너리가 네이티브로 읽는 실제 env**다 — claude harness descriptor(`config/ai-litellm/harnesses/claude.json`)의 envAllowlistAdditions와 `models.tiers`(`["fable","opus","sonnet","haiku"]`)가 이를 박는다. fable이 descriptor-driven인 점이 핵심이다: tier 목록·env 이름·alias 장부가 모두 한 descriptor에서 흐르므로, 4번째 tier 추가는 하드코딩 분기가 아니라 descriptor 한 곳 + 이중 장부(settings.json의 aliases/directAliases/displayNames×2)의 fable 행 추가로 끝난다. 현 매핑(`config/claude-litellm/settings.json`): proxy fable=`GLM-5.2-openrouter`, direct fable=`z-ai/glm-5.2`. tier 간접화(위 결정)의 전제 — "Claude Code가 tier 이름을 네이티브로 이해한다" — 가 fable에도 그대로 성립하는 것이 이 추가의 정당성이다.

> **반론**: fable이 Claude Code의 *모든* tier-인지 경로(세션 내 `/model fable`, 백그라운드 자동 선택, effort 광고)에서 opus/sonnet/haiku와 동등하게 동작하는지는 env 존재로 *추정*되나, 본 repo에서 fable의 4경로 전수 동작을 별도 eval로 실증한 기록은 없다 — env가 인식된다는 것과 picker/`/model` UX가 4번째 tier를 매끄럽게 노출한다는 것은 다른 주장이다. 의심되면 라이브 세션에서 확인하라.

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

### 2a. HARD CONSTRAINT 재확인: native harness는 litellm/fabric 때문에 결코 영향받지 않는다 (track-4 기각)

**결정: native harness(codex/claude)는 litellm/fabric의 존재 때문에 절대 동작이 바뀌면 안 된다 — 이 불변식이 "codex-litellm 카탈로그를 native `~/.codex`의 ACTIVE 카탈로그에서 소싱하자"(track-4)는 접근을 기각시켰다.** [기록, 2026-06-19/20]

§2가 절단선을 정밀화했지만(공유는 user-scope 6항목 symlink로 한정), 그 절단선의 *제1전제*는 여전히 "native가 fabric 때문에 깨지지 않는다"이다. codex facade가 active-only 슬러그(`gpt-5.3-codex-spark`)를 못 쓴다는 §3의 제약이 정확히 이 전제에서 나온다: active 카탈로그를 native 로그인 상태에서 끌어오는 track-4는 (a) fabric의 sync가 native의 로그인/네트워크 상태에 *읽기 결합*되고(native 로그아웃 시 fabric sync가 깨지거나 stale를 굳힘), (b) 더 위험하게는 격리 CODEX_HOME이 native 카탈로그를 *참조*하기 시작하면 격리 자체가 허울이 된다. **공유 user-scope 항목(skills, CLAUDE.md, plugins, settings via symlink)은 의도된 공유이며 이 제약에 *걸리지 않는다*** — 그것들은 Claude Code 자신이 native 세션과 동일하게 누적하는 상태이지, fabric이 native의 동작을 바꾸는 것이 아니다(§2의 "쓰기를 수행하는 것은 fabric이 아니라 Claude Code 자신" 논리와 동일). 경계의 정확한 문장: **fabric은 native가 *공유하기로 한* 것을 native와 함께 쓸 수 있으나, native의 검증/카탈로그/로그인 상태를 *소스로 삼을* 수는 없다.**

> **반론**: track-4를 기각한 대가는 실재한다 — 사용자가 원한 정확한 슬러그를 못 주고(§3 반론), 번들 베이스라인이 active 카탈로그보다 뒤처질 수 있다. 그러나 이 비용은 "native harness 격리"라는 repo의 존재 이유와 맞바꿀 수 없다: track-4가 한 번 결합을 들이면, native codex 로그아웃·재로그인·카탈로그 변동이 모두 fabric의 잠재적 고장 표면이 된다. 전제 감시: codex가 *로그아웃 상태에서도* active 카탈로그를 안정적으로 노출하게 되면(현재는 아님), track-4의 결합 위험이 사라지므로 재론 가능하다.

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

**결정: 모델 선택 계약 — `claude-litellm <token>`의 선행 positional은 모델 선택자다. tier(opus|sonnet|haiku) 또는 등록된 registry model_name으로 resolve되지 않으면 **loud-error**(비-0 종료), 절대 프롬프트로 누출시키지 않는다. 임의 alias-map 키는 확장하지 않는다.** [실증, 2026-06-13]

배경: openclaw-brain eval 세션이 4번째 로컬 모델을 `--proxy <X>`로 추가하려다 실패했고, "모델이 alias 문자열을 프롬프트로 받는다"고 보고했다. 실증 결과 근본 원인은 단 하나였다 — `claude-litellm()` arg 파서에서 선행 positional이 어느 분기에서도 소비되지 않으면(미인식 tier/model_name, 또는 오타) `shift`되지 않아 `claude`에 **프롬프트로 조용히 누출**되고, `launch_proxy`가 빈 `requested`를 default tier로 폴백해 성공하므로 에러조차 안 났다. 이 footgun이 (a) 오타와 (b) alias 키 시도 둘 다를 "프롬프트 손실"로 보이게 만들었고, 별개로 보였던 F2(route-level thinking-off "프롬프트 손실")도 사실 같은 footgun이었다(잘못된 이름으로 라우트 선택 → 누출 → 모델이 시스템 프롬프트의 "haiku"만 보고 시 작성). 왜 alias-key 확장(`--proxy h35`)을 기각했나: 비-tier alias 키는 Claude 네이티브 의미가 없어(background→haiku, effort 광고가 sonnet을 가리킨 채 남음) "반만 작동하는" 기능이 되고, display/capabilities 루프(models.tiers 순회)와도 어긋난다. 정본 식별자는 surface model_name이고 tier는 3-facade다 — 임의 모델은 `--proxy <model_name>`(이미 작동)으로 선택한다. raw 가드는 모드 무관(proxy + default-direct 누출 모두)으로 걸되, 명시 `--direct <X>`는 OpenRouter가 직접 404를 내므로 관대하게 둔다.

**결정: 로컬 라우트의 per-route litellm_params(thinking-off 등)는 발견 라우트엔 `runtimes.<rt>.litellmParamsOverrides` glob로 주입하고, tier/eval용 항구 라우트엔 정식 엔트리로 승격해 명시한다.** [실증, 2026-06-13]

Qwen3.x thinking 모드는 토큰을 폭증시키고(27B/35B 모두 numeric 문제를 6000 토큰 안에 못 끝냄) 구조적/수치 작업에 해롭다. 실증: route-level `litellm_params.extra_body.chat_template_kwargs.enable_thinking: false`는 LiteLLM→oMLX로 그대로 포워딩되어 thinking을 끈다(148→2 토큰, 프롬프트 보존; `drop_params:true`도 이 키는 떨구지 않음). 발견 라우트는 매 sync에 wholesale 재생성되어 per-route extra_body를 손으로 유지할 수 없으므로, `modelInfoOverrides`와 대칭인 `litellmParamsOverrides`(glob 패턴 → litellm_params 병합, model id와 route명 둘 다 매칭, 뒤 패턴 우선)를 generator에 추가했다 — "벤치마킹용 로컬 모델 교체" churn에서 hand-promotion 없이 thinking-off가 따라온다(기본 `{}` = 무변경, 매칭 시 sync stdout에 어떤 glob이 적용됐는지 로깅). tier/eval용 항구 라우트(예: Phase 0 replication arm `Qwen3.6-35B-A3B-4bit-omlx`)는 정식 엔트리로 승격하며 extra_body를 직접 명시한다 — 발견 라우트의 증발성에 의존하지 않기 위함. **per-model 자격 검증(thinking on/off, 지시 준수, 정확도)은 fabric이 제거할 수 없는 모델별 사실이다**; fabric은 그것을 *실행 가능*하게만 만든다([per-model qualification protocol](AI_AGENT_LITELLM_ARCHITECTURE.md) 참조).

> **반론**: `litellmParamsOverrides` glob는 의도치 않은 모델을 매칭할 수 있다(예: `Qwen3*`가 thinking-OK인 미래 모델까지). 완화: opt-in 기본 `{}`, 매칭 로깅, 좁은 패턴 권장. 또한 항구 엔트리 승격은 머신별 로컬 라우트를 git에 올리는데, 이는 Gemma4-12B-omlx/Qwen3.6-27B-omlx 선례와 일치하며 런타임이 없으면 무해(inert)하다.

**결정: codex surface는 번들 슬러그 facade(gpt-5.5 등)를 유지한다 — claude와 정반대의, 의도된 비대칭.** [기록]

codex는 자기 카탈로그로 모델을 검증·구동한다: 카탈로그는 번들 카탈로그의 clone-and-patch로 생성되고, 카탈로그에 없는 원시 이름은 그냥 실패할 수 있으며, `review` 기능은 `codex-auto-review` 슬러그를 하드코딩 요청한다. surface명==번들 슬러그면 codex 제품 표면 전체(picker, 기본값, 슬러그별 reasoning level)가 무수정으로 동작하고 라우팅만 밑에서 바뀐다. claude는 카탈로그 제약이 없으므로 정직한 실명이 이긴다.

> **반론**: "gpt-5.4가 사실은 Kimi"는 호환성을 위한 의도된 거짓말이다. 완화 장치는 인접한 `-openrouter` 실명 엔트리(같은 앵커 공유)와 `ai-litellm route info`. codex가 일급 커스텀 모델 지원(profile-v2 시대)을 얻으면 실명 이전을 재론하라.

**결정: codex facade 슬러그는 반드시 codex의 `--bundled` 카탈로그 슬러그여야 한다 — ACTIVE(로그인) 카탈로그 슬러그(`gpt-5.3-codex-spark`)는 격리된 codex-litellm에서 사용 불가다.** [기록+실증, 2026-06-19/20]

사용자가 facade로 요청한 `gpt-5.3-codex-spark`는 **ACTIVE-only 슬러그**다 — codex가 네트워크/로그인으로 native `~/.codex`에 fetch해 넣는 것이라, 로그아웃·격리된 `CODEX_LITELLM_CODEX_HOME`은 그것을 끌어올 수 없다. `config/codex-litellm/shell.zsh`(L316–321)의 주석이 이 제약과 그 *순환성*을 명시한다: 격리 HOME에서 `codex debug models`를 돌리면 그건 우리가 방금 생성한 카탈로그 파일을 *되읽을* 뿐이다(circular). 그래서 sync는 `codex debug models --bundled`(L325)로 **번들 베이스라인**을 clone-and-patch하고, litellm 라우트는 정확히 그 번들 슬러그(`gpt-5.5/5.4/5.4-mini/5.3-codex/5.2`)만 덮는다. 결과적으로 현 facade는 번들에 존재하는 슬러그로 매핑됐다(`gpt-5.3-codex`/`gpt-5.2`는 번들에 있음). 이것은 §7의 HARD CONSTRAINT(아래 §2a)의 직접 귀결이다: ACTIVE 카탈로그를 native에서 끌어오는 길은 native 로그인 상태에 결합되므로 *기각*됐고, 그 대가가 "spark 같은 active-only 슬러그는 facade로 못 쓴다"는 제약이다.

> **반론**: 사용자가 정확히 `gpt-5.3-codex-spark`를 원했는데 못 준다는 것은 기능 손실이다. 우회는 두 가지뿐이며 둘 다 더 나쁘다 — (a) native 로그인 카탈로그를 소스로 삼기(HARD CONSTRAINT 위반, native harness 결합), (b) 번들에 없는 슬러그를 facade로 박고 codex가 검증 실패하길 기대(§3 "카탈로그에 없는 원시 이름은 그냥 실패할 수 있다"에 정면 충돌). 둘 다 기각이므로 제약을 수용한다. codex가 로그아웃 상태에서도 active 카탈로그를 노출하거나 일급 커스텀 슬러그를 받으면(profile-v2) 재론하라.

**결정: /model picker의 게이트웨이 디스커버리는 휴면 상태로 둔다.** [기록+실증] — 바이너리는 id가 `^(claude|anthropic)`인 항목만 목록화한다(표시명이 아니라 **id**, 즉 surface명 기준 — 실증). 컨벤션을 굽혀 `anthropic-<surface>` alias를 만드는 것은 기각. tier 외 모델은 런치 인자 또는 `/model <surface명>` 타이핑으로 쓴다. proxy에서 discovery=1을 유지하는 것은 무해하며, 미래에 필터가 풀리면 공짜로 점등된다.

---

## 4. 토큰 정책 3계층

이 스택 전체가 하나의 실증된 공포에서 나왔다: **공유 윈도우 프로바이더는 input + 예약 output을 한 윈도우로 회계한다.** Kimi는 output 능력치가 윈도우와 같아서(262142), 능력치를 예약으로 보내면 입력 예산이 0이 되고, ~240K 입력에서 400이 재현됐다(C2 감사).

**1층 — 능력치(x-limits 앵커)** [기록]: underlying 모델당 앵커 1개, 모든 surface는 `model_info: *alias` 참조(인라인 숫자 금지, doctor가 강제). 여러 facade가 같은 백엔드로 수렴하므로(DeepSeek 하나가 3개 surface를 서빙) 앵커 1개 수정이 전부를 갱신한다. 모든 수치는 출처 라벨(provider/observed/owned-policy)을 달아야 한다 — C6 감사가 "추측 숫자와 프로바이더 공표 숫자가 구분 불가"한 상태를 부정직으로 판정했기 때문. `x-limits`가 LiteLLM이 무시하는 최상위 키인 것은 의도다: LiteLLM이 이미 읽는 파일 안에 fabric 소유 정책이 동거하면서 앵커가 model_info와 같은 문서에서 해석된다. **discovered route만 인라인 model_info를 갖는 예외**는: 그 숫자들이 능력치가 아니라 런타임 정책(보수 기본값/override)이고, 관리 블록이 통째로 재생성되기 때문이다.

**2층 — harness 예약(adapterConfig.outputReservation)** [기록]: 예약은 모델 능력치가 아니라 **harness 정책**이다 — 같은 모델에 두 harness가 다르게 예약할 수 있고, 능력치 메타데이터(OpenCode가 파생하는)를 오염시키면 안 되므로 x-limits가 아닌 descriptor에 산다. 32000/8192/32768 삼중값: 32000은 C5 감사의 표준화 권고(관측된 codex 암묵 출력 ≈22K에 여유를 더한 값), minimumInput 32768은 입력 예산 바닥. 파생물: claude proxy의 `CLAUDE_CODE_MAX_OUTPUT_TOKENS=예약`/`AUTO_COMPACT_WINDOW=유효입력`(컴팩션이 프로바이더 거절보다 먼저 발화하도록), codex 카탈로그의 윈도우 축소(codex는 출력 예약 레버가 **없어서** — model_max_output_tokens는 파싱되고 무시됨이 검증됨 — 믿음 형성이 예약을 대신한다), opencode env 주입. 로컬 모델은 카탈로그 축소에서 면제(이미 정책 캡이 훨씬 낮아 이중 낭비).

**3층 — gateway 강제(clamp + cost guardrail)** [기록+실증]: `async_pre_call_deployment_hook` 커스텀 콜백인 이유는 측정이다(verify_litellm_token_clamp.py, LiteLLM 1.81.14): `litellm_params.max_tokens`는 더 큰 클라이언트 값을 못 낮추고, `modify_params:true`는 max_tokens만 잡고 max_completion_tokens(codex의 responses 경로!)를 놓친다. 오직 이 훅만 둘 다 낮추며, deployment 선택 후라 model_info 인지 캡이 가능하다. clamp는 **lower-only**(키 부재 시 주입하지 않음 — 예약 도입은 harness 층의 일). guardrail은 청구서 등급이 아니라 사전 차단이다($1.06짜리 단일 요청 실측 + `--max-budget-usd`가 이 경로에서 하드 리밋이 아님이 확인된 후 만들어짐). 순서는 clamp→guardrail(가드레일이 클램프 후 요청을 가격하도록). doctor는 두 정책의 `enabled:false`를 설정 선택이 아니라 **고장**으로 취급한다 — 방어층은 공격이 아니라 "임시로 꺼둔 것"으로 죽는다.

> **반론(이 층의 가장 강한 것들)**: ① guardrail 전역 200K는 Kimi의 적법한 221950 유효 입력보다 작다 — 스택이 정성껏 보존한 능력을 가드레일이 깨문다. 첫 실제 >200K 워크플로우가 나타나면 perModel 한도를 구현하라(권고 문서에 이미 스펙됨). ② 같은 예산 공식이 **세 언어에 다중 구현**되어 있다 — M5 로그가 blast-radius를 이유로 통합을 보류했고, check의 221950/3277 고정 단언이 드리프트 방지선이다. 이 서브시스템 최대의 잠재 버그원. → **이 반론은 §4a에서 갱신·일부 반박된다**: 실제 사본 수는 3이 아니라 **5개**이고(이 반론과 옛 감사가 4번째·5번째를 놓쳤다), 새 `verify_budget_consistency.py` 차분 테스트가 5개가 lockstep임을 *증명*하며 드리프트 위험을 통합의 blast-radius 없이 무력화한다. ③ 발견은 LiteLLM 1.81.14에 핀되어 있다 — 업그레이드마다 verify 스크립트를 재실행하라(스크립트의 recommended_policy는 modify_params가 충분해지면 훅 제거를 권하도록 짜여 있다: "검증되는 가장 단순한 메커니즘을 써라").

**drop_params: true** [재구성, pre-git]: N개 harness가 자기 방언(thinking/betas/effort)을 M개 백엔드에 過광고하는 구조에서, 끄면 거의 모든 라우트 조합이 400으로 하드 실패한다. 가용성-우선을 선택하고 그 비용(조용한 드롭)을 관측 가능하게 만들었다: reasoning matrix의 drop_risk 컬럼, 그리고 모델별 교정은 flag 반전이 아니라 `SUPPORTED_CAPABILITIES` 선언으로 한다(기본 미설정 — 현 동작 불변이 기록된 결정). 추론 품질이 이유 없이 낮으면 이 flag가 제1용의자다.

**관측은 증거이지 진실이 아니다** [기록]: GLM이 204800을 받은 관측과 프로바이더 공표 202752는 **둘 다 참일 수 있다**(OpenRouter는 멀티플렉서다). 그래서 관측은 `>=N`으로 표시만 하고 강제는 보수값을 유지하며, 모순되는 관측은 해소하지 않고 보존한다(F2.5 규칙). probe는 돈이 들므로 절대 자동 실행하지 않는다.

---

**결정: tool-call의 *충실도*는 fabric 책임(테스트 대상), *역량*은 모델 한계(불가항력)다 — 둘을 mock provider로 가르는 회귀 가드를 둔다.** [실증, 2026-06-15]

모델이 harness 안에서 tool을 잘못 고르거나 방황하는 것은 모델 역량 문제로 fabric이 못 고친다. 그러나 **잘 만들어진 tool_use가 LiteLLM의 Anthropic↔OpenAI 번역에서 드롭/손상/400되는 것**(알려진 LiteLLM #25321/#26395/#28045류, streaming tool-arg 손상, multi-turn reasoning_content 결손)은 우리(번역 설정의 소유자) 책임이고 **LiteLLM 버전에 취약**하다. 그래서 `verify_litellm_token_clamp.py`와 같은 자리·방식의 `scripts/verify_tool_call_fidelity.py`를 둔다: mock OpenAI provider + throwaway 실제 LiteLLM proxy로, (a) Anthropic tools/tool_use/tool_result → OpenAI 요청 형태(요청 충실도)와 (b) OpenAI tool_calls → Anthropic tool_use 블록(응답 충실도)을, 단일·멀티턴 + Claude Code가 resume 시 만드는 thinking-block 동반 케이스(#26395 트리거)까지 무비용·결정론적으로 검증한다. 2026-06-15 실측: cloud(DeepSeek/Kimi)·로컬(Qwen3.6-27B) 모두 단일·멀티턴 tool 왕복이 깨끗했다 — 즉 모델이 방황하면 그것은 모델 한계이지 fabric 결함이 아님이 *증명 가능*하다. CI 잡 `tool-fidelity`가 litellm 1.81.14 핀으로 회귀를 막는다.

> **반론**: mock은 우리 번역 계층만 격리해 친다(실제 provider의 tool-calling quirk는 `--live-model`로만). 그게 의도다 — 실 provider 호출은 과금·비결정적이라 CI에 못 넣는다. 실 백엔드 신뢰는 `--live-model` 수동 스모크가 담당한다.

---

## 4a. 예산 공식의 5중 구현 — 통합하지 않고 차분 테스트로 묶는다

**사실 정정: 출력예산/clamp 공식은 3개가 아니라 5개의 독립 사본으로 존재한다.** [실증, 2026-06-20]

§4 반론 ②와 2026-06-12 전수 감사는 "3중(Node/Ruby/Python)"이라 적었으나, 실측 결과 **5개**다. `verify_budget_consistency.py`의 헤더가 열거한다: (1) Node `ai_litellm_harness_output_budget`(lib.zsh node 블록 ≈449–515), (2) Ruby `effective_input`(codex 카탈로그 context-map, ≈543–581), (3) Ruby `output_budget`(context matrix, ≈4759–4820), (4) Python `gateway_output_cap`(`output_clamp.py`), (5) **Ruby `output_budget`(doctor 체크 `ai_litellm_context_harness_reservations_ok` 내부, ≈5622–5687)** — 옛 감사와 §4 반론이 놓친 것이 바로 이 5번째, 즉 doctor가 reservation 정합을 검사할 때 쓰는 사본이다. 공식 자체는 동일하다: reservation 선택 → 능력치 clamp → context 스케일링(headroom 0.1 / minInput 0.5) → tiny/small-window clamp → `effectiveInput=max(0, ctx−reservation−headroom)`. 1·2·3·5는 effectiveInput을, 4는 outputCap을 산출하므로 비교 가능한 필드만 정렬한다.

**결정: 5개를 통합하지 *않고*, 차분 테스트(`scripts/verify_budget_consistency.py`)로 lockstep을 강제한다.** [실증]

스크립트는 27행 입력 매트릭스를 5개 구현 *모두*에 먹여 비교 가능 필드가 동일함을 단언한다. 핵심 anti-drift 설계: 4개의 lib.zsh 사본은 테스트에 **복붙하지 않고 런타임에 lib.zsh를 줄 범위로 슬라이스해 라이브 실행**한다 — 항상 *배포된* 코드를 검사한다. 범위가 어긋나면(lib.zsh 리팩터로 줄이 밀리면) 추출 텍스트가 기대 함수를 정의하지 못해 **조용히 stale를 검사하는 게 아니라 loud-fail**한다. `python3 -m py_compile` + 실제 실행 둘 다 `scripts/check.zsh`(L27/L35)에 박혀 CI에서 돈다.

**FINDING: 5개는 lockstep이다 — 드리프트 버그는 없다.** [실증] 한때 "221950 대 3277" 불일치가 드리프트 공포로 보였으나, 둘은 *서로 다른 양*(effectiveInput 대 outputCap)이지 같은 양의 두 값이 아니었다 — 실제 모순이 아니다. check의 221950/3277 고정 단언(§8 표)은 그 두 양의 앵커를 박아 "바꾸려면 의식적 동시 수정"을 강요하는 장치로 유효하며, 이제 차분 테스트가 *전 범위*에서 정합을 본다.

> **반론**: 통합이 "정답"처럼 보이는데 왜 5개를 남기나? 세 가지가 통합을 *진다*. (1) 사본들은 서로 다른 실행 컨텍스트에 산다 — Node 배치(harness env 주입), Ruby 카탈로그(codex sync), Ruby 매트릭스(관측 표), Ruby doctor(설정 검증), Python 게이트웨이(요청별 훅). 하나의 공유 모듈로 묶으면 그 컨텍스트들이 한 의존성을 공유하게 되고, 이는 §4 반론 ②가 경계한 blast-radius다(게이트웨이 훅 한 줄 버그가 doctor·sync·배치를 동시에 깬다). (2) 차분 테스트는 통합이 막으려던 위험(드리프트)을 *이미* 무력화한다 — 통합의 유일한 추가 이득은 LOC 감소뿐이고, 그 대가가 결합도 상승이다. (3) "검증되는 가장 단순한 메커니즘"(§4 ③의 원칙)은 여기선 *테스트*이지 리팩터가 아니다. **전제 감시**: 차분 테스트가 비-vacuous함(슬라이스가 실제로 함수를 정의하고 27행이 분기를 덮음)은 검증됐으나, 6번째 사본이 추가되면 테스트는 *자동으로 알지 못한다* — 새 예산 산술을 쓰는 사람이 매트릭스에 등록할 책임이 있다. 사본 추가 시 verify 스크립트 등록을 잊으면 이 보호는 그 사본을 덮지 못한다.

## 5. 시크릿 계층

| 계층 | 보관처 | 흐름 | 강제 |
|---|---|---|---|
| 라우팅/프로바이더 키 (OpenRouter, LiteLLM master, 향후 provider) | Keychain (`ai-litellm key set --keychain`; env 파일은 포터블 폴백) | per-invocation 주입. proxy 모드의 자식은 master key만 본다 — provider 키는 proxy 프로세스에만 존재하므로 **세션 안의 에이전트가 자기 env에서 provider 키를 읽을 수 없다** | lint가 공유 settings 유입을 hard-fail; check가 `$(touch PWNED)` 주입 공격을 단언; repo 전체 키-형태 grep |
| 세션 도구 키 (Bash에서 curl로 쓰는 Brave 등) | **Keychain이 정본** (openclaw 소비 키는 service `"OpenClaw SecretRef"` / account `openclaw/...` 네임스페이스) | 세션 내 사용은 on-demand lookup: `security find-generic-password -a <id> -s "OpenClaw SecretRef" -w`; openclaw은 자체 resolver로 동일 항목을 읽음 — **한 항목, 두 소비자** | scrub/lint 의도적 통과 |
| (예외 채널) process env로만 전달 가능한 도구 키 | 공유 `~/.claude/settings.json` env 블록 — **2026-06-12 이후 기본적으로 비어 있음** | symlink로 양 변형 자동 공유 → Object.assign → Bash 상속 ([실증]) | lint가 라우팅 키만 차단; 평문 디스크 비용을 아는 키만 여기 둘 것 |
| 외부 시스템 (openclaw 등) | 각자 설정; Keychain source 패턴 권장 | 비공유 | — |

설계 원칙(2026-06-12 키 통일 이후): **모든 키의 정본은 Keychain이다.** Brave 사례 — 한때 openclaw.json 인라인 + `~/.claude/settings.json` env 블록에 같은 값이 평문 2중 보관되어 있었고, 이것이 "이 키가 왜 여기 있고 어디에 흐르는지 불확실한" 경험의 발원지였다. 둘 다 keychain 단일 항목(`openclaw/plugins/brave/web-search-api-key`)으로 통합했다: openclaw은 resolver로, Claude 세션은 security lookup으로 같은 항목을 읽는다. Claude Code 자체는 Brave 키를 모른다(바이너리에 참조 없음 — 소비자는 Bash curl 패턴이다). settings env 블록은 예외 채널로만 남는다 — process env로만 전달 가능한 키가 생기면 평문 비용을 인지하고 사용하되, 비-Anthropic 모델 세션 노출(그래서 권한 하향이 존재)도 함께 인지하라. master key가 env 파일에 생성될 수 있는 것은 첫 실행 UX를 위한 폴백이고(현재 이 머신은 keychain만 사용, env 파일 부재), localhost:4000에만 유효한 로컬 자격증명이라 수용했다.

---

## 6. harness 비대칭의 이유

네 harness가 네 가지 다른 격리 전략을 쓰는 것은 비일관성이 아니라 **각 CLI의 설정 표면이 강제한 결과**다.

- **claude — 공유 환경 + 격리 세션** (§2): config dir가 알갱이 단위라 symlink 절단선이 가능했다.
- **codex — 완전 격리 CODEX_HOME.** [기록] 세 가지가 claude식 처리를 막는다: CODEX_HOME이 monolithic(세션/메모리/설정이 한 뿌리 — 알갱이 절단 불가), memories sqlite에 provider 컬럼이 없음(약한 모델 메모리를 사후 필터링 불가), generator가 config.toml을 통째 교체(공유 시 native 파괴). 미래 경로는 profile-v2인데, codex 0.138.0에서 **미명시 키가 native의 `approval=never`/`danger-full-access`를 상속하는 함정이 실증**되어 있다 — profile 파일은 approval_policy/sandbox_mode/model_catalog_json을 반드시 명시해야 한다. 생성 config가 on-request/workspace-write/home-untrusted로 고정되는 것은 같은 원칙(약한·미지 모델은 관대한 모드를 상속받지 않는다)의 codex 버전이다. `shell_environment_policy inherit="core"`는 모델이 실행하는 셸 명령이 master key를 못 읽게 하는 장치다.
- **goose — retired 2026-06-28.** [기록] 이전 env-injector shim은 지원 대상에서 제외했다. 현 설치/제거 스크립트는 기존 설치본의 shim, descriptor, state를 지우는 legacy cleanup만 유지한다.
- **opencode — OPENCODE_CONFIG 파일 포인터 + XDG 리디렉션.** [기록] config 경로를 env로 받으므로 생성 파일이 native 트리 밖에 있으면 끝. per-model limit 블록은 opencode의 32000 절단 기본값을 교정한다.

---

## 6a. fabric 대시보드: read-then-act 컨트롤 플레인

**fabric**(= `ai-litellm dash`)은 ai-litellm CLI 위의 Textual TUI 컨트롤 플레인이다(`config/ai-litellm/fabric_dash/`). 그 설계 결정들은 모두 하나의 명제에서 파생된다: **TUI는 CLI의 *관측*이지 CLI 로직의 *재구현*이 아니다.**

**결정: read-then-act 분리 — 기본은 read-only, mutating 액션은 확인 모달로 게이트한다. 중단성(RESTART)·파괴적(DESTRUCTIVE)·과금성(BILLABLE) 등급은 모두 Cancel-우선 ConfirmModal이다(billable launch도 PR #2 경화에서 Cancel-우선으로 통일 — `_GUARDED`에 셋 다 포함).** [실증]

`safety.classify(argv)`(`safety.py`)가 액션을 4계급으로 가른다: `SAFE`(start/doctor/read-only router plan/explain/dry-run — 자유 실행), `RESTART`, `BILLABLE`, `DESTRUCTIVE`. `ACTIONS` 테이블에서 SAFE인 start/doctor는 `needs_confirm=False`로 바로 돌고, sync/restart/stop은 `RESTART`로 ConfirmModal 뒤에 선다. Router execute와 harness launch는 BILLABLE gate를 탄다. 자동 갱신(auto-refresh)은 **엄격히 read-only**다 — 화면을 새로 그리는 폴링이 절대 mutating 명령을 부르지 않는다. 그 분리의 강제 지점은 `FabricClient`(`client.py`)가 *읽기/plan 표면만* 노출한다는 것이다: `proxy_status`/`model_list`/`harness_list`/`reasoning_matrix`/`router_plan` 등 `--json` read/plan 명령만 메서드로 있고(`route_list`/`context_matrix`는 round-1 리뷰에서 죽은 코드로 제거), 실행 측은 별도 `ActionRunner`(`actions.py`)에 격리됐다. 안전 기본값은 *구조*로 보장된다 — read 경로에는 실행 메서드가 없다.

**결정: `FabricClient`는 실패 시 traceback이 아니라 빈 컨테이너를 반환한다(empty-on-failure), runner는 주입 가능하다.** [실증]

`client.py` 헤더가 명시: "returns an empty container so the TUI shows 'empty', never a traceback." `_obj`/`_arr`이 `except Exception: return {}`/`return []`로 감싸 CLI가 죽거나 비-JSON을 뱉어도 패널이 "비어 있음"으로 graceful하게 표시된다. runner(`__init__(self, runner=None, ...)`)가 주입 가능한 덕에 대시 테스트 일체가 실제 CLI 없이 가짜 응답으로 전 패널·전 액션을 결정론적으로 돈다(`make_client_with({...})` 패턴, `tests/test_{app,actions_app,client,safety}.py`).

**결정: 대시보드는 패키지 소유 venv(`$AI_LITELLM_STATE_HOME/dash-venv`)에 격리된다.** [기록]

`bin/fabric` shim → `ai-litellm dash` 디스패치 → `"$AI_LITELLM_STATE_HOME/dash-venv/bin/python" -m fabric_dash`(lib.zsh L6180). install.zsh의 `ensure_dash_venv`(L367–)가 `$prefix/state/dash-venv`에 venv를 만들고 textual을 pip-install한다. 별도 venv인 이유는 PEP-668(externally-managed) 환경에서 시스템 파이썬에 textual을 함부로 설치할 수 없고, 대시보드는 ai-litellm의 zsh 코어와 의존성을 공유할 이유가 없기 때문이다 — TUI 의존성이 코어를 오염시키지 않는다. venv 빌드는 네트워크·느림이므로 `AI_LITELLM_SKIP_DASH_VENV`(check.zsh가 설정 — L63 등)로 게이트되어 구조 검사/CI는 빠르고 오프라인으로 돈다.

**결정: harness launch는 터미널을 넘겨준다(`os.execvp`).** [기록] `__main__.py` L22: `os.execvp("ai-litellm", ["ai-litellm", "harness", "launch", harness])` — TUI가 살아서 자식을 감싸는 게 아니라, *exec로 자기를 대체*해 터미널 제어권을 harness에 완전히 양도한다. 대시보드는 launcher이지 supervisor가 아니다.

**결정: `--json` read API는 output-FORMATTER-ONLY다 — 상태를 절대 재유도하지 않는다.** [실증]

TUI가 소비하는 계약(proxy status, model list/limits, route list, runtime status, reasoning/context matrix, harness list/info, key status가 `--json` 획득)은 *형식 변환 계층*일 뿐이다: 기존 텍스트 출력과 동일한 소스에서 camelCase JSON을 방출하되 백엔드 로직은 한 줄도 안 건든다(default 텍스트 출력은 byte-identical 유지). lib.zsh의 형제 `*_json` emitter들(`ai_litellm_status_json` L2255 등)과 `ai_litellm_emit_json` 헬퍼(L96 — argv 쌍을 `@num:`/`@bool:`/`@null` 마커로 타입화해 JSON 직렬화)가 구현한다. 매트릭스(reasoning/context)는 코드를 복제하는 대신 `AI_LITELLM_MATRIX_JSON` env 플래그로 **기존 Ruby가 JSON을 방출**하게 해 단일 진실원을 지킨다. 읽을 수 없는 소스는 `{}`/`[]`를 주고 exit 0 — client.py의 empty-on-failure와 짝을 이룬다. read-only 명령에만 붙는다.

**결정: 품질 보증은 Textual `run_test()` 파일럿으로 *렌더된* 위젯 트리를 검증한다(SVG 스냅샷 diff 아님).** [실증]

테스트는 `async with app.run_test() as pilot`로 실제 앱을 띄워 `pilot.press(...)`/`show_panel(...)` 후 렌더 결과를 단언한다 — 예: `query_one("#status").content`에 "claude"가 있는지, Models/Router 패널이 텍스트 래핑이 아니라 진짜 `DataTable`을 렌더하는지(`test_app.py`), 잘못된 harness 셀이 회색이 아니라 빨강으로 신호하는지, router dry-run/execute prompt가 argv가 아니라 stdin으로만 흐르는지. 즉 "스냅샷 리뷰"는 *렌더된 출력*을 검사하는 것이지 SVG 이미지 비교 회귀(pytest-textual-snapshot류)가 아니다. 이 루프로 외부 UX 리뷰어의 화면 품질 리뷰 점수 90을 통과시켰다. 이 90은 Router 후보의 내부 `score`가 아니다. CI 잡 `dash-tests`(커밋 690c009)가 textual을 프로비저닝하고 이 테스트를 돌려 대시보드 회귀가 *조용히* CI를 통과하지 못하게 막는다 — venv가 없으면 check.zsh는 모듈 임포트 검사를 skip하므로(L78–83), CI의 전용 잡이 그 빈틈을 메운다.

**결정: Router 패널은 internal score를 숨기고, 현재 intent와 highlighted route를 실행 의미에 연결한다.** [실증, 2026-06-29]

`router_core`의 `score`는 품질 점수도 성공 확률도 아니라 후보 정렬용 내부 휴리스틱이다(기본 50점에 context headroom, local/non-billable, 기본 Claude opus, preferred harness/model 등을 더한다). 이를 TUI primary table에 `Score`로 노출하면 사용자는 "모델 품질 90점"으로 읽기 쉽다. 또 `reasons`/`risks`는 판단 근거로는 필요하지만 후보 비교 표에 넣으면 가장 긴 문장이 화면을 지배해 harness/model/provider/local/billable/effectiveInput 같은 식별 정보를 밀어낸다. 그래서 Router table은 `chosen/harness/model/provider/local/billable/effectiveInput`만 보여주고, 현재 계획의 조건은 `panel-note`에 `intent: no-billable`, `estimated input`, `selected <harness> <model>`로, 선택 행의 판단 근거는 `panel-detail`의 `why`/`risks` 2줄로 별도 표시한다.

또 행을 고른 뒤 `t`/`E`를 누르면 그 행이 실행될 것이라는 기대가 자연스럽다. 이전 구현은 row highlight를 실행 intent에 반영하지 않고 새 modal 입력으로 재계획했기 때문에 오해 가능성이 컸다. 현재는 highlighted route와 RowSelected(마우스 클릭/Enter)를 같은 `_select_router_row` 경로에 연결하고, 그 route를 `preferred-harness`/`preferred-model`로 modal 기본값에 넣어 `p`/`v`/`t`/`E`가 모두 같은 선택 의미를 공유한다. `test_router_panel_renders_default_plan_candidates`는 `Score`/`Reasons`/`Risks` 컬럼 부재와 intent/detail note를, `test_router_row_selection_seeds_execute_intent`는 선택 row가 dry-run argv로 흘러가는 것을, `test_router_row_mouse_click_updates_detail_and_intent`는 실제 DataTable 클릭이 detail과 intent를 갱신하는 것을 고정한다.

**결정: command palette는 `:` 하나만 남기고, raw Router commands는 제외한다.** [실증, 2026-06-29]

Palette는 discovery/escape hatch로는 유용하지만, Router에는 이미 typed modal이 있다. Raw `router plan/explain/execute`를 palette에 남기면 prompt/stdin, billable intent, row selection 의미가 분산되고, 사람이 기대하는 "선택한 row를 실행" 모델과 충돌한다. 따라서 Router는 Router 패널 action(`p`/`v`/`t`/`E`)이 정본이고, palette registry는 router group을 제외한다. `ctrl+p` alias도 제거했다. Textual 내장 command palette와의 충돌 회피 때문에 `ENABLE_COMMAND_PALETTE=False`는 유지하되, 실제 사용자 단축키는 `:`만 문서화한다. Results log도 초기에는 접어 두고, `_write_result`/`_run_argv`가 실제 출력이 생길 때만 펼친다. 이 변경의 원칙은 기능을 숨기는 것이 아니라, 이유를 설명할 수 없는 표면을 줄이는 것이다.

> **반론**: ① read/act 분리는 *구조적*으로 안전하나, ConfirmModal의 Cancel-우선이 막는 건 "오발"이지 "악의"가 아니다 — 자동 갱신이 read-only라는 보장은 client.py에 mutate 메서드가 없다는 사실에 의존하므로, 누군가 client에 실행 메서드를 추가하면 그 불변식이 코드 리뷰에서만 지켜진다(테스트가 "auto-refresh는 mutate 안 함"을 직접 단언하는지는 미확인 — 의심되면 추가하라). ② `run_test` 검증은 *우리 렌더 로직*을 친다 — 실제 터미널의 폰트·색·리사이즈 깨짐은 잡지 못한다(SVG 스냅샷이라면 잡았을 부류). UX 리뷰어 점검이 그 갭을 사람 눈으로 메웠으나, 그건 회귀 가드가 아니라 1회성이다. ③ 패키지 소유 venv는 textual 버전을 핀하지 않으면 드리프트한다 — 테스트가 `textual 8.2.7`의 `.content` API에 주석으로 의존(`test_app.py` L271)하므로, textual 메이저 업그레이드는 재검증 대상이다.

---

## 7. 설치/검증 철학

**copy-and-render 패키지 (symlink 농장 금지)** [기록+재구성]: 네 가지가 겹친다 — ① JSON/TOML은 env 확장이 없어 절대 경로가 렌더 시점에 박혀야 한다(`__HOME__`/`__FABRIC_HOME__`), ② 패키지는 checkout 사후 생존해야 한다(uninstall.zsh를 패키지 안에 복사), ③ 설치본은 가변 런타임 상태다(`reasoning set`이 descriptor를 수정 — symlink면 git checkout에 쓰게 됨), ④ state가 prefix 안에 산다. 한때 repo 루트에 생기던 `__FABRIC_HOME__/` 디렉토리가 렌더 없이 checkout에서 wrapper를 실행하면 무슨 일이 나는지의 물증이었다(지금은 제거·gitignore했고 `ai_litellm_assert_rendered_path` 가드가 재발을 막는다 — 아래 §11). 멱등성+변경 시 백업(`cmp -s` 동일이면 무백업 — check가 "동일 재설치 시 백업 0"을 단언).

**check.zsh = 집행 척추**: 일회용 mktemp HOME에 **진짜 설치**를 수행하고 마지막에 `~/.claude`/`~/.codex`가 생성되지 않았음을 단언한다 — 경계 계약을 개발자의 실제 native 설치를 위험에 빠뜨리지 않고 매 CI에서 검증. master key 소스를 의도적으로 눈멀게 해(LITELLM_MASTER_KEY= + 미스 보장 keychain 계정) 자동 생성 경로를 결정론적으로 태운다. stub claude 패턴: wrapper의 산출물은 자식 프로세스가 받는 env+argv 계약이므로, 그 계약 자체를 echo로 관측한다(네트워크/과금/실바이너리 불요). **`set -e` 사건**: 내부 `zsh -fc` 블록은 마지막 명령의 종료코드만 전파하므로, d1c4edd 이전의 모든 중간 단언은 조용히 무효였다 — 모든 green run이 보이는 것보다 적게 증명하고 있었다. 적대적 테스트: PWNED 주입(시크릿이 어느 층에서도 셸 평가되지 않음), 외부 pid 보호(pid 파일의 프로세스가 litellm이어야만 신뢰 — pid 재활용 시 무고한 프로세스 kill 방지), 공백 포함 prefix 전체 수명주기.

> **반론**: 단일 순차 스크립트는 첫 실패가 나머지를 가리고, claude만 stub이 있다(codex/opencode 런치 계약은 간접 검증) — stub 패턴 확장이 자명한 다음 투자다.

---

## 8. 불변식 → 강제 장치 매핑 (수정 제한 권고)

"이건 수정 제한을 하는 게 낫겠는데?"에 대한 현황표. **강제됨**은 깨면 check/doctor가 빨갛게 된다는 뜻이고, **무방비**는 조용히 깨진다는 뜻이다.

| 불변식 | 강제 |
|---|---|
| 앵커 참조 강제(인라인 model_info 금지, 관리 블록 제외) | ✅ doctor + check |
| 기본 모드/디스패치/alias 해석/wire-strip | ✅ check |
| 모델 선택 계약: unresolvable proxy positional은 loud-error(프롬프트 누출 금지) — §3 | ✅ check (06-13 추가; dispatcher stub 블록의 비-vacuous 단언) |
| 발견 라우트 litellmParamsOverrides glob 주입(thinking-off 등) — §3 | ✅ check (06-13 추가; temp-settings 오버레이로 매칭/비매칭 검증) |
| tool-call 번역 충실도(Anthropic↔OpenAI, 단일/멀티턴/thinking-resume) — §4 | ✅ verify_tool_call_fidelity.py + CI `tool-fidelity` 잡 (litellm 1.81.14 핀) |
| 공유 settings env 라우팅 키 금지 | ✅ launch lint + check |
| 양 오버레이의 defaultMode=default **렌더 기본값** (라이브 오버레이의 운영자 상향은 사양임 — §2) | ✅ check (06-12 추가; throwaway HOME의 신규 렌더만 검사) |
| symlink 존재·대상·`~/.claude` 비생성·멱등 | ✅ check |
| 예약 수치(221950/3277) 고정 + 예산 공식 5중 구현 lockstep — §4a | ✅ check (수치 고정 + `verify_budget_consistency.py` 차분 테스트가 5사본을 라이브 슬라이스해 정합 단언) |
| 대시보드 회귀(read-only 패널·액션 안전 분류) — §6a | ✅ CI `dash-tests` 잡 (venv+textual 프로비저닝, `run_test` 파일럿 테스트 일체; check.zsh는 venv 부재 시 skip) |
| gateway 정책 enabled=true | ✅ doctor ("must stay true") |
| codex 카탈로그 신선도 | ✅ doctor limit-sync |
| dedup(빈 출력 단언 — 네이밍 변경에 면역) | ✅ check (06-12 수정: 종전 단언은 옛 이름을 검사해 무효였음) |
| 발견 실패는 발견 라우트를 wipe하지 않는다(parse-fail rc≠0 → loud-skip, 보존) — §9 | ✅ check (06-15 추가; reachable-but-garbage mock으로 보존 단언) |
| 동시 sync 거부(별도 sync mutex, restart의 proxy lock과 데드락 없음) | ✅ check (06-15 추가; held-lock 시 즉시 loud 거부) |
| codex 세션 실행 pre-flight(바이너리 미기동 시 무한행 대신 loud-fail) | ✅ check (06-15 추가; hang stub→timeout+loud, instant stub→pass) |
| 경계 계약(native 디렉토리 비생성, 시크릿 비평가, uninstall prefix 안전) | ✅ check |
| **scrub 실효성**(scrub된 var가 자식 env에서 실제로 사라지는지) | ⚠️ 무방비 — codex/opencode용 stub 테스트 권고 |
| **harness 예약 ↔ gateway clamp 수치 정렬** | ⚠️ 무방비 — doctor warn 권고 (주석으로만 선언됨) |
| **codex 생성 config의 안전 키 존재**(approval/sandbox/trust) | ⚠️ 무방비 — 렌더 결과 grep 권고 |
| **앵커 ↔ modelInfoOverrides 동족 글롭 수치 일치** | ⚠️ 무방비 — 저위험, doctor warn 후보 |
| **lint denylist의 신선도**(새 라우팅 env) | ⚠️ 구조적 한계 — claude 업그레이드 시 수동 재점검 |
| general_settings 위치(생성 블록 삽입 landmark) | ⚠️ 실패는 loud — yaml 주석으로 선언 |

생성물 표식: codex config.toml/model-catalog.json, opencode.json, discovered routes 블록은 **손편집 금지**다(매 런치/sync에 전량 재생성). discovered 블록은 BEGIN/END 마커와 배너가 있고, codex config.toml에도 생성 배너 추가를 권고한다(§10).

---

## 8b. 견고성 감사 (2026-06-15): fail-loud-not-silent + 동시성

아키텍처 안정성 관점의 견고성 감사(degraded 조건이 조용히 잘못 서빙하지 않고 loud 실패하는가 + 공유상태 경쟁)에서 **실증으로 확인해 고친 것**:

- **발견 실패의 silent 라우트 wipe (실버그, 수정)** — `ai_litellm_runtime_routes_refresh`가 `available_models`의 종료코드를 버려, 런타임이 reachable이지만 `/v1/models`가 파싱 불가 200을 줄 때 빈 목록을 `routes_write`에 넘겨 **발견 라우트를 통째로 조용히 삭제**했다(mock garbage 200으로 재현: 기존 라우트 1→0, "0 discovered"만 출력). 수정: 발견 실패(rc≠0)와 진짜 0개를 구분해, 실패 시 loud-skip + 기존 라우트 보존. unreachable/timeout은 이미 reachable 체크로 loud-skip됨(감사의 timeout 주장은 부정확).
- **동시 sync 경쟁 (수정)** — `ai_litellm_start`엔 lock이 있으나 `ai_litellm_sync`엔 없어 두 sync가 다중 파일 재작성을 교차할 수 있었다(파일별 atomic tmp+rename은 reader의 half-file은 막지만 cross-file 불일치+이중 restart는 아님). proxy-start lock을 재사용하면 sync→restart→start가 데드락이므로, **전용 sync mutex**(non-blocking: 두 번째 sync는 loud 거부, dead-holder reclaim, 단일 종료점 release)를 추가했다. reclaim 판정은 `kill -0`(생존)와 age(`started_at` mtime, pid 재활용 안전) 둘 다 본다 — 회귀 테스트 작성 중 발견: `started_at`이 없는 **torn lock**(pid는 썼으나 started_at 직전에 죽거나 acquire 중)에서 `perl stat`이 빈 리스트→`time-undef`=전체 epoch을 줘 age가 max를 무조건 초과, 살아있는 holder를 잘못 reclaim했다. 미존재 stat은 age=0으로 읽어 `kill -0` 생존 체크가 판정하도록 고침.
- **고아 tmp 정리 (위생)** — atomic rename 패턴 자체는 안전(중단돼도 config 무손상)하나 중단된 sync가 `*.tmp.$$`를 남긴다. sync 시작에서 sweep.
- **codex 세션 실행 pre-flight (06-15 codex 사건 후속, 수정)** — sync 카탈로그 프로브는 timeout으로 감쌌으나(위 Fix D) **대화형 세션 실행 경로(`_codex_litellm_run_codex`)는 무방비**였다 — codex 바이너리가 안 뜨면(예: macOS Tahoe dyld 행, openai/codex#23802; 실측 0.139 `--version`이 pre-main `_dyld_start`에서 무한행) loud 에러도 없이 영원히 대기. exec 직전 bounded `codex --version` pre-flight(`AI_LITELLM_CODEX_PREFLIGHT_TIMEOUT:-10`)를 넣어 미기동 시 actionable loud-fail. 정상 바이너리는 ~0s라 비용 없음. 세션 실행은 timeout으로 감싸면 정상 긴 세션도 죽으니 **실행 자체가 아니라 startup 생사만** 본다. (해당 머신은 `~/.local/bin/codex`→앱 내장 0.140 심링크로 별도 해결.)

**의식적으로 수용한 이론적 윈도우(단일 사용자 머신 기준, 미수정)**: pid/config-hash/started_at 파일의 bare-redirect 쓰기(start의 lock 하에서만 쓰므로 실질 경쟁 없음); proxy `/model/info`가 health는 통과하나 garbage를 줄 때 "run sync" 메시지가 약간 오도(여전히 actionable); 두 동시 claude-litellm launch의 overlay-render `.$$`(서로 다른 PID라 충돌 없음). 다중 사용자/CI 동시성으로 가면 flock 기반 강화가 다음 단계.

## 9. 근거 불명·미해결·단순화 후보 (정직한 목록)

감사가 "방어 가능한 근거 없음" 또는 "기록 없음"으로 판정한 것들. 합리화하지 않고 그대로 둔다 — **이 목록의 항목을 지우는 올바른 방법은 측정하거나, 기록하거나, 단순화하는 것이다.**

1. **tokenizerHeadroom=8192** — 기능(하니스↔프로바이더 토크나이저 오차 패드)은 구조적으로 필요함이 입증됐지만(Kimi 경계 ±1 토큰에서 200↔400 실측), **수치 8192는 측정 없는 2^13 라운드 넘버**다. 절대값이라 보호율도 비일관(Kimi ~3.6%, DeepSeek 1M ~0.8%). 예산 내 경계 400이 한 번이라도 나면 그 관측으로 재유도하라.
2. **소형 윈도우 스케일링 10%/50%** — 목적(정책 상수가 8K 윈도우를 잡아먹지 않게)은 명확하나 비율 자체는 미측정.
3. **subagentModel이 direct 전용** — 출생(8a507e1: main=sonnet, subagent=opus 품질 핀) 후 proxy로 이식되지 않았다. 바이너리 분석 결과 proxy에서 핀 부재는 사실상 옳다(미핀 subagent는 main 모델을 상속하며, 핀은 세션의 /model·로컬 tier 선택을 짓밟는 전역 override다). 현 기본값에서는 no-op이기도 하다. 의도였는지는 미기록 — 현 상태로 두되 주석으로 범위를 선언했다.
4. **CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK가 direct 전용** — OpenRouter 레시피의 일부로 재구성되나 proxy 부재의 이유는 미확인.
5. **gpt-5.4-mini가 카탈로그 클론 베이스인 이유** — "가장 중립적인 소형 템플릿"으로 추정될 뿐 기록 없음. 번들에서 사라지면 models[0] 폴백이 놀라운 기본값을 가질 수 있다.
6. **harness별 기본 모델 분배(codex=DeepSeek+xhigh, opencode=Kimi)** — codex만 reasoning-effort 레버가 있어 최강 추론 백엔드와 짝지은 것으로 재구성되나, 정확한 가중(비용? eval?)은 미기록. 다음에 만질 때 기록하라.
7. **shell.zsh의 하드코딩 폴백들**(env 이름, tier 목록, 모드별 default의 화석화된 opus/sonnet 종단) — descriptor가 검증 필수라 건강한 설치에서 도달 불가능한 사실상 죽은 코드. loud-fail로 교체가 방어 가능한 정리다.
8. **deprecated alias 테이블에 일몰 기준이 없다** — 무해하나 영생할 것이다.
9. **availabilityNux** — 의미는 상류 소스로 확정(모델 광고 툴팁의 표시 횟수 카운터, 상한 4). 값 3은 작성자의 라이브 카운터 복사로 추정되며 **기능적으로 틀려서**(3<4 + 매 런치 재렌더로 증분 소실 → 툴팁 매번 재출현) 4로 수정했다(06-12).
10. **nvm 부트스트랩 비대칭** — 드리프트로 판정(npm 배포 CLI 시대의 잔재). PATH-최소 컨텍스트에서 opencode가 hard-fail하고 key-status가 **조용히 "키 없음"으로 오보고**하던 것을 shim 통일로 수정했다(06-12).
11. **`__FABRIC_HOME__/` 리터럴 디렉토리 풋건 (해결)** — checkout에서 wrapper를 직접 실행하면 미렌더 경로에 상태를 쓰던 풋건. 이제 `ai_litellm_assert_rendered_path`가 descriptor 파생 mkdir(isolation home, Claude settings dir, shared-env dir, opencode config·XDG home) 직전에 해석된 경로의 placeholder를 잡아 loud-fail하고, `.gitignore`가 잔재를 가리며, check.zsh가 회귀를 단언한다. 가드의 마커는 install.zsh의 렌더가 가드 자신을 치환하지 못하도록 조각으로 조립한다.
12. **관측의 무기한 표시** — 2026년의 lower bound가 2027년에도 신뢰를 빌려준다. 프로바이더 믹스가 유동적이 되면 타임스탬프 표시/노화를 고려하라.

---

## 10. 반론 초대 (전제 감시 목록)

각 결정이 의존하는 전제와, 그것이 바뀌었을 때 열어야 할 문:

| 전제 | 깨지면 재론할 결정 |
|---|---|
| OpenRouter Anthropic skin의 tool-calling 미검증 | direct 보조 경로 지위 (검증되면 승격 또는 듀얼 모드 자체의 단순화) |
| LiteLLM 1.81.14의 clamp 결함 | C4 커스텀 훅 (verify가 modify_params 충분을 보고하면 훅 제거) |
| codex의 카탈로그 검증 + profile-v2 상속 함정 | codex facade 네이밍, CODEX_HOME 완전 격리 |
| codex가 로그아웃 상태에서 ACTIVE 카탈로그를 노출하지 않음 (§3/§2a) | codex facade=번들 슬러그 제약, active-only(`gpt-5.3-codex-spark`) 사용 불가, track-4(native 카탈로그 소싱) 기각 |
| `ANTHROPIC_DEFAULT_FABLE_MODEL`이 Claude Code 네이티브 env임 (§1) | fable의 4번째 일급 tier 지위 (env가 무시되면 fable은 다른 tier로 폴백) |
| claude 바이너리의 `^(claude\|anthropic)` picker 필터 | discovery 휴면 (필터 완화 시 picker가 갑자기 채워짐 — 양성이나 놀람) |
| 미인식 모델 id = 200K 윈도우 믿음 | tier 간접화의 근거 일부, AUTO_COMPACT 주입 수치 |
| 단일 사용자 로컬 머신 | pid 지문의 관대함(`*litellm*`), guardrail의 전역 단일 한도, 콜백의 요청당 YAML 재파싱 |
| 런타임 1개(omlx) | 런타임 kind 기계의 사변적 일반성, 반쯤-다운된 멀티런타임의 stale 블록 보존 |
| OpenRouter가 id 어휘를 유지 | direct wire-strip의 단일 리터럴 접두사 |

---

*이 문서를 갱신하는 규칙: 결정을 바꾸면 해당 절의 전제·반론을 함께 갱신하고, 새 "근거 불명"을 만들지 말 것 — 만들었다면 §9에 자수하라. 날짜 있는 사건 기록은 아키텍처 문서의 결정 로그가 정본이고, 이 문서는 그 로그들의 "왜"를 종합한 살아있는 뷰다.*
