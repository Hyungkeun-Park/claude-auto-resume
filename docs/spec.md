# Rate Limit Auto-Resume Spec

## Overview

Claude Code에서 rate limit 100%에 도달했을 때, 리셋 시점에 자동으로 세션을 재개하는 시스템.
밤새 자율 작업 (ralph-loop, omc:ralph 등)을 중단 없이 가능하게 하는 것이 목표.

## Problem Statement

- Claude Pro/Max 구독은 5시간/7일 rolling window rate limit이 존재
- Rate limit 도달 시 사용자가 수동으로 대기 후 재개해야 함
- 야간 자율 작업 (ralph-loop 등) 시 rate limit으로 작업이 중단되면 방치됨

## Key Technical Facts (모두 검증 완료)

### Rate Limit Data

- **Statusline JSON이 유일한 rate limit 데이터 소스** (hook input에는 포함되지 않음)
- **100% 도달 후에도 statusline은 정상적으로 rate_limits 데이터를 전달** (trace 로그로 검증 완료)
- Statusline JSON 구조:
  ```json
  {
    "rate_limits": {
      "five_hour": { "used_percentage": 100, "resets_at": 1777662000 },
      "seven_day": { "used_percentage": 57, "resets_at": 1777856400 }
    }
  }
  ```

### API 동작

- 한 번 수락된 API 요청은 끝까지 완료됨 (mid-stream cutoff 없음)
- Rate limit은 다음 요청의 진입 시점에서 체크
- 즉, 99%에서 큰 요청을 해도 해당 요청은 완전히 처리됨

### 추가 사용량 (Overage)

- 추가 사용량이 ON이면 rate limit 100%에서도 세션이 멈추지 않음
- 추가 사용량이 OFF이면 100% 도달 시 "You've hit your limit" 표시 후 세션 멈춤
- 새 세션에서도 100% 상태면 Claude Code가 자체적으로 차단

### Rate Limit 클라이언트 차단 시점

**차단은 항상 "hooks 이후, API 호출 직전"에 발생:**

```
프롬프트 입력 (유저 or hook 주입)
    ↓
UserPromptSubmit hooks (유저 입력일 때만)
    ↓
Stop hook exit 2 continuation (루프일 때)
    ↓
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ▶ Claude Code 클라이언트 rate limit 체크  ◀   ← 여기서 차단
━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    ↓ (통과 시)
API 호출
    ↓
응답 수신
    ↓
Stop hooks
```

- 유저가 직접 프롬프트를 보내든, ralph의 Stop hook exit 2로 주입되든 동일한 지점에서 차단
- **차단 이후에는 어떤 hook도 fire되지 않음** → 차단 이전에 스케줄이 존재해야 함
- StopFailure는 **API 에러**에만 반응, 클라이언트 단 차단에는 fire 안 됨 (실환경 검증 완료)

### Session Resume

- `claude -p --resume <session-id> "prompt"` 로 headless 재개 가능
- `-p` 모드: TTY 없이 동작 (nohup 환경에서 검증 완료), 1턴 실행 후 종료
- Transcript JSONL에서 대화 히스토리 완전 복원

### 루프 동작 원리

#### 일반 세션

```
프롬프트 → UserPromptSubmit → (rate limit) → API → 응답 → Stop (exit 0) → 끝
```

#### Ralph 루프

```
프롬프트 → UserPromptSubmit → (rate limit) → API → 응답 → Stop (ralph exit 2)
                                                              ↓
                                                        (rate limit) → API → 응답 → Stop (ralph exit 2)
                                                                                          ↓
                                                                                        ...
                                                                                    promise 감지 → Stop (exit 0) → 끝
```

- Ralph의 루프는 **Stop hook exit 2**가 전부. 첫 턴 이후 UserPromptSubmit을 거치지 않음
- Stop hook에 여러 hook이 등록되면 전부 실행. 하나라도 exit 2면 세션 계속
- 각 hook은 독립 실행 — **다른 hook의 exit code를 알 수 없음**
- `/ralph-loop`과 `/oh-my-claudecode:ralph` 모두 파일 기반 상태, resume 시 자동 재개

## Overuse Detection (v4)

### 문제

추가 사용량(Overuse) ON 상태에서 rate 100%여도 세션이 계속 동작하지만, hook은 rate 100%만 보고 스케줄을 생성/유지하여 불필요한 resume이 발생.

### 핵심 원리

> **rate=100%에서 생성된 session.json을 Stop이 다시 마주하면 = 턴이 성공함 = overuse → 삭제**

Client-side 체크를 통과해서 턴이 완료됐다는 건, overuse가 켜져 있다는 증거. 안 켜져 있으면 client가 막았을 것.

### session.json 확장 필드

| 필드 | 설명 | 용도 |
|------|------|------|
| `created_at_rate` | 생성 시점의 rate % (max of five_hour, seven_day) | Overuse 감지 기준값 |
| `source` | 생성한 hook (`user_prompt`, `stop`, `subagent_stop`, `stop_failure`) | StopFailure 잠금용 |

### Hook 동작 변경

| Hook | 기존 | 변경 |
|------|------|------|
| **UserPromptSubmit** | 100% → 생성 | 100% → 생성 (`created_at_rate`, `source: user_prompt` 추가) |
| **Stop** | 100% → 생성/유지 | 100% + 기존 `created_at_rate>=100` + `source!=stop_failure` → **overuse 삭제** |
| **SubagentStop** | Stop과 동일 | overuse 삭제 로직 **미적용** (병렬 완료 ≠ overuse 증거) |
| **StopFailure** | 100% → 생성 | 100% → 생성 + `source: stop_failure` (Stop 삭제 방지 잠금) |
| **Stop (<100%)** | 삭제 | 삭제 (변경 없음) |

### Overuse 케이스 흐름

**일반 세션:**
```
UPS(100%) → session.json 생성 {created_at_rate:100, source:user_prompt}
턴 성공 (overuse)
Stop(100%) → session.json의 created_at_rate>=100, source!=stop_failure → 삭제 ✅
```

**Ralph 루프:**
```
Stop(100%) → session.json 생성 {created_at_rate:100, source:stop}
Ralph exit 2 → 다음 턴 성공 (overuse)
Stop(100%) → session.json의 created_at_rate>=100 → 삭제 ✅
```

**Overuse→Hard limit 전환:**
```
계속 overuse (매 턴: 생성 → 삭제 반복)
Anthropic이 overuse 종료
UPS(100%) → session.json 생성
Client block → Stop 안 뜸 → session.json 유지 → daemon resume ✅
```

### SubagentStop 예외 처리

SubagentStop은 병렬 서브에이전트가 동시에 완료되는 것이므로 연속 턴 성공과 다름:
```
SubagentStop A(100%) → session.json 생성
SubagentStop B(100%) → overuse 삭제 미적용 → session.json 유지 ✅
```

`hook_event_name` 필드로 Stop과 SubagentStop을 구분.

### Subagent Marker Tracking (v1.2.0 — G16 Fix)

서브에이전트가 rate limit으로 실패한 경우, 부모 턴이 overuse로 잘못 분류되는 문제 해결.

**문제**: 서브에이전트 실행 중 rate cache가 stale → SubagentStop이 rate<100%으로 판단 → 스케줄 미생성. 이후 부모 Stop이 overuse로 판정해 스케줄 삭제.

**핵심 발견**: Rate-limited SubagentStop은 성공한 SubagentStop보다 10분+ 지연 발생. 부모 Stop이 먼저 실행됨.

**마커 라이프사이클**:
```
SubagentStart → 마커 생성: subagents/<session_id>/<agent_id>
  ↓
성공 SubagentStop (즉시) → 마커 삭제
Rate-limited SubagentStop (10분+ 후) → 마커 삭제 (정리)
  ↓
부모 Stop 시점:
  마커 없음 (전부 성공) → 기존 overuse 로직 정상 동작
  마커 존재 (실패 에이전트) → overuse 판정 건너뛰기 → 스케줄 유지 ✅
```

**구현 위치**:
| Hook | 동작 |
|------|------|
| `rate-limit-subagent-start.sh` (신규) | 마커 파일 생성 |
| `rate-limit-stop.sh` SubagentStop | 마커 삭제 (캐시 체크 **이전**, stale cache에도 동작) |
| `rate-limit-stop.sh` Stop | 마커 존재 확인 → `SKIP_OVERUSE` 플래그 |

**SubagentStart hook input** (rate 데이터 없음):
```json
{
  "session_id": "...",
  "cwd": "...",
  "agent_id": "a474a400d17efa0d3",
  "agent_type": "general-purpose",
  "hook_event_name": "SubagentStart",
  "transcript_path": "..."
}
```

**마커 파일 위치**: `<cwd>/.claude/auto-resume/subagents/<session_id>/<agent_id>` (내용: 생성 epoch)

### StopFailure 잠금

StopFailure가 `source: stop_failure`를 설정하면, Stop의 overuse 삭제 로직이 무시:
```
UPS(100%) → session.json {source: user_prompt}
API 429 → StopFailure → session.json {source: stop_failure}  (잠금)
Stop(100%) → source==stop_failure → 삭제 안 함 ✅
```

## Architecture (v3 → v4)

### 설계 원칙: "먼저 만들고, 나중에 관리"

Rate limit 차단 이후에는 어떤 hook도 fire되지 않기 때문에, **차단 이전에 스케줄이 이미 존재해야** 한다.

```
┌─ Statusline (매 UI 업데이트) ──────────────────────────┐
│ rate_limits → atomic write (tmp + mv)                   │
│ → ~/.claude/rate-limits.json                            │
│ + last_updated 타임스탬프 포함                           │
└─────────────────────────────────────────────────────────┘
                    ↓ file
┌─ UserPromptSubmit Hook ────────────────────────────────┐
│ rate 100% → 스케줄 생성 (유저 실제 프롬프트 저장)        │
│ exit 0 (프롬프트 통과)                                   │
│ stderr: "⏳ Preparing auto-resume..."                    │
└─────────────────────────────────────────────────────────┘
                    ↓
          (rate limit 차단 or 턴 실행)
                    ↓
┌─ Stop Hook ────────────────────────────────────────────┐
│ rate 100% + 스케줄 없음 → 생성 (고정 텍스트)             │
│ rate 100% + 스케줄 있음 → 유지 (prompt을 고정 텍스트로)  │
│ rate < 100% + 스케줄 있음 → 삭제                         │
│ rate < 100% + 스케줄 없음 → 무시                         │
│                                                         │
│ stderr (생성/유지): "⏳ Auto-resume confirmed at ..."    │
│ stderr (삭제): "✅ Rate recovered. Auto-resume cleared." │
└─────────────────────────────────────────────────────────┘
                    ↓
┌─ Resume Script (nohup 백그라운드) ─────────────────────┐
│ 1. wall-clock 폴링 (60초 간격, 머신 sleep 대응)        │
│    - <session-id>.json 삭제 감지 시 → 즉시 취소         │
│ 2. pre-resume health check:                            │
│    - <session-id>.json 존재 확인 (취소 여부)            │
│    - rate-limits.json 재확인 (최대 5회 재시도)           │
│ 3. <session-id>.json에서 prompt 읽기                   │
│ 4. 세션 활성 여부 분기:                                 │
│    ┌─ ACTIVE (pgrep 감지) ─────────────────────────┐   │
│    │ skip + archive (session_still_active)          │   │
│    └────────────────────────────────────────────────┘   │
│    ┌─ INACTIVE ────────────────────────────────────┐   │
│    │ timeout 3600 claude -p --resume <id> "$prompt" │   │
│    └────────────────────────────────────────────────┘   │
│ 5. 결과를 success/ 또는 failed/ 디렉토리로 아카이브      │
└─────────────────────────────────────────────────────────┘
```

### Active 세션 Resume 전략 (v4)

| 세션 상태 | 전략 | 이유 |
|-----------|------|------|
| **ACTIVE** (pgrep 감지) | **skip + archive** | 세션이 이미 동작 중이면 resume 불필요. kill 시 사용자 작업 손실 위험 |
| **INACTIVE** | `claude -p --resume` (background) | headless 모드로 1턴 실행 |

**v3→v4 변경**: 기존에는 active 세션을 kill → tmux/print resume 했으나, v4에서는 active 세션을 건드리지 않고 skip으로 변경. Overuse 감지로 불필요한 schedule이 제거되므로, active 세션에 resume을 시도할 필요 자체가 사라짐.

### pgrep 자기참조 방지 (v4: ps -o args=)

Daemon 프로세스의 cmdline에 session ID가 포함되어 있어 `pgrep -f`가 자기 자신을 매칭하는 문제:

```bash
# 문제: daemon 자신 + 서브쉘이 매칭됨
pgrep -f "claude.*$SESSION_ID"

# v4 해결: ps -o args= 로 cmdline 확인 + auto-resume 제외 (macOS/Linux 공통)
for pid in $(pgrep -x claude 2>/dev/null || true); do
    CMDLINE=$(ps -o args= -p "$pid" 2>/dev/null || true)
    if [ -n "$CMDLINE" ] && echo "$CMDLINE" | grep -q "$SESSION_ID" && ! echo "$CMDLINE" | grep -q "auto-resume"; then
        CLAUDE_PID="$pid"; break
    fi
done
```

`pgrep -x claude`로 정확히 `claude` 바이너리만 매칭한 후, `ps -o args=`로 session ID 포함 + auto-resume 미포함 여부를 확인. `/proc/cmdline` 대신 `ps`를 사용하여 macOS에서도 동작.

### Stop Hook의 prompt 관리

| 시점 | prompt 저장 값 | 이유 |
|------|---------------|------|
| UserPromptSubmit | 유저의 실제 프롬프트 | 첫 턴이 차단되면 히스토리가 없으므로 원본 필요 |
| Stop (생성/유지) | "If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work." | 턴이 실행됐으므로 히스토리 존재, 고정 텍스트로 충분 |

## 전체 케이스 분석

### Rate 100%에서 시작

| # | 추가사용량 | 세션 | 흐름 | 결과 |
|---|----------|------|------|------|
| A1 | OFF | 일반 | UPS→스케줄(원본)→**차단**→resume | ✅ 핵심 케이스 |
| A2 | OFF | Ralph | UPS→스케줄(원본)→**차단**→resume | ✅ 핵심 케이스 |
| A3 | ON | 일반 | UPS→스케줄(원본,rate=100)→턴 성공→Stop(created_at_rate>=100 감지→**overuse 삭제**)→세션 계속 | ✅ v4: overuse 감지로 해결 |
| A4 | ON | Ralph | UPS→스케줄(원본,rate=100)→턴 성공→Stop(**overuse 삭제**)→루프 계속 | ✅ v4: overuse 감지로 해결 |

### 도중에 100% 도달

| # | 추가사용량 | 세션 | 흐름 | 결과 |
|---|----------|------|------|------|
| B1 | OFF | 일반 | UPS(스케줄X)→턴 성공→Stop(100% 생성)→세션 종료→유저 재입력→UPS(이미 있음)→client block→resume | ✅ 핵심 케이스 |
| B2 | OFF | Ralph | UPS(스케줄X)→턴 성공→Stop(100% 생성)→ralph→**차단**→resume | ✅ 핵심 케이스 |
| B3 | ON | 일반 | UPS(스케줄X)→턴 성공→Stop(100% 생성,rate=100)→다음 턴 성공→Stop(**overuse 삭제**) | ✅ v4: overuse 감지로 해결 |
| B4 | ON | Ralph | UPS(스케줄X)→턴 성공→Stop(100% 생성,rate=100)→루프→Stop(**overuse 삭제**) | ✅ v4: overuse 감지로 해결 |

### 서브에이전트가 Rate 100% 소진

| # | 추가사용량 | 흐름 | 결과 |
|---|----------|------|------|
| D1 | OFF | 서브에이전트 실패→SubagentStop(100% 스케줄 생성)→부모 rate limit 화면→**대기**→resume(kill+재개) | ✅ 핵심 케이스 |
| D2 | OFF | 일부 서브에이전트만 실패→SubagentStop(스케줄 생성)→나머지도 연쇄 실패→부모 대기→resume | ✅ 핵심 케이스 |
| D3 | ON | 서브에이전트 완료→SubagentStop(100% 생성, overuse 삭제 미적용)→부모 overage→Stop(created_at_rate>=100→**overuse 삭제**) | ✅ v4: Stop의 overuse 감지로 해결 |

**D1 상세 흐름:**
```
부모: Agent tool 호출 (병렬 서브에이전트 N개 spawn)
  ├─ 서브에이전트 1: API 호출 → 성공 → SubagentStop (rate < 100% → 무시)
  ├─ 서브에이전트 2: API 호출 → rate limit → SubagentStop (100% → 스케줄 생성 + daemon spawn)
  └─ 서브에이전트 3: API 호출 → rate limit → SubagentStop (100% → 스케줄 이미 존재 → 유지)
부모: 서브에이전트 결과 수집 시도 → API 호출 → rate limit 화면 (기다리기 선택)
  → 부모 세션은 '기다리기' 상태로 살아있음 (active)
  → daemon: 대��� → rate 회복 → ps -o args= 로 active 감지 → skip + archive
  → 부모 세션이 rate 회복 후 자연스럽게 재개됨
```

### Rate 100% 미달

| # | 흐름 | 결과 |
|---|------|------|
| C | 스케줄 생성 안 됨 | ✅ |

### 불필요 Resume 케이스 분석

~~⚠️ 케이스의 공통점: **세션이 정상 종료됐는데 스케줄이 남아있어 불필요한 resume 발생**~~

**v4에서 해결**: Overuse 감지 (`created_at_rate` + `source` 필드)로 A3, A4, B3, B4, D3 케이스 모두 해결.

| 케이스 | v3 결과 | v4 결과 | 해결 방법 |
|--------|---------|---------|-----------|
| A3 | ⚠️ 불필요 resume | ✅ 해결 | Stop이 created_at_rate>=100 감지 → overuse 삭제 |
| A4 | ⚠️ 불필요 resume | ✅ 해결 | Ralph 루프 중 Stop이 반복적으로 overuse 삭제 |
| B3 | ⚠️ 불필요 resume | ✅ 해결 | 다음 턴의 Stop이 overuse 삭제 |
| B4 | ⚠️ 불필요 resume | ✅ 해결 | Ralph 루프 중 Stop이 overuse 삭제 |
| D3 | ⚠️ 불필요 resume | ✅ 해결 | SubagentStop은 예외, 이후 Stop이 overuse 삭제 |

**v4 트레이드오프**: 첫 턴 100%에서 tentative 스케줄이 생성되고, 다음 Stop에서 삭제되기까지 daemon이 잠깐 spawn됨 (60초 내 파일 삭제 감지 후 종료). 실질적 영향 없음.

**추가 안전장치 (v4)**: Daemon이 resume 시점에 세션이 active하면 kill하지 않고 skip. Overuse 감지를 놓쳐도 무해.

## State File: `<project>/.claude/auto-resume/queued/<session-id>.json`

세션별 독립 파일로 관리. 복수 세션이 동시에 스케줄 가능.

```json
{
  "session_id": "abc-123-def",
  "resume_at": 1777662000,
  "resume_at_human": "2026-05-02T04:00:00+09:00",
  "scheduled_at": 1777648658,
  "created_at_rate": 100,
  "source": "user_prompt",
  "prompt": "If any agents failed in the previous task, do not perform their work directly — re-launch the same agents. If it was not an agent failure, continue with the remaining work."
}
```

| 필드 | 설명 |
|------|------|
| `session_id` | resume 대상 세션 |
| `resume_at` | 리셋 예정 epoch |
| `resume_at_human` | 사람이 읽을 수 있는 ISO 시각 |
| `scheduled_at` | 예약 생성 시각 |
| `created_at_rate` | 생성 시점의 rate % (v4: overuse 감지 기준) |
| `source` | 생성한 hook: `user_prompt`, `stop`, `subagent_stop`, `stop_failure` (v4: StopFailure 잠금용) |
| `prompt` | resume 시 전달할 프롬프트 (**유저 수정 가능**) |

### 디렉토리 구조 (v4)

```
<project>/.claude/auto-resume/
├── queued/        ← 대기 중인 스케줄
│   └── <session-id>.json
├── success/       ← 성공한 resume (completed_at 포함)
│   └── <session-id>.json
└── failed/        ← 실패한 resume (error_output 포함)
    └── <session-id>.json
```

### 사용자 조작

- **프롬프트 수정**: `<project>/.claude/auto-resume/queued/<session-id>.json`의 `prompt` 필드 편집
- **특정 세션 취소**: `rm <project>/.claude/auto-resume/queued/<session-id>.json`
- **전체 취소**: `rm -rf <project>/.claude/auto-resume/queued/`
- **시각 확인**: `resume_at_human` 필드로 예정 시각 확인
- **이력 확인**: `success/`, `failed/` 디렉토리에서 과거 resume 결과 확인

## Hook 전체 목록 (Claude Code 29개)

auto-resume 시스템에서 사용하는 hook:

| Event | 사용 | 역할 |
|-------|------|------|
| **UserPromptSubmit** | ✅ | 선제적 스케줄 생성 (100% 시) |
| **Stop** | ✅ | 스케줄 생성/유지/삭제 (rate 상태 기반) |
| **SubagentStop** | ✅ | 서브에이전트 종료 시 스케줄 생성/유지/삭제 (`rate-limit-stop.sh` 재사용) |
| **StopFailure** | ✅ | API 에러 시 스케줄링 (fallback) |

사용하지 않는 hook: SessionStart, SessionEnd, Setup, UserPromptExpansion, PreToolUse, PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch, SubagentStart, TaskCreated, TaskCompleted, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, FileChanged, WorktreeCreate, WorktreeRemove, PreCompact, PostCompact, Elicitation, ElicitationResult, Notification

**핵심 제약**: "최종 exit code"를 받는 hook이 없음. 각 Stop hook은 독립 실행이라 다른 hook(ralph 등)의 exit code를 알 수 없음.

## Components & File Layout

```
~/.claude/
├── hooks/
│   ├── rate-limit-stop.sh            # Stop hook
│   ├── rate-limit-stop-failure.sh    # StopFailure hook (fallback)
│   └── rate-limit-prompt-guard.sh    # UserPromptSubmit hook
├── bin/
│   ├── claude-auto-resume.sh         # Resume executor (nohup)
│   ├── test-resume-daemon.sh         # Daemon 단위 테스트
│   └── test-rate-limit-simulation.sh # Hook 시뮬레이션 테스트
├── rate-limits.json                  # Statusline이 저장하는 rate limit 캐시
└── logs/
    ├── auto-resume-YYYY-MM-DD.log    # 일별 로그
    ├── resume-<session-id>.log       # 개별 resume 프로세스 로그
    └── rate-limit-trace.log          # Statusline trace (검증용, 최근 200줄)

<project>/.claude/
└── auto-resume/
    ├── queued/                       # 대기 중인 스케줄 (삭제 = 취소)
    │   └── <session-id>.json
    ├── success/                      # 성공한 resume (아카이브)
    │   └── <session-id>.json
    └── failed/                       # 실패한 resume (아카이브)
        └── <session-id>.json
```

## settings.json Hook 등록

```json
{
  "hooks": {
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/hooks/rate-limit-stop.sh",
        "timeout": 10
      }]
    }],
    "SubagentStop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/hooks/rate-limit-stop.sh",
        "timeout": 10
      }]
    }],
    "StopFailure": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/hooks/rate-limit-stop-failure.sh",
        "timeout": 10
      }]
    }],
    "UserPromptSubmit": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "bash ~/.claude/hooks/rate-limit-prompt-guard.sh",
        "timeout": 10
      }]
    }]
  }
}
```

## Statusline Cache

Statusline 스크립트에 추가된 캐싱 로직 (v4: jq 기반 atomic write):

```bash
if [ -n "$five_pct" ] || [ -n "$week_pct" ]; then
    jq -n \
        --argjson fp "${five_pct:-0}" --argjson fr "${five_reset:-0}" \
        --argjson wp "${week_pct:-0}" --argjson wr "${week_reset:-0}" \
        --argjson now "$now" \
        '{rate_limits:{five_hour:{used_percentage:$fp,resets_at:$fr},seven_day:{used_percentage:$wp,resets_at:$wr}},last_updated:$now}' \
        > "$HOME/.claude/rate-limits.json.tmp" && mv "$HOME/.claude/rate-limits.json.tmp" "$HOME/.claude/rate-limits.json"
fi
```

**v3→v4 변경**: 문자열 보간 대신 `jq -n --argjson`으로 안전한 JSON 생성.

## User-Facing 메시지 (stderr)

| 시점 | 메시지 |
|------|--------|
| UserPromptSubmit (100%, 스케줄 생성) | `⏳ Auto-resume scheduled at {시각} (in {N}m {N}s)` + `   State: {파일}` + `   Cancel: rm {파일}` |
| UserPromptSubmit (100%, 이미 존재) | `⏳ Auto-resume already scheduled at {시각} (in {N}m {N}s)` + `   State: {파일}` + `   Cancel: rm {파일}` |
| Stop (100%, 스케줄 생성/유지) | `⏳ Auto-resume confirmed at {시각} (in {N}m {N}s)` + `   State: {파일}` + `   Cancel: rm {파일}` |
| Stop (100%, overuse 감지) | `✅ Overuse detected (turn completed at 100%). Schedule cancelled.` |
| Stop (<100%, 스케줄 삭제) | `✅ Rate recovered. Auto-resume cleared.` |
| StopFailure (100%, 스케줄 생성) | `⏳ Auto-resume scheduled at {시각} (in {N}m {N}s) [locked by stop_failure]` + `   State: {파일}` + `   Cancel: rm {파일}` |
| StopFailure (100%, 이미 존재) | `⏳ Auto-resume already scheduled at {시각} (in {N}m {N}s) [locked by stop_failure]` + `   State: {파일}` + `   Cancel: rm {파일}` |

모든 메시지는 stderr로 출력 → 유저에게 보이고 모델에게는 전달되지 않음. v4에서 시간 델타(Nm Ns), State 파일 경로, Cancel 명령이 모든 메시지에 추가됨.

## Critical Issues & Mitigations

| Severity | Issue | Mitigation |
|----------|-------|------------|
| ~~CRITICAL~~ | ~~TTY 필요~~ | `-p` 모드로 해결, nohup에서 검증 완료 |
| ~~CRITICAL~~ | ~~100%에서 statusline 데이터 안 옴~~ | trace 로그로 정상 수신 확인 |
| ~~CRITICAL~~ | ~~클라이언트 차단 시 hook 안 fire~~ | UserPromptSubmit에서 선제적 스케줄링으로 해결 (실환경 검증 완료) |
| ~~HIGH~~ | ~~불필요한 resume (정상 종료 + 100%)~~ | v4: `created_at_rate` + `source` 기반 overuse 감지로 해결. Active 세션은 skip |
| HIGH | Stale 데이터 | atomic write (tmp+mv) + Stop hook에서 0.3s delay + 5분 freshness 체크 |
| HIGH | 중복 예약 | `<session-id>.json` 존재 + session_id 유효성 체크 |
| HIGH | 7일 한도 | 두 window 모두 확인, max(resets_at), 8시간 초과 시 skip |
| HIGH | 머신 sleep | wall-clock 폴링 루프 (60초 간격) |
| ~~HIGH~~ | ~~기존 세션 충돌 (active session)~~ | v4: active 세션 감지 시 skip + archive. kill 없이 안전하게 처리 |
| HIGH | Corrupted JSON | 모든 jq read에 `2>/dev/null \|\| echo ""` fallback (set -e 호환) |
| ~~HIGH~~ | ~~pgrep 자기참조~~ | v4: `ps -o args=` + `pgrep -x claude`로 정확 매칭 (macOS/Linux 공통). `pgrep -af` 제거 |
| ~~HIGH~~ | ~~Resume 실패 시 프롬프트 소실~~ | 파일 삭제를 resume 시도 전에 수행 → 실패 시 프롬프트 영구 소실. **성공 시에만 삭제**로 수정 |
| MEDIUM | 동시 파일 접근 | atomic rename (tmp → mv) |
| ~~MEDIUM~~ | ~~환경 변수~~ | v4: `find_claude_bin()` 명시적 경로 탐색 (shell profile 의존 제거) |
| MEDIUM | jq `//` 연산자 | `false` 값에 `//` 사용 불가 → 명시적 if/else 사용 |

## Log Format

```
~/.claude/logs/auto-resume-YYYY-MM-DD.log     # 일별 이벤트 로그
~/.claude/logs/resume-<session-id>.log         # 개별 resume 프로세스 로그
```

### 일별 이벤트 로그 (hook → 스케줄 이벤트)

```
2026-05-01T22:15:00+09:00 SCHEDULED session=abc123 resume_at=2026-05-02T04:00:00+09:00 five=100% seven=57% cwd=/workspace/project
2026-05-01T22:15:00+09:00 SCHEDULED_BY_GUARD session=abc123 resume_at=2026-05-02T04:00:00+09:00 five=100% seven=57% cwd=/workspace/project
2026-05-01T22:15:00+09:00 SCHEDULED_BY_FAILURE session=abc123 resume_at=2026-05-02T04:00:00+09:00 five=100% seven=57% cwd=/workspace/project
2026-05-01T23:00:00+09:00 CLEARED session=abc123 cwd=/workspace/project
```

| Prefix | Source |
|--------|--------|
| `SCHEDULED` | Stop hook 생성 |
| `SCHEDULED_BY_GUARD` | UserPromptSubmit hook 생성 |
| `SCHEDULED_BY_FAILURE` | StopFailure hook 생성 |
| `CLEARED` | Stop hook 삭제 (rate 회복) |
| `OVERUSE_DETECTED` | Stop hook이 overuse 감지하여 스케줄 삭제 (rate 100% + created_at_rate >= 100) |
| `OVERUSE_CLEARED` | Rate 회복 시 overuse로 생성된 스케줄 정리 |

### Resume 프로세스 로그

```
2026-05-01T22:15:00+09:00 WAITING session=abc123 target=2026-05-02T04:00:00+09:00
2026-05-02T04:00:05+09:00 RATE_RECOVERED session=abc123 five=45% seven=85%
2026-05-02T04:00:05+09:00 BG_RESUME session=abc123 prompt="[Auto-resumed after 345m wait for rate limit recovery] If any agents..."
2026-05-02T04:00:08+09:00 DONE session=abc123 exit_code=0
```

Active 세션 시 (v4: skip):
```
2026-05-02T04:00:05+09:00 SKIPPED session=abc123 reason=session_still_active pid=12345
```

실패 시:
```
2026-05-02T04:00:05+09:00 RESUME_FAILED session=abc123 exit_code=1
```

Overuse 감지 시:
```
2026-05-01T22:15:00+09:00 OVERUSE_DETECTED session=abc123 source=user_prompt created_at_rate=100
```

| Prefix | 설명 |
|--------|------|
| `WAITING` | 대기 시작 |
| `CANCELLED` | 파일 삭제로 취소됨 |
| `CACHE_STALE` | 캐시 오래됨 → 회복으로 간주 |
| `RATE_RECOVERED` | rate < 100% 확인 |
| `NO_CACHE` | 캐시 파일 없음 → 회복으로 간주 |
| `STILL_LIMITED` | 아직 rate 100% (재시도 중) |
| `GAVE_UP` | 최대 재시도 초과 |
| `SKIPPED` | active 세션 감지 → skip + archive (v4) |
| `KILL_OLD_DAEMON` | 동일 세션 중복 daemon 제거 |
| `BG_RESUME` | background print 모드 resume 시작 |
| `DONE` | resume 완료 |
| `RESUME_FAILED` | resume 실패 (파일 유지) |
| `FAILED` | claude 바이너리 미발견 등 치명적 실패 |

## Constraints

| Constraint | Detail |
|------------|--------|
| Claude Code only | Claude Desktop에는 hook 시스템 없음 |
| OS 범용 | Linux, macOS, WSL 지원 |
| 추가 설치 없음 | POSIX 셸 + jq + nohup만 사용 (bc, at, cron, screen 불필요) |
| tmux (선택적) | tmux 환경이면 active 세션에 interactive resume. 없으면 headless (`-p`) fallback |
| `-p` 모드 | TTY 불필요. 1턴 실행 후 종료 |
| Machine on | 머신이 꺼지면 예약 소멸 |

## Resolved Questions

1. ~~CLI syntax~~ → `claude -p --resume <id> "prompt"` (위치 인자) ✅
2. ~~TTY 없이 동작?~~ → nohup 환경에서 검증 완료 ✅
3. ~~screen/tmux 필요?~~ → nohup + `-p` 모드로 충분 ✅
4. ~~100%에서 statusline 데이터?~~ → trace 로그로 정상 수신 확인 ✅
5. ~~ralph-loop / omc:ralph 커버?~~ → 둘 다 파일 기반 상태, resume 시 자동 재개 ✅
6. ~~추가 사용량 충돌?~~ → v4: `created_at_rate` 기반 overuse 자동 감지로 해결. overage 필드 불필요 ✅
7. ~~jq false 처리~~ → `//` 대신 명시적 `if .overage == false` 사용 ✅
8. ~~클라이언트 차단 시 hook 없음~~ → UserPromptSubmit 선제적 스케줄링으로 해결, 실환경 검증 완료 ✅
9. ~~StopFailure로 커버 가능?~~ → 클라이언트 단 차단에는 fire 안 됨 (API 에러에만 반응), fallback 용도로 유지 ✅
10. ~~열린 세션에 프롬프트 재주입 가능?~~ → tmux: kill → `claude --resume` → `send-keys` 프롬프트 주입. 일반 터미널: TIOCSTI 비활성화로 불가, kill → `claude -p --resume`(headless)로 대체 ✅
11. ~~pgrep이 daemon 자신을 active로 오탐~~ → v4: `pgrep -x claude` + `ps -o args=`로 해결 (macOS/Linux 공통) ✅
12. ~~resume 실패 시 프롬프트 소실~~ → 성공 시에만 파일 삭제로 해결 ✅
13. ~~병렬 서브에이전트가 rate 소진 시 auto-resume 미생성~~ → `SubagentStop`에 `rate-limit-stop.sh` 등록으로 해결. 서브에이전트 실패 시점에 스케줄 생성, 부모 세션은 '기다리기' 상태에서 kill → resume ✅

## Resolved Implementation Issues

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| Corrupted JSON crash (exit 4) | `set -euo pipefail` + jq non-zero exit on invalid JSON | `jq ... 2>/dev/null \|\| echo ""` on ALL jq reads |
| JSON quoting vulnerability | heredoc with `$PROMPT` breaks on quotes/special chars | `jq -n --arg` for all JSON generation |
| Race condition with statusline | Stop hook reads cache before statusline writes | `sleep 0.3` in Stop hook only |
| Active session 처리 | v3: kill → resume (위험) | v4: skip + archive (안전). Overuse 감지로 불필요 schedule 자체가 제거됨 |
| pgrep 자기참조 오탐 | daemon cmdline에 `claude-auto-resume.sh SESSION_ID`가 포함 | v4: `pgrep -x claude` + `ps -o args=` (macOS/Linux 공통) |
| Resume 실패 시 파일 소실 | 파일 삭제가 resume 시도 전에 수행됨 | success/ 또는 failed/ 디렉토리로 아카이브 |
| 동일 세션 중복 daemon | hook이 여러 번 fire되면 같은 세션에 daemon 다중 spawn | daemon 시작 시 `ps -o args=`로 기존 daemon kill |
| Resume 무한 대기 | `claude -p --resume`이 hang될 경우 daemon도 영구 block | v4: `timeout 3600` 래핑 (1시간 타임아웃) |
| 로그 파일 누적 | resume/auto-resume 로그가 무한 축적 | v4: `cleanup_old_logs()` — resume 7일, auto-resume 30일, archive 50개 제한 |
| Resume 메타데이터 부재 | resumed 세션에서 auto-resume 발동 사실을 알 수 없음 | v4: 프롬프트 앞에 `[Auto-resumed after {N}m wait]` 메타데이터 추가 |
| Shell 환경 의존 | `source ~/.bashrc` 등으로 PATH 설정 → non-login shell에서 실패 | v4: 명시적 경로 탐색 (`find_claude_bin()`) |

## Open Questions

1. `-p` 모드에서 permission 요청 발생 시 동작 (`--dangerously-skip-permissions` 필요?)
2. 기존 사용자의 statusline/hook 설정과 충돌 없이 병합하는 방법
3. Resume 실패 후 파일이 남았을 때 자동 재시도 메커니즘 (현재는 수동 재시도만 가능)

## Test

### Hook 시뮬레이션 테스트 (66개 시나리오, 214 assertions)

```bash
bash ~/.claude/bin/test-rate-limit-simulation.sh
```

| Category | Tests | Coverage |
|----------|-------|----------|
| Stop hook 기본 | T01-T06 | Rate states, stale/missing cache |
| Prompt guard 기본 | T07-T12 | Scheduling, dedup, edge cases |
| StopFailure 기본 | T13-T17 | API error fallback, source lock |
| Multi-session | T18-T20 | Coexistence, selective cleanup |
| 특수 문자 prompt | T21-T26 | Quotes, backslash, newline, Korean, JSON |
| Both limits at 100% | T27-T29 | Reset time selection |
| Edge cases | T30-T36 | 8h limit, rounding, empty input, atomic write |
| 전체 라이프사이클 | T37-T38 | Guard → StopFailure lock → Stop confirm → recovery |
| Corrupted files | T39-T43 | Invalid JSON, empty files, directory cleanup |
| **Overuse detection** | **T44-T56** | **Overuse via UPS/Stop, SubagentStop exempt, StopFailure lock, field validation, invalid session ID** |
| **Subagent marker (G16)** | **T57-T66** | **Marker create/delete, overuse skip with marker, stale cache cleanup, multi-agent partial, full G16 lifecycle, validation, opt-out, empty dir** |

### Daemon 단위 테스트

```bash
bash ~/.claude/bin/test-resume-daemon.sh
```

| Test | 검증 항목 |
|------|----------|
| Test 1: tmux pane detection | `find_tmux_pane()` — 현재 쉘 PID로 tmux pane 탐지, PID 1에 대해 빈 결과 |
| Test 2: Rate limit cache | fake `rate-limits.json` 생성/복원 |
| Test 3: Inactive session resume | 비활성 세션 → `BG_RESUME` 경로 → claude 호출 (가짜 ID라 실패) → 파일 유지 확인 |
| Test 4: Active session detection | 가짜 claude 프로세스 → `pgrep` 매칭 + tmux pane 탐지 |

### E2E Rate Limit 시뮬레이션

수동 실행 (약 30-90초 소요):
1. `rate-limits.json`을 100%로 조작 (reset N초 후)
2. auto-resume 파일 생성
3. daemon 실행 → 대기 → rate 회복 시뮬레이션 (45%로 변경) → resume 시도
4. 일별 로그에서 `WAITING → RATE_RECOVERED → BG_RESUME → DONE` 흐름 확인

검증 완료 항목:
- pgrep 자기참조 오탐 해결 (`SESSION_ACTIVE` 미출력)
- 파일에서 원본 프롬프트 정상 읽기
- 실패 시 파일 유지 (`RESUME_FAILED` + `file_kept=...`)

### 방어 로직 (구현 완료)

- **Corrupted JSON 회복**: `jq -r '...' "$FILE" 2>/dev/null || echo ""` 패턴으로 손상된 파일에서도 crash 방지
- **`set -euo pipefail` 호환**: 모든 jq read에 `|| echo ""`/`|| true` fallback 추가
- **Atomic write**: 모든 파일 쓰기는 `.tmp` → `mv` 패턴 사용

## Installation (Skill)

```
/setup-auto-resume
  → ① statusline 캐시 로직 추가/병합
  → ② hook 스크립트 설치
  → ③ resume 스크립트 설치
  → ④ settings.json에 hook 등록
  → ⑤ 설치 결과 안내
```
