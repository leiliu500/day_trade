# Human Option Day Trade — System Design

> **Date:** 2026-02-22
> **System:** Alpaca Option MultiTF DMI/TD — n8n + Postgres + AI Agents
> **Scope:** End-to-end option day trading lifecycle, designed to replicate how a skilled human trader operates

---

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [System Architecture Overview](#2-system-architecture-overview)
3. [Trading Day Lifecycle](#3-trading-day-lifecycle)
4. [Phase 1 — Pre-Market Preparation](#4-phase-1--pre-market-preparation)
5. [Phase 2 — Signal Generation Pipeline](#5-phase-2--signal-generation-pipeline)
6. [Phase 3 — Option Selection & Candidate Scoring](#6-phase-3--option-selection--candidate-scoring)
7. [Phase 4 — AI Analysis & Decision Gate](#7-phase-4--ai-analysis--decision-gate)
8. [Phase 5 — Orchestrated Trade Lifecycle](#8-phase-5--orchestrated-trade-lifecycle)
9. [Phase 6 — Order Execution & Fill Management](#9-phase-6--order-execution--fill-management)
10. [Phase 7 — Position Monitoring & Risk Management](#10-phase-7--position-monitoring--risk-management)
11. [Phase 8 — Exit Execution](#11-phase-8--exit-execution)
12. [Phase 9 — Post-Trade Evaluation & Learning](#12-phase-9--post-trade-evaluation--learning)
13. [Phase 10 — End-of-Day Reconciliation](#13-phase-10--end-of-day-reconciliation)
14. [Data Model](#14-data-model)
15. [Risk Management Framework](#15-risk-management-framework)
16. [Notification & Alerting](#16-notification--alerting)
17. [Configuration & Tuning Parameters](#17-configuration--tuning-parameters)
18. [Deployment Architecture](#18-deployment-architecture)
19. [Operational Runbook](#19-operational-runbook)

---

## 1. Design Philosophy

A human option day trader does not simply react to signals — they operate within a disciplined framework of **observation → conviction building → execution → monitoring → exit → review**. This system replicates that framework through:

| Human Behavior | System Implementation |
|---|---|
| Scans charts across multiple timeframes | Multi-TF indicator pipeline (3 parallel Alpaca bar requests → DMI/ADX + TD Sequential + candlestick patterns) |
| Evaluates both call and put sides | Dual-candidate option pipeline (CALL + PUT scored simultaneously) |
| Builds conviction before entering | 3-confirmation entry strategy (OBSERVE → BUILDING_CONVICTION → CONFIRMED_ENTRY) |
| Sizes positions based on conviction | Conviction-based sizing with 3 tiers (REGULAR 1-3, SIZABLE 3-5, MAX_CONVICTION 5-10 contracts) |
| Watches positions continuously | Signal-driven monitoring loop (5-min AUTO mode + Telegram manual triggers) |
| Cuts losses and lets winners run | ATR-based stop-loss (0.8× ATR) and take-profit (1.6× ATR) levels |
| Reviews trades and learns | AI Trade Evaluator with grades (A–F), lessons learned, and feedback loop |
| Keeps a trading journal | PostgreSQL position_journal + signal_snapshots + trading_decisions |

### Core Principles

1. **Deterministic over AI**: Trend direction, confidence, and levels are computed deterministically. AI provides explanation only.
2. **Dual-candidate fairness**: Both CALL and PUT are evaluated on equal footing before a winner is selected.
3. **Gate-first safety**: Time gate, liquidity gate, R:R gate, and side-mismatch gate all run BEFORE any order reaches the broker.
4. **Journal everything**: Every signal, decision, execution, and evaluation is persisted for audit and learning.
5. **Fail-safe to WAIT**: When in doubt, the system defaults to WAIT — never to a trade.

---

## 2. System Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        TRIGGERS                                      │
│   ┌──────────────┐    ┌──────────────────────────────────────┐      │
│   │   Telegram    │    │  Schedule (every 5 min Mon-Fri       │      │
│   │  "<TICKER> S" │    │  12:00-20:00 UTC, AUTO mode)         │      │
│   └──────┬───────┘    └──────────────┬───────────────────────┘      │
│          │                           │                               │
│          ▼                           ▼                               │
│   ┌──────────────────────────────────────┐                          │
│   │        Get Profile / Set Request      │                          │
│   │  Parse: ticker, profile (S/M/L),      │                          │
│   │  intervals, mode (MANUAL/AUTO)        │                          │
│   └──────────────┬───────────────────────┘                          │
└──────────────────┼──────────────────────────────────────────────────┘
                   │
┌──────────────────┼──────────────────────────────────────────────────┐
│    SIGNAL GENERATION PIPELINE                                        │
│                  ▼                                                   │
│   ┌─────────────────────────────────────┐                           │
│   │  Yahoo Finance → Ticker Resolution   │                           │
│   └──────────────┬──────────────────────┘                           │
│                  ▼                                                   │
│   ┌──────────────────────────┐                                      │
│   │  3 Parallel Bar Requests  │  (Alpaca /v2/stocks/bars)           │
│   │  LTF | MTF | HTF         │  e.g., 2m | 3m | 5m (Profile S)    │
│   └──────┬───┬───┬───────────┘                                      │
│          │   │   │                                                   │
│          ▼   ▼   ▼                                                   │
│   ┌──────────────────────────┐                                      │
│   │  3 Parallel Normalize +   │                                      │
│   │  Indicator Pipelines      │                                      │
│   │  DMI(14) + TD Sequential  │                                      │
│   │  + Price Structure        │                                      │
│   │  + Candlestick Patterns   │                                      │
│   └──────┬───┬───┬───────────┘                                      │
│          │   │   │                                                   │
│          ▼   ▼   ▼                                                   │
│   ┌──────────────────────────┐                                      │
│   │       Merge (3-way)       │                                      │
│   └──────────┬───────────────┘                                      │
│              ▼                                                       │
│   ┌──────────────────────────┐                                      │
│   │    Build AI Payload       │  Multi-TF alignment, summary,       │
│   │                           │  price context, candle patterns      │
│   └──────────┬───────────────┘                                      │
└──────────────┼──────────────────────────────────────────────────────┘
               │
┌──────────────┼──────────────────────────────────────────────────────┐
│    OPTION SELECTION PIPELINE                                         │
│              ▼                                                       │
│   ┌──────────────────────────┐                                      │
│   │   Derive Option Intent    │  Emit 2 items: CALL + PUT           │
│   │   (strike bounds, expiry) │  Next-business-day expiry           │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Get Option Contracts     │  Alpaca /v2/options/contracts       │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Select Contract          │  Filter: right, expiry, OI, spread  │
│   │  (Shortlist, per side)    │  Rank by ATM proximity              │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Get Option Snapshots     │  Alpaca /v1beta1/options/snapshots  │
│   │  (up to 100 per side)     │  bid/ask/greeks/trade               │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Select Contract (Liquid) │  Best spread + freshness            │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │   Compare Candidates      │  Score CALL vs PUT:                 │
│   │   (RunOnceForAllItems)    │  pass > liq > sideMatch > RR >     │
│   │                           │  spread > OI                        │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Liquidity OK? Gate       │                                      │
│   │  ├─ Yes → Enrich + AI     │                                      │
│   │  └─ No  → Force WAIT      │                                      │
│   └──────────────────────────┘                                      │
└──────────────────────────────────────────────────────────────────────┘
               │
┌──────────────┼──────────────────────────────────────────────────────┐
│    AI ANALYSIS + DECISION GATE                                       │
│              ▼                                                       │
│   ┌──────────────────────────┐                                      │
│   │  Enrich Payload for AI    │  Merge all upstream context          │
│   │                           │  + option premiums (entry/stop/TP)   │
│   │                           │  + TD normalization per TF           │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Compute Trend &          │  Deterministic: direction, strength, │
│   │  Confidence               │  confidence (0..1), alignment,       │
│   │                           │  ADX confirmation                    │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Enforce Desired Right    │  Set desired_option_right from bias  │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  If1 (confidence > 65%?) │                                      │
│   │  ├─ TRUE  ───────────────┼─→ AI Indicator Analyst               │
│   │  │                       │   → Normalize Confidence              │
│   │  │                       │   → Switch (Confidence Gate)          │
│   │  │                       │   → Output Telegram                   │
│   │  │                       │   → Save Signal Snapshot ─┐           │
│   │  │                       │                           │           │
│   │  └─ FALSE ───────────────┼─→ Save Signal Snapshot ───┤           │
│   │    (bypass AI, low conf) │   (position mgmt only)    │           │
│   └──────────────────────────┘                           │           │
└──────────────────────────────────────────────────────────┼───────────┘
               │◄──────────────────────────────────────────┘
┌──────────────┼──────────────────────────────────────────────────────┐
│    ORCHESTRATED TRADE LIFECYCLE (ALWAYS RUNS)                        │
│              ▼                                                       │
│   ┌──────────────────────────┐                                      │
│   │  Save Signal Snapshot     │  Persist to trading.signal_snapshots │
│   │  + Build 8 SQL queries    │  Cascading fallback:                 │
│   │                           │  Output Telegram → Normalize Conf    │
│   │                           │  → Enforce Desired Right → $json     │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Sync Broker State        │  GET /v2/positions → broker_positions│
│   │                           │  GET /v2/orders?status=open →        │
│   │                           │  broker_open_orders                  │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Build Orchestrator       │  RunOnceForAllItems: classify        │
│   │  Context                  │  Postgres rows → 7 context buckets   │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │              AI Decision Orchestrator (GPT-4.1-mini)          │  │
│   │                                                               │  │
│   │  7 Decision Types:                                            │  │
│   │  ┌───────────────┐ ┌──────────────┐ ┌──────────────────┐    │  │
│   │  │  NEW_ENTRY     │ │ CONFIRM_HOLD │ │  ADD_POSITION     │    │  │
│   │  └───────────────┘ └──────────────┘ └──────────────────┘    │  │
│   │  ┌────────────────┐ ┌─────────┐ ┌──────┐ ┌──────┐         │  │
│   │  │REDUCE_EXPOSURE │ │ REVERSE │ │ EXIT │ │ WAIT │          │  │
│   │  └────────────────┘ └─────────┘ └──────┘ └──────┘         │  │
│   │                                                               │  │
│   │  Entry Strategy: 3-Confirmation Protocol                      │  │
│   │  OBSERVE → BUILDING_CONVICTION → CONFIRMED_ENTRY              │  │
│   │  Override: confidence ≥ 0.85 + strong alignment → immediate   │  │
│   │                                                               │  │
│   │  Confidence Gates:                                            │  │
│   │  NEW_ENTRY / ADD_POSITION: require ≥ 0.65                    │  │
│   │  EXIT / REVERSE / REDUCE: allowed at any confidence           │  │
│   │                                                               │  │
│   │  Broker State Awareness:                                      │  │
│   │  - Reads real positions + pending orders                      │  │
│   │  - Prevents duplicate orders                                  │  │
│   │  - Reconciles virtual vs real positions                       │  │
│   │                                                               │  │
│   │  Past Evaluation Learning:                                    │  │
│   │  - Reads v_evaluation_feedback                                │  │
│   │  - Avoids repeating D/F grade patterns                        │  │
│   └───────────────────────────┬──────────────────────────────────┘  │
│                               ▼                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                    Decision Router (8 outputs)                │  │
│   │                                                               │  │
│   │  0: NEW_ENTRY      → Account → Size → Parse → Submit → Persist│
│   │  1: CONFIRM_HOLD   → Notify → Persist → Telegram              │
│   │  2: ADD_POSITION   → Account → Size → Parse → Submit → Persist│
│   │  3: REDUCE_EXPOSURE→ Prepare → Sell to Close → Persist + Eval │
│   │  4: REVERSE        → Close → Re-enter opposite → Persist      │
│   │  5: EXIT           → Prepare → Close Position → Persist + Eval│
│   │  6: WAIT           → Notify → Persist → Telegram              │
│   │  7: Fallback       → (empty)                                  │
│   └──────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
               │
┌──────────────┼──────────────────────────────────────────────────────┐
│    POST-TRADE EVALUATION                                             │
│              ▼                                                       │
│   ┌──────────────────────────┐                                      │
│   │  Gather Trade Data        │  SQL join: position_journal +        │
│   │                           │  order_executions + trading_decisions │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Compute Trade P&L        │  Price change, P&L/contract,         │
│   │                           │  total P&L, outcome, hold duration   │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  AI Trade Evaluator       │  GPT-4.1-mini: signal quality,       │
│   │                           │  timing, risk mgmt, grade A-F,       │
│   │                           │  score 0-100, lessons_learned        │
│   └──────┬───────────────────┘                                      │
│          ▼                                                           │
│   ┌──────────────────────────┐                                      │
│   │  Persist Evaluation       │  trading.trade_evaluations           │
│   │  + Telegram Notification  │                                      │
│   └──────────────────────────┘                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. Trading Day Lifecycle

A complete trading day follows this state machine:

```
 ┌─────────────┐
 │  PRE_MARKET  │  Before 9:30 ET
 │  (optional)  │  - Check overnight levels
 │              │  - Review prior day evaluations
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │   OPENING    │  9:30 - 10:00 ET
 │              │  - AUTO mode starts at 12:00 UTC (≈ 7:00 ET)
 │              │  - Market hours gate (Alpaca /v2/clock)
 │              │  - Initial signals may be noisy
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │    ACTIVE    │  10:00 - 15:00 ET
 │              │  - Primary trading window
 │              │  - Signal → Orchestrate → Execute loop every 5 min
 │              │  - Manual triggers via Telegram anytime
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │  POWER_HOUR  │  15:00 - 15:45 ET
 │              │  - Tighten stops on open positions
 │              │  - Avoid new entries after 15:30
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │   CLOSING    │  15:45 - 16:00 ET
 │              │  - Force-close all day trade positions (planned)
 │              │  - Final broker reconciliation
 └──────┬──────┘
        ▼
 ┌─────────────┐
 │   CLOSED     │  After 16:00 ET
 │              │  - Post-trade evaluations run
 │              │  - Session status → CLOSED
 └─────────────┘
```

---

## 4. Phase 1 — Pre-Market Preparation

### What a Human Does

Before the market opens, a human trader:
- Reviews overnight price action and gap direction
- Identifies key support/resistance levels from the prior session
- Checks economic calendar (CPI, FOMC, jobs reports)
- Reviews prior day's trade evaluations for lessons learned
- Sets bias for the day (bullish/bearish/neutral)

### Current System Implementation

| Component | Status | Description |
|---|---|---|
| Schedule Trigger | ✅ Implemented | Runs every 5 min Mon-Fri 12:00-20:00 UTC |
| Market Hours Gate | ✅ Implemented | Alpaca `/v2/clock` + `/v2/calendar` check |
| Prior Evaluations | ✅ Schema exists | `v_evaluation_feedback` view available for orchestrator |
| Overnight Levels | ❌ Not implemented | No pre-market gap analysis |
| Economic Calendar | ❌ Not implemented | No event awareness |

### Trigger Modes

| Mode | Trigger | Behavior |
|---|---|---|
| **MANUAL** | Telegram message: `<TICKER> <PROFILE>` (e.g., `SPY S`) | One-shot analysis, confidence gate bypassed |
| **AUTO** | Schedule trigger (every 5 min during market hours) | Continuous monitoring, requires confidence ≥ 65% |

### Profile Configuration

| Profile | Timeframes | Use Case |
|---|---|---|
| **S** (Scalp) | 2m / 3m / 5m | Fast-paced scalping, 5-30 min holds |
| **M** (Medium) | 1m / 5m / 15m | Standard day trades, 15-120 min holds |
| **L** (Long) | 5m / 1h / 1d | Swing-ish day trades, multi-hour holds |

---

## 5. Phase 2 — Signal Generation Pipeline

### Multi-Timeframe Indicator Stack

For each of the 3 timeframes in the selected profile, the system computes:

#### 5.1 DMI / ADX (Period 14)

```
Inputs:  OHLC candles (up to 1000 bars per TF from Alpaca)
Outputs:
  - DI+ (directional index positive)
  - DI- (directional index negative)
  - ADX (average directional index)
  - Crossover detection (bullish_cross_up / bearish_cross_down)
  - Trend strength classification (weak < 25, moderate 25-50, very_strong ≥ 50)
```

**Interpretation:**
- DI+ > DI- → Bullish pressure
- DI- > DI+ → Bearish pressure
- ADX > 25 → Trend has meaningful strength (used for confirmation, not decision)

#### 5.2 TD Sequential / DeMark

```
Inputs:  OHLC candles
Outputs:
  - Setup: direction (bullish/bearish), count (0-9), completed (bool)
  - Countdown: direction, count (0-13), completed (bool)
```

**Interpretation:**
- Setup 9 completion → potential exhaustion signal
- Countdown 13 completion → strong reversal signal
- Early setup (1-4) in trend direction → trend continuation likely

#### 5.3 Price Structure

```
Inputs:  OHLC candles
Outputs:
  - last_close, last_high, last_low
  - swing_high_N (20-bar lookback), swing_low_N
  - ATR(14) SMA — used for stop/TP calculation
```

#### 5.4 Candlestick Patterns (last 1-2 candles)

| Pattern | Detection | Interpretation |
|---|---|---|
| **Hammer** | Small body (≤35%), long lower wick (≥2× body), small upper wick | Bullish reversal hint |
| **Shooting Star** | Small body, long upper wick (≥2× body), small lower wick | Bearish reversal hint |
| **Bullish Engulfing** | Prior bearish candle engulfed by current bullish candle | Bullish momentum |
| **Bearish Engulfing** | Prior bullish candle engulfed by current bearish candle | Bearish momentum |

> **Important:** Candlestick patterns are explanatory only — they do NOT override the deterministic trend/confidence.

### Alignment Classification

After all 3 timeframes are merged:

| Alignment | Condition | Confidence Impact |
|---|---|---|
| `all_aligned` | All 3 TFs agree on direction | Highest confidence boost |
| `htf_mtf_aligned` | HTF + MTF agree | Moderate boost |
| `mtf_ltf_aligned` | MTF + LTF agree | Minor boost |
| `mixed` | No 2 TFs agree | Confidence penalty |

---

## 6. Phase 3 — Option Selection & Candidate Scoring

### 6.1 Dual-Candidate Pipeline

Unlike a human who may default to their bias, the system evaluates **both sides equally**:

```
Signal Payload
    │
    ▼
Derive Option Intent
    │
    ├─→ CALL candidate (option_intent.right = "call")
    │       │
    │       ▼
    │   Get Contracts → Shortlist → Snapshots → Liquidity Check
    │
    └─→ PUT candidate (option_intent.right = "put")
            │
            ▼
        Get Contracts → Shortlist → Snapshots → Liquidity Check
            │
            ▼
        Compare Candidates (both sides scored together)
```

### 6.2 Contract Selection Parameters

| Parameter | Default | Description |
|---|---|---|
| `exp_gte` / `exp_lte` | Next business day | Near-term expiry for maximum gamma |
| `strike_mode` | `near_atm` | Focus on ATM strikes for best delta/liquidity |
| `strike_count` | 8 | Number of strikes to consider around ATM |
| `min_oi` | 0 | Minimum open interest filter |
| `max_spread_pct` | 1% (shortlist), 2% (liquidity gate) | Maximum bid-ask spread percentage |

### 6.3 Candidate Scoring Algorithm

The Compare Candidates node scores each side using a lexicographic priority:

```
Score = passOk(1M) + liqOk(100K) + sideMatch(10K) + rrRank + spRank + oiRank

Priority order (highest to lowest):
1. candidate_pass (boolean)     — Did the contract pipeline succeed?
2. option_liquidity_ok (boolean) — Is the spread within limits?
3. sideMatch (boolean)          — Does it match the desired side from trend?
4. option_risk_reward (number)  — Higher R:R is better
5. option_spread_pct (number)   — Lower spread is better (inverted)
6. open_interest (number)       — Higher OI is better
```

### 6.4 Desired Side Determination

The "desired side" is inferred from signals (not from AI):

```
Priority order:
1. winner_side / desired_side (explicit upstream)
2. technical_bias_pre (bearish → PUT, bullish → CALL)
3. trend_direction_pre (downtrend → PUT, uptrend → CALL)
4. derived_right from DMI vote (majority DI direction across TFs)
5. null → no preference
```

---

## 7. Phase 4 — AI Analysis & Decision Gate

### 7.1 Enrich Payload for AI

Merges all upstream context into a single payload:

- **Intervals**: DMI/ADX per timeframe with normalized DeMark data
- **Price context**: Swing levels + ATR from HTF/MTF/LTF
- **Option context**: Selected contract, quote (bid/ask/mid/spread%), greeks (delta/gamma/theta/vega/IV)
- **Computed levels**: Trigger price, invalidation level, target level
- **Option premiums**: Entry, stop (ATR 0.8×), take-profit (ATR 1.6×), R:R ratio
- **Gates**: time_gate_ok, option_liquidity_ok, candidate_pass

### 7.2 Deterministic Trend & Confidence

**Computed BEFORE AI — AI cannot override:**

```
confidence_pre = base(0.40-0.45)
    + strength_component(0..0.40)     [based on DI spread]
    + adx_bonus(0.05)                 [if HTF ADX > 25]
    + td_adjustment(-0.05..+0.03)     [penalize opposing TD completion]

Range: 0.00 — 1.00
```

### 7.3 AI Indicator Analyst

**Model:** GPT-4.1-mini with Calculator tool and Buffer Window memory

**Input:** Full enriched payload as JSON

**Output constraints (STRICT):**
- Must use `*_pre` fields for trend/strength/confidence (copy-through only)
- Must not change `option_contract_symbol`, `desired_option_right`, or premium levels
- Must force `WAIT` if: time_gate_ok=false, option_liquidity_ok=false, RR < 0.6, or side mismatch
- Allowed to output: `key_factors[]`, `plain_explanation`, explanatory text only

**Required output sections:**
- TD Sequential status per timeframe
- Hammer / Shooting Star / Engulfing status per timeframe
- Option trade plan (decision + contract + premium levels)

### 7.4 Confidence Gate (If1 Node + Switch Node)

#### If1 Node — Pre-AI Gate

The `If1` node checks `confidence_pre > 0.65` **before** the AI Indicator Analyst runs:

| Branch | Condition | Path |
|---|---|---|
| TRUE | confidence ≥ 65% | → AI Indicator Analyst → Normalize Confidence → Switch → Orchestrator |
| FALSE | confidence < 65% | → **Save Signal Snapshot → Orchestrator** (bypass AI analysis) |

> **Critical Design:** The FALSE branch routes directly to `Save Signal Snapshot`,
> bypassing AI Indicator Analyst, Normalize Confidence, and Output Telegram.
> This ensures the orchestrator **always runs** and can make EXIT / REDUCE / REVERSE
> decisions on existing positions even when the current signal has low confidence.
> Without this, a position could go unmanaged when signals weaken.

#### Save Signal Snapshot — Cascading Fallback

The `Save Signal Snapshot` node uses a 4-level fallback to find its input data:

```
1. $('Output Telegram')         — high-confidence path (AI ran, Telegram sent)
2. $('Normalize Confidence')    — AI ran but Switch didn't route to Telegram
3. $('Enforce Desired Right')   — low-confidence path (If1 FALSE, AI never ran)
4. $json                        — direct input fallback
```

A `_source_path` field is included in the output for debugging which path was taken.

#### Switch Node — Telegram Routing (High-Confidence Path Only)

| Route | Condition | Path |
|---|---|---|
| Output 0 | AUTO mode + confidence ≥ 65% | → Telegram notification + Orchestrator |
| Output 1 | MANUAL mode (any confidence) | → Telegram notification + Orchestrator |
| Output 2 | confidence ≥ 65% (any mode) | → Telegram notification + Orchestrator |
| Fallback | confidence < 65% in AUTO | → Telegram WAIT notification only |

#### Orchestrator Confidence Rules (Downstream)

The confidence gate only controls **new entries**, not position management:

| Decision Type | Confidence Requirement |
|---|---|
| NEW_ENTRY / ADD_POSITION | Require ≥ 0.65 (enforced by orchestrator) |
| EXIT / REDUCE_EXPOSURE / REVERSE | **Allowed at any confidence** |
| CONFIRM_HOLD / WAIT | **Allowed at any confidence** |

---

## 8. Phase 5 — Orchestrated Trade Lifecycle

### 8.1 Context Assembly

Before making a decision, the orchestrator gathers 8 SQL queries worth of context:

| Query | Source Table/View | Purpose |
|---|---|---|
| Signal history | `signal_snapshots` | Last N signals for this ticker today |
| Active positions | `v_active_positions` | Current open positions |
| Confirmation streaks | `v_confirmation_streaks` | How many consecutive confirms/contradicts |
| Recent executions | `order_executions` | Recent order results |
| Broker positions | `v_broker_positions_latest` | Real Alpaca positions |
| Broker open orders | `v_broker_open_orders_latest` | Pending Alpaca orders |
| Evaluation feedback | `v_evaluation_feedback` | Past trade grades + lessons |
| Recent decisions | `trading_decisions` | Decision log |

### 8.2 Broker State Synchronization

Before every orchestration decision:

```
1. GET /v2/positions → INSERT into trading.broker_positions
2. GET /v2/orders?status=open → INSERT into trading.broker_open_orders
3. Orchestrator reads v_broker_positions_latest + v_broker_open_orders_latest
4. Reconciles with position_journal in reasoning
```

### 8.3 Decision Types

| Decision | When Used | Action |
|---|---|---|
| **NEW_ENTRY** | No existing position, signals confirm direction, confidence ≥ 0.65 | → Size → Order → Execute |
| **CONFIRM_HOLD** | Existing position, signals still confirm direction | → Log + Telegram |
| **ADD_POSITION** | Existing position strengthening, want more exposure | → Size → Order → Execute |
| **REDUCE_EXPOSURE** | Signals weakening but not reversed | → Sell to Close (partial) |
| **REVERSE** | Signals flipped direction entirely | → Close all → Re-enter opposite |
| **EXIT** | Invalidation hit, TD exhaustion, or adverse signal | → Close all positions |
| **WAIT** | No actionable signal, stay flat | → Log + Telegram |

### 8.4 Three-Confirmation Entry Strategy

```
Signal 1 (conf ≥ 0.65, direction clear):
    → OBSERVE (log signal, do not trade)

Signal 2 (confirms Signal 1 direction):
    → BUILDING_CONVICTION (log confirmation streak = 1)

Signal 3 (still confirms):
    → CONFIRMED_ENTRY → NEW_ENTRY decision

Override: If confidence ≥ 0.85 AND all_aligned:
    → Skip straight to NEW_ENTRY on first signal
```

---

## 9. Phase 6 — Order Execution & Fill Management

### 9.1 Position Sizing (Conviction-Based)

```
Conviction Score (0-10) computed from:
  +2  alignment = all_aligned
  +1  alignment = htf_mtf_aligned
  +2  confidence ≥ 80%
  +1  confidence ≥ 70%
  +1  ADX confirmation (HTF ADX > 25)
  +1  trend_strength = strong/very_strong
  +1  option R:R ≥ 2.0
  +1  spread < 0.5%
  +1  consecutive confirms ≥ 3
  +1  TD early setup (count 1-4)

Tier Mapping:
  Score 0-3:  REGULAR        → 1× risk budget  → 1-3 contracts
  Score 4-6:  SIZABLE        → 2× risk budget  → 3-5 contracts
  Score 7+:   MAX_CONVICTION → 3× risk budget  → 5-10 contracts

Base Risk Budget:
  maxRiskUsd = equity × 0.5% (default)
  qty = floor(effectiveRisk / riskPerContract)
  riskPerContract = (entry_premium - stop_premium) × 100

Hard Cap: 10 contracts maximum
Buying Power Guard: qty reduced if total cost > buying power
```

### 9.2 Order Construction

```json
{
  "symbol": "SPY260223C00600000",    // OCC option symbol
  "qty": "3",                         // number of contracts
  "side": "buy",
  "type": "limit",                    // limit or market
  "time_in_force": "day",
  "order_class": "simple",
  "position_intent": "buy_to_open",
  "limit_price": "2.45"              // entry premium
}
```

**Order submission flow:**
```
Parse Order Payload → If Order OK? → Submit Order (POST /v2/orders)
    → Normalize Order → Build Persist SQL → Persist ORDER (order_executions)
    → Insert row (legacy workflow_decisions) → Telegram notification
```

### 9.3 Order Execution Recording

Every order submission is persisted in `trading.order_executions`:

| Field | Source |
|---|---|
| `alpaca_order_id` | Alpaca response `id` |
| `alpaca_status` | Alpaca response `status` (new/accepted/filled/cancelled) |
| `submitted_price` | limit_price from order payload |
| `fill_price` | From Alpaca response (if filled) |
| `submitted_qty` / `filled_qty` | From order payload / Alpaca response |

---

## 10. Phase 7 — Position Monitoring & Risk Management

### 10.1 Current Monitoring Architecture

| Mechanism | Interval | Description |
|---|---|---|
| AUTO signal loop | Every 5 min | Full indicator re-analysis → orchestrator decision |
| MANUAL Telegram | On-demand | Human triggers `<TICKER> <PROFILE>` for immediate re-analysis |
| Broker state sync | Every orchestrator run | Real Alpaca positions/orders fetched and stored |

### 10.2 Stop-Loss and Take-Profit Levels

Computed at entry from ATR(14) on option bars:

```
option_stop_premium    = entry_premium - (0.8 × ATR)
option_take_profit     = entry_premium + (1.6 × ATR)
option_risk_reward     = (TP - entry) / (entry - stop)
```

These are stored in `position_journal.current_stop` and `position_journal.current_tp`.

### 10.3 Risk Gates (Pre-Order)

Before any order reaches the broker, these gates must pass:

| Gate | Condition | Action on Fail |
|---|---|---|
| Time Gate | Market is open (Alpaca `/v2/clock`) | Force WAIT |
| Liquidity Gate | Spread ≤ max_spread_pct (default 2%) | Force WAIT |
| Confidence Gate | confidence ≥ 0.65 for entries | Skip orchestrator |
| R:R Gate | option_risk_reward ≥ 0.6 | Force WAIT |
| Side Mismatch Gate | desired_right matches trend direction | Force WAIT |
| Candidate Pass Gate | Option contract successfully selected | Force WAIT |

### 10.4 Known Monitoring Gaps (Planned Improvements)

| Gap | Impact | Planned Solution |
|---|---|---|
| No continuous price monitoring | Stop can be blown between 5-min intervals | Position Monitor workflow (1-min poll) |
| No bracket orders | Stop/TP not at broker level | Alpaca bracket order support |
| No trailing stops | Profitable positions can reverse | Update `current_stop` on CONFIRM_HOLD |
| No EOD liquidation | Positions can carry overnight | Force-close node at 15:50 ET |
| No daily loss limit | Unlimited daily drawdown | Risk Manager node with -$500/-2% circuit breaker |

---

## 11. Phase 8 — Exit Execution

### 11.1 Signal-Driven Exit (Currently Implemented)

The orchestrator can trigger EXIT through multiple paths:

#### EXIT Path
```
Decision Router (output 5: EXIT)
    → Prepare EXIT (build close-position payload with contract symbol)
    → Close Position (DELETE /v2/positions/{symbol})
    → Format EXIT Result (success/failure Telegram)
    → Build EXIT Persist SQL
    → Persist EXIT (order_executions + position_journal update)
    → Telegram EXIT notification
    → Gather Trade Data → Trade Evaluation Pipeline
```

#### REDUCE_EXPOSURE Path
```
Decision Router (output 3: REDUCE_EXPOSURE)
    → Prepare REDUCE (build sell_to_close payload)
    → Sell to Close (POST /v2/orders with sell_to_close)
    → Format REDUCE Result
    → Persist REDUCE
    → Telegram REDUCE + Gather Trade Data → Evaluation
```

#### REVERSE Path
```
Decision Router (output 4: REVERSE)
    → Prepare REVERSE Close → Close Position
    → Format REVERSE Close → Persist REVERSE
    → Telegram REVERSE Close
    → If REVERSE Close OK? → HTTP Account (get fresh balance)
    → Re-enter opposite side (same pipeline as NEW_ENTRY)
```

### 11.2 Exit Triggers

| Trigger | Detection Method | Decision Type |
|---|---|---|
| Invalidation level hit | Orchestrator compares current price vs `invalidation_level` | EXIT |
| TD Sequential exhaustion | Countdown reaches 13 in opposing direction | EXIT |
| All TFs flip direction | DMI direction changes across all timeframes | REVERSE |
| Signal weakening | Majority TFs contradict, but not fully flipped | REDUCE_EXPOSURE |
| Manual exit | Human sends signal via Telegram, orchestrator decides | EXIT |

---

## 12. Phase 9 — Post-Trade Evaluation & Learning

### 12.1 Trade Evaluation Pipeline

Triggered automatically after every EXIT, REDUCE, or REVERSE:

```
1. Gather Trade Data — SQL query joining:
   - position_journal (entry/exit prices, qty, timestamps)
   - order_executions (actual fills)
   - trading_decisions (reasoning, confidence at entry)

2. Compute Trade P&L:
   - price_change = exit_price - entry_price
   - pnl_per_contract = price_change × 100
   - pnl_total = pnl_per_contract × qty
   - outcome = WIN / LOSS / BREAKEVEN
   - hold_duration = exit_time - entry_time

3. AI Trade Evaluator (GPT-4.1-mini):
   - Signal quality assessment (was the signal actually good?)
   - Timing quality (entered too early? too late?)
   - Risk management quality (stop respected? position sized well?)
   - Overall grade: A / B / C / D / F
   - Score: 0-100
   - lessons_learned: freeform text

4. Persist Evaluation → trading.trade_evaluations

5. Telegram notification with evaluation summary
```

### 12.2 Feedback Loop

The orchestrator reads past evaluations via `v_evaluation_feedback`:

```sql
-- Recent evaluations for context
SELECT ticker, evaluation_grade, score, lessons_learned,
       signal_quality, timing_quality, risk_management_quality
FROM trading.trade_evaluations
WHERE ticker = $1
ORDER BY evaluated_at DESC
LIMIT 5;
```

**Learning rules in orchestrator prompt:**
- If last 3 trades graded D/F with "entered too late" → increase trigger sensitivity
- If last 3 trades graded D/F with "stop too tight" → widen ATR multiplier
- If recent evaluations show consistent pattern → adjust behavior

---

## 13. Phase 10 — End-of-Day Reconciliation

### Current Implementation

| Step | Status | Description |
|---|---|---|
| Session tracking | ✅ | `trading_sessions` with ACTIVE/CLOSED status |
| Position journal | ✅ | OPEN/CLOSED status per position |
| Broker sync | ✅ | `broker_positions` / `broker_open_orders` populated per run |
| Reconciliation | ⚠️ Advisory only | Orchestrator notes discrepancies in reasoning text |
| EOD force-close | ❌ Not implemented | No automated position closing before market close |
| Daily P&L summary | ❌ Not implemented | No aggregate daily performance report |

### Planned EOD Workflow

```
15:50 ET Trigger:
    → Fetch all OPEN positions from position_journal
    → For each: Submit EXIT via DELETE /v2/positions/{symbol}
    → Update position_journal.status = 'CLOSED', close_reason = 'SESSION_CLOSE'
    → Trigger evaluation for each closed position
    → Send daily summary to Telegram
    → Update trading_sessions.status = 'CLOSED'
```

---

## 14. Data Model

### Entity Relationship

```
trading_sessions (1)
    │
    ├── signal_snapshots (N)        ── "The tape" of all indicator readings
    │       │
    │       └── trading_decisions (N)   ── Every orchestrator decision
    │               │
    │               ├── decision_confirmations (N)  ── Confirm/contradict tracking
    │               │
    │               └── position_journal (N)         ── Virtual position lifecycle
    │                       │
    │                       └── order_executions (N)  ── Every Alpaca API call
    │
    └── trade_evaluations (N)       ── Post-trade AI critiques
    
broker_positions (snapshot)         ── Real Alpaca positions (latest)
broker_open_orders (snapshot)       ── Real Alpaca pending orders (latest)
```

### Key Tables

| Table | Rows/Day (est.) | Purpose |
|---|---|---|
| `trading_sessions` | 1-3 | One per ticker+profile+day |
| `signal_snapshots` | 50-100 | Every 5-min signal run |
| `trading_decisions` | 10-30 | Every orchestrator decision |
| `decision_confirmations` | 10-30 | Confirm/contradict per decision |
| `position_journal` | 2-10 | Each position open/close |
| `order_executions` | 2-10 | Each order submitted |
| `trade_evaluations` | 2-5 | Each closed position evaluated |
| `broker_positions` | 50-100 | Snapshot per sync |
| `broker_open_orders` | 50-100 | Snapshot per sync |

### Key Views

| View | Purpose |
|---|---|
| `v_active_positions` | Current open positions with decision context |
| `v_confirmation_streaks` | Running confirm/contradict counts per decision |
| `v_broker_positions_latest` | Most recent broker position snapshot |
| `v_broker_open_orders_latest` | Most recent broker open orders |
| `v_evaluation_feedback` | Recent evaluations for orchestrator learning |
| `v_recent_executions` | Recent order execution results |
| `v_recent_evaluations` | Recent trade evaluations |

---

## 15. Risk Management Framework

### 15.1 Per-Trade Risk

| Parameter | Default | Description |
|---|---|---|
| Max risk per trade | 0.5% of equity | Base risk budget |
| Max contracts | 10 | Hard cap regardless of conviction |
| Stop-loss | Entry - 0.8 × ATR(14) | Option premium floor |
| Take-profit | Entry + 1.6 × ATR(14) | Option premium target |
| Min R:R | 0.6 | Force WAIT below this (way too low) |
| Max spread | 2% | Liquidity gate |
| Min confidence | 65% | Entry gate (AUTO mode) |

### 15.2 Conviction-Based Scaling

```
Account equity: $10,000
Base risk: $50 (0.5%)
Entry premium: $2.50
Stop premium: $2.00
Risk per contract: ($2.50 - $2.00) × 100 = $50

REGULAR   (score 0-3): $50 / $50  = 1 contract
SIZABLE   (score 4-6): $100 / $50 = 2 contracts
MAX_CONV  (score 7+):  $150 / $50 = 3 contracts
```

### 15.3 Safety Gates Summary

```
┌─────────────────────────────────────────┐
│              ORDER SUBMISSION            │
│                                          │
│  ✓ Market is open (time_gate_ok)         │
│  ✓ Spread ≤ 2% (option_liquidity_ok)     │
│  ✓ Confidence ≥ 65% (for entries)        │
│  ✓ R:R ≥ 0.6 (option_risk_reward)        │
│  ✓ Side matches trend direction           │
│  ✓ Contract selected (candidate_pass)     │
│  ✓ Buying power sufficient                │
│  ✓ Qty ≤ 10 (hard cap)                   │
│  ✓ No duplicate pending orders (broker)   │
│                                          │
│  ANY FAIL → Force WAIT                   │
└─────────────────────────────────────────┘
```

---

## 16. Notification & Alerting

### Telegram Message Structure

Every signal run produces a structured Telegram notification:

```
Options Multi-TF Summary
Ticker: SPY
Timeframes: multi_2m_3m_5m
Direction: uptrend
Strength: moderate (score 45)
Alignment: all_aligned
ADX confirmation: confirmed
Bias: bullish
Confidence: 72%
Underlying Levels: Trigger: 600.25 | Invalidation: 598.50 | Target: 602.75

🕯 Candles (Hammer / BullEngulf / BearEngulf / ShootingStar)
2m: Hammer=none | BullEngulf=none | BearEngulf=none | ShootingStar=none
3m: Hammer=none | BullEngulf=bullish_engulfing ✅ | BearEngulf=none | ShootingStar=none
5m: Hammer=none | BullEngulf=none | BearEngulf=none | ShootingStar=none

🗺 Candidate Compare
Desired: CALL | technical_bias_pre_or_bias
Winner: CALL
Why: RR: CALL=2.15 vs PUT=1.43 (higher wins → CALL)
CALL: CALL | SPY260224C00600000 | pass=true | score=1100025 | spread%=0.82% | RR=2.15 | Δ +0.520 | liq=true | quoteAge=3s
PUT:  PUT  | SPY260224P00600000 | pass=true | score=1100012 | spread%=1.05% | RR=1.43 | Δ -0.480 | liq=true | quoteAge=5s

🧾 Option Trade Plan
Decision: 🟢 BUY_CALL @ SPY260224C00600000
Quote: Right: call | Bid: 2.40 | Ask: 2.50 | Mid: 2.450 | Spread%: 0.82%
Entry: 2.50 | Stop: 2.10 | TP: 3.30 | R:R 2.15

Key factors:
• prompt_version=TDv3
• DI+ > DI- on all 3 TFs (all_aligned bullish)
• ADX 5m=28.3 > 25 (confirmed)
• TD 5m: setup=bullish 3/9
• Engulfing 3m: bullish_engulfing

Explanation: DI alignment bullish across 2m/3m/5m...
```

### Notification Types

| Event | Channel | Content |
|---|---|---|
| Signal analysis | Telegram | Full multi-TF summary + option trade plan |
| Validation mismatch | Telegram (separate) | Bias vs right inconsistency alert |
| NEW_ENTRY order | Telegram | Order submitted + contract + qty + price |
| CONFIRM_HOLD | Telegram | Holding position, streak count |
| REDUCE/EXIT/REVERSE | Telegram | Position closed + P&L summary |
| Trade evaluation | Telegram | Grade + score + lessons learned |
| Chart image | Telegram | TradingView chart via chart-img.com API |

---

## 17. Configuration & Tuning Parameters

### Indicator Parameters

| Parameter | Value | Location |
|---|---|---|
| DMI Period | 14 | Code nodes (hardcoded) |
| Swing Lookback | 20 bars | Code nodes (hardcoded) |
| ATR Lookback | 14 bars | Code nodes (hardcoded) |
| Hammer body threshold | ≤ 35% of range | `computeHammer()` |
| Hammer lower wick min | ≥ 2× body | `computeHammer()` |
| Engulfing body requirement | Current ≥ prior | `computeBullishEngulfing()` |

### Option Selection Parameters

| Parameter | Value | Location |
|---|---|---|
| Default expiry | Next business day | `Derive Option Intent` |
| Strike count | 8 (near ATM) | `Derive Option Intent` |
| Max spread (shortlist) | 1% | `Select Contract (Shortlist)` |
| Max spread (liquidity gate) | 2% | `Select Contract (Liquid)` |
| Max quote age | 120 seconds | `Select Contract (Liquid)` |
| Snapshot limit | 100 contracts per side | `Get Option Snapshots` |

### Orchestration Parameters

| Parameter | Value | Location |
|---|---|---|
| Entry confidence threshold | 65% | Switch node |
| Override entry confidence | 85% + all_aligned | Orchestrator prompt |
| Confirmation count for entry | 3 | Orchestrator prompt |
| R:R force-WAIT threshold | < 0.6 | AI Analyst + Orchestrator |
| AI model | GPT-4.1-mini | All 4 agent nodes |

### Sizing Parameters

| Parameter | Value | Location |
|---|---|---|
| Base risk % | 0.5% of equity | `Compute Size` |
| Max qty cap | 10 contracts | `Compute Size` |
| REGULAR multiplier | 1× | Conviction score 0-3 |
| SIZABLE multiplier | 2× | Conviction score 4-6 |
| MAX_CONVICTION multiplier | 3× | Conviction score 7+ |
| Option tick size | $0.01 | `Parse Order Payload` |

---

## 18. Deployment Architecture

### Infrastructure (Docker Compose)

```yaml
services:
  postgres:
    image: postgres:15
    ports: "5433:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ../sql:/docker-entrypoint-initdb.d     # Auto-runs migrations

  n8n:
    image: n8nio/n8n:latest
    ports: "5678:5678"
    depends_on: postgres (healthy)
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
```

### Database Migrations (execution order)

| File | Purpose |
|---|---|
| `000_create_day_trade_db.sh` | Create `day_trade` database |
| `001_trading_orchestration.sql` | Core schema: sessions, snapshots, decisions, confirmations, journal |
| `002_widen_numeric_columns.sql` | Widen NUMERIC precision for confidence/RR |
| `003_cleanup_database.sql` | Database maintenance |
| `004_order_executions.sql` | Order execution tracking table |
| `005_trade_evaluations.sql` | Post-trade evaluation table |
| `006_broker_state_and_eval_feedback.sql` | Broker sync tables + evaluation feedback view |

### External Dependencies

| Service | Purpose | API |
|---|---|---|
| **Alpaca** (paper) | Broker: orders, positions, market data | REST API (paper-api.alpaca.markets) |
| **Alpaca** (data) | Stock bars, option contracts/snapshots | REST API (data.alpaca.markets) |
| **OpenAI** | AI agents (4 GPT-4.1-mini instances) | Chat Completions API |
| **Yahoo Finance** | Ticker resolution | Search API |
| **Telegram** | Notifications + manual triggers | Bot API |
| **chart-img.com** | TradingView chart images | Exchange resolution API |

---

## 19. Operational Runbook

### Starting the System

```bash
cd docker/
docker-compose up -d

# Verify services
docker-compose ps
docker-compose logs -f n8n
```

### Manual Trade Trigger

Send a Telegram message to the configured bot:
```
SPY S       # SPY with Scalp profile (2m/3m/5m)
AAPL M      # AAPL with Medium profile (1m/5m/15m)
TSLA L      # TSLA with Long profile (5m/1h/1d)
QQQ         # QQQ with default Scalp profile
```

### Monitoring Checklist

| Check | Frequency | How |
|---|---|---|
| Workflow execution status | Continuous | n8n Executions page (localhost:5678) |
| Telegram notifications | Every signal | Watch Telegram chat |
| Open positions | Every 5 min | `SELECT * FROM trading.v_active_positions;` |
| Broker reconciliation | Hourly | Compare `v_broker_positions_latest` vs `v_active_positions` |
| Daily P&L | End of day | `SELECT SUM(pnl_total) FROM trading.position_journal WHERE trade_date = CURRENT_DATE;` |
| Evaluation grades | End of day | `SELECT * FROM trading.trade_evaluations WHERE evaluated_at::date = CURRENT_DATE;` |

### Useful SQL Queries

```sql
-- Today's trading decisions
SELECT decision_time, ticker, decision_type, direction,
       orchestration_confidence, reasoning
FROM trading.trading_decisions
WHERE trade_date = CURRENT_DATE
ORDER BY decision_time DESC;

-- Current confirmation streaks
SELECT * FROM trading.v_confirmation_streaks
WHERE trade_date = CURRENT_DATE;

-- Recent order executions
SELECT * FROM trading.order_executions
WHERE created_at::date = CURRENT_DATE
ORDER BY created_at DESC;

-- Open positions with current stops/targets
SELECT ticker, side, contract_symbol, entry_price,
       current_stop, current_tp, qty, status
FROM trading.position_journal
WHERE status = 'OPEN';

-- Today's evaluations
SELECT ticker, evaluation_grade, score,
       signal_quality, timing_quality,
       risk_management_quality, lessons_learned
FROM trading.trade_evaluations
WHERE evaluated_at::date = CURRENT_DATE;
```

### Emergency Procedures

| Scenario | Action |
|---|---|
| **Runaway position** | Manual Alpaca dashboard: close all positions |
| **Workflow stuck** | n8n: cancel execution, check logs |
| **Broker API down** | System will `continueOnFail` — check Telegram for error notifications |
| **AI API down** | Workflow will fail at agent nodes — no orders will be placed |
| **Database full** | Check `docker-compose logs postgres`, prune old data |

---

## Summary

This system implements a **complete AI-augmented option day trading lifecycle** that mirrors how a disciplined human trader operates:

| Phase | Human Equivalent | System Components |
|---|---|---|
| **Scan** | Looking at charts | 3-TF indicator pipeline (DMI + TD + candles) |
| **Analyze** | Forming a view | AI Indicator Analyst + deterministic confidence |
| **Select** | Picking the trade | Dual-candidate option pipeline + scoring |
| **Validate** | Double-checking | Report validation + safety gates |
| **Decide** | Pulling the trigger | Orchestrator with 3-confirmation strategy |
| **Size** | Choosing lot size | Conviction-based sizing (REGULAR/SIZABLE/MAX) |
| **Execute** | Placing the order | Alpaca order submission + persistence |
| **Monitor** | Watching the screen | 5-min signal loop + broker state sync |
| **Exit** | Taking profit / cutting loss | 3 exit paths (EXIT/REDUCE/REVERSE) |
| **Review** | Journaling | AI Trade Evaluator + grades + lessons learned |
| **Learn** | Improving over time | Evaluation feedback loop → orchestrator context |

The system currently handles **14 core workflow nodes** across **~3,950 lines of workflow JSON** and **7 SQL migrations**, with **4 AI agents** (Analyst, Orchestrator, Evaluator, Validator) coordinated through a deterministic pipeline that ensures AI augments but never overrides the systematic trading rules.
