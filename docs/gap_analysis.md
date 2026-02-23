# Day Trade Workflow — Gap Analysis# Gap Analysis: What's Missing to Trade Like a Human Option Day Trader



> **Date**: 2025-01-20> **Date:** 2026-02-22  

> **Workflow**: `day_trade.json` — "Alpaca Option MultiTF DMI/TD (1m/15m/60m)"> **Scope:** Alpaca Option MultiTF DMI/TD workflow — n8n + Postgres + AI agents

> **Methodology**: Exhaustive line-by-line review of the entire workflow JSON (3,951 lines), all 7 SQL migrations, docker-compose.yml, and connection graph.

---

---

## Current Architecture Summary

## System Architecture Summary

| Layer | What Exists | Agent / Component |

| Layer | Technology | Role ||-------|-------------|-------------------|

|---|---|---|| **Analytics** | Multi-TF DMI/ADX, TD Sequential, candlestick patterns (hammer, engulfing, shooting star), swing/ATR price structure | `AI Indicator Analyst` + deterministic code nodes |

| Orchestration | n8n (self-hosted via Docker) | Workflow engine || **Orchestration** | Signal snapshots → trading decisions (NEW_ENTRY, CONFIRM_HOLD, ADD_POSITION, REDUCE, REVERSE, EXIT, WAIT), position journal, confirmation streaks | `Orchestrator Agent` + Postgres tables |

| Broker | Alpaca (paper trading) | Options order execution, market data, positions, account || **Order Execution** | Parse order payload → Alpaca `/v2/orders` (buy_to_open, limit/market), order_executions logging | `Parse Order Payload` + `Submit Order` |

| AI (Analysis) | OpenAI GPT-4.1-mini — AI Indicator Analyst | Multi-TF indicator analysis, option decision || **Evaluation** | Post-trade critique: P&L, grade A–F, signal/timing/risk quality, lessons learned | `Trade Evaluation Agent` + `trade_evaluations` table |

| AI (Orchestration) | OpenAI GPT-4.1-mini — AI Decision Orchestrator | Trade lifecycle decisions (entry/hold/exit) || **Notification** | Telegram alerts with multi-TF summary, candidate compare, trade plan | `Output Telegram` + `Send a text message` |

| AI (Evaluation) | OpenAI GPT-4.1-mini — AI Trade Evaluator | Post-trade critique, grading, lessons learned || **Broker Sync** | `broker_positions`, `broker_open_orders` tables + latest views | SQL migration 006 (schema exists, sync implementation unclear) |

| AI (Verification) | OpenAI GPT-4.1-mini — Day Trade Report Validation | Consistency checks on analysis reports |

| Database | PostgreSQL 15 | Signal snapshots, decisions, positions, executions, evaluations, broker sync |---

| Notifications | Telegram Bot | Manual trigger + structured notifications |

| Market Data | Yahoo Finance | Ticker symbol resolution |## 🔴 Critical Gaps — A Human Trader Would Never Skip These



---### 0. ~~If1 Low-Confidence Dead End~~ ✅ RESOLVED (2026-02-23)

**Status:** **FIXED.** The `If1` node (confidence_pre > 0.65 gate) previously had an **empty false branch** (`[]`), which meant the entire workflow terminated when confidence < 65%. This was a critical safety gap:

- The AI Indicator Analyst, Normalize Confidence, Output Telegram, Save Signal Snapshot, and the **entire Orchestrator pipeline** (including EXIT, REDUCE_EXPOSURE, REVERSE decisions) would never run.
- If a position was open and signals weakened (confidence dropped below 65%), the system was **completely blind** — no exit management, no risk reduction, nothing.

**Fix applied:**
1. **Wired `If1` false branch → `Save Signal Snapshot`** — bypasses AI Indicator Analyst (not needed for low-confidence position management) and routes directly to the orchestrator pipeline.
2. **Updated `Save Signal Snapshot` cascading fallback** — now tries 4 sources in order: `Output Telegram` → `Normalize Confidence` → `Enforce Desired Right` (low-conf path) → `$json`. Includes `_source_path` field for debugging.
3. **Orchestrator confidence rules unchanged** — NEW_ENTRY / ADD_POSITION still require ≥ 0.65, but EXIT / REDUCE / REVERSE / CONFIRM_HOLD / WAIT are allowed at any confidence level.

### 1. ~~Position Exit Management Agent~~ ✅ RESOLVED



## What Currently Works (Verified ✅)**Status:** The workflow **already has automated exit execution**. The Decision Router routes EXIT decisions through a complete execution path:

1. `Prepare EXIT` → builds close-position payload with contract symbol

### 1. Multi-Timeframe Indicator Pipeline ✅2. `Close Position (EXIT)` → calls `DELETE /v2/positions/{symbol}` on Alpaca API

- **3 profiles**: S (2m/3m/5m scalp), M (1m/5m/15m medium), L (5m/1h/1d long)3. `Format EXIT Result` → builds Telegram notification (success/failure)

- **Telegram trigger** parses `<TICKER> <PROFILE>` (e.g., `SPY S`)4. `Telegram EXIT` → sends notification

- **Schedule trigger** runs every 5 minutes Mon–Fri 12:00–20:00 UTC (AUTO mode)5. `Persist EXIT` → records execution in `order_executions`, updates `position_journal`

- **Market hours check** via Alpaca `/v2/clock` + `/v2/calendar` for AUTO mode6. → triggers Trade Evaluation pipeline

- **Yahoo Finance** ticker resolution before data fetch

- **3 parallel Alpaca bar requests** → 3 parallel normalize + indicator pipelinesAdditionally, REDUCE_EXPOSURE and REVERSE paths also submit `sell_to_close` orders to Alpaca.

- **Indicators per TF**: DMI/ADX(14), TD Sequential/DeMark, Hammer, Shooting Star, Bullish Engulfing, Bearish Engulfing, Swing Levels, ATR(14)

- **Merge** combines all 3 TFs → **Build AI Payload** creates unified structure with HTF/MTF/LTF alignment**Remaining sub-gaps (not yet implemented):**

- **Bracket orders** (stop-loss + take-profit) are not set automatically after entry

### 2. Dual-Candidate Options Pipeline ✅- **Trailing stop logic** (e.g., move stop to breakeven after 1R move, trail by ATR)

- **Derive Option Intent** emits 2 items (CALL + PUT candidates), computes strike bounds, next-business-day expiry- **EOD Liquidation Node** to force-close all open positions 5–15 min before market close

- **Get Option Contracts** → **Merge1** → **Select Contract (Shortlist)** — filters by right, expiry, OI, spread- Exits are currently **signal-driven only** (orchestrator must decide EXIT) — there is no independent price-threshold-based exit

- **Get Option Snapshots (Shortlist)** — up to 100 contracts per candidate

- **Merge Snapshots (Keep Input)** → **Select Contract (Liquid)** — picks best by spread + staleness---

- **Compare Candidates** — scores both sides, picks winner using DMI/trend alignment

- **Liquidity OK?** gate with configurable `max_spread_pct` (default 2%)### 2. Real-Time Position Monitoring Loop

- **Force WAIT (Liquidity Gate)** on failure path

**What's missing:** The current workflow is **trigger-based** (Telegram message → one-shot analysis → order). There is no continuous monitoring loop that watches open positions in real-time.

### 3. Option Metrics & Risk Pipeline ✅

- **Enrich Payload for AI** — massive enrichment node merging 6+ upstream sources, TD normalization, greeks, quote, OCC parsing**What a human does:**

- **Compute Option Metrics** — intrinsic/extrinsic, theta cost %, expected move to expiry- Watches positions on a screen continuously

- **Replace Get Option Bars (Selected)** — delta-gamma synthetic stop/TP from underlying levels- Reacts to sudden price moves, news events, or indicator changes

- **Compute Option ATR Stops/TP** — ATR(14) on option bars for stop (0.8× ATR) and TP (1.6× ATR)- Adjusts stops/targets intraday based on evolving price action

- **Compute Trend & Confidence** — deterministic confidence (0–1) from DMI alignment + ADX + TD adjustments

- **Enforce Desired Right** — slims payload, enforces winner side before AI, confidence gate (`> 0.65` to proceed to AI)**Recommendation:**

- Add a **Position Monitor Workflow** (scheduled every 1–2 min) that:

### 4. AI Indicator Analyst ✅  - Fetches current option quotes for all open positions

- GPT-4.1-mini agent with Calculator tool and Buffer Window memory  - Compares current premium vs entry/stop/target

- Detailed system prompt enforcing: deterministic confidence usage, option decision output (BUY_CALL/BUY_PUT/WAIT), key factors, candlestick awareness  - Triggers EXIT/REDUCE decisions when thresholds are hit

- **Normalize Confidence** extracts and clamps AI confidence, preserves deterministic values  - Updates `position_journal` with current unrealized P&L

- Outputs to 3 parallel paths: Output Telegram, Save Signal Snapshot, Switch (confidence gate)

---

### 5. Report Validation Pipeline ✅

- **Day Trade Report Validation** — separate GPT-4.1-mini agent verifies consistency### 3. Account / Portfolio Risk Management

- Checks: bias vs. selected right, gates respected, RR threshold (< 0.6 = critical), indicator contradictions in Telegram text vs. payload

- **Code in JavaScript7** parses AI JSON output**What's missing:** The `Compute Size` node calculates qty but there is no portfolio-level risk enforcement.

- **If3** routes OK vs. MISMATCH → **Render Verification Report** → **Send a text message1** (Telegram)

**What a human does:**

### 6. Trade Sizing & Order Submission ✅- Never risks more than 1–2% of account on a single trade

- **Switch** routes by confidence + mode (3 outputs, all → Output Telegram)- Limits total portfolio exposure (e.g., max 3 simultaneous positions)

- **Output Telegram** → **Send a text message** → **Create Chart ID** → chart image generation- Checks buying power before placing orders

- **HTTP Account** → **Edit Fields** → **Compute Size** — conviction-based tiers:- Reduces size after a losing streak

  - REGULAR: 1–3 contracts- Stops trading after daily loss limit is hit

  - SIZABLE: 3–5 contracts

  - MAX_CONVICTION: 5–10 contracts (capped at 10)**Recommendation:**

- **Parse Order Payload** builds Alpaca options order (`buy_to_open`, limit/market)- Add a **Risk Manager Node** that:

- **If Order1** gates on `order_meta.ok`  - Queries Alpaca account balance / buying power before every order

- **Submit Order** → POST `/v2/orders`  - Enforces max risk per trade (% of account)

- **Normalize Order** → **Build ORDER Persist SQL** → **Persist ORDER** → **Insert row1** (legacy `workflow_decisions`)  - Enforces max concurrent positions

  - Implements **daily loss limit** (e.g., stop trading after -$500 or -2% of account)

### 7. AI Decision Orchestrator ✅  - Implements **daily profit target** (optional: reduce aggression after hitting target)

- **Save Signal Snapshot** — persists signal + builds 8 SQL queries (history, positions, streaks, executions, broker positions, broker open orders, evaluation feedback)  - Tracks win rate and adjusts sizing dynamically

- **Sync Broker State** — fetches real Alpaca positions + open orders via `fetch()`, inserts into `broker_positions` / `broker_open_orders`

- **Persist Broker State** → **Query Decision History** — executes all 8 SQL queries in one Postgres call---

- **Build Orchestrator Context** — `runOnceForAllItems` to prevent fan-out, classifies Postgres rows into 7 context buckets

- **AI Decision Orchestrator** — GPT-4.1-mini agent with comprehensive system prompt:### 4. Volume / VWAP / Market Microstructure Analysis

  - 7 decision types: NEW_ENTRY, CONFIRM_HOLD, ADD_POSITION, REDUCE_EXPOSURE, REVERSE, EXIT, WAIT

  - 3-confirmation entry strategy (OBSERVE → BUILDING_CONVICTION → CONFIRMED_ENTRY)**What's missing:** The analytics agent uses DMI/ADX, TD Sequential, and candlestick patterns, but has **no volume analysis**.

  - Override entry at confidence ≥ 0.85 with strong alignment

  - Confidence gate: NEW_ENTRY/ADD_POSITION require ≥ 0.65; EXIT/REVERSE/REDUCE allowed at any confidence**What a human does:**

  - Broker state awareness (real positions, pending orders, duplicate prevention)- Checks if a move is backed by volume (volume confirmation)

  - Past evaluation learning (avoid D/F patterns)- Uses VWAP as intraday support/resistance

- **Save Orchestration Decision** — `runOnceForAllItems`, parses AI output, builds SQL for `trading_decisions` + `decision_confirmations` + `position_journal`, suppresses duplicate Telegram for WAIT/CONFIRM_HOLD- Watches for volume spikes at key levels

- **Persist Decision** + **Suppress Dup Telegram** → **Orchestration Telegram**- Avoids low-volume choppy periods (lunch hour 11:30–1:30 ET)



### 8. Decision Router & Execution Paths ✅**Recommendation:**

**Decision Router** (Switch with 8 outputs):- Add **VWAP calculation** per timeframe

- Add **relative volume** indicator (current volume vs. average at this time of day)

| Output | Decision Type | Execution Path |- Add **volume-price divergence** detection (price making new highs on declining volume → bearish)

|---|---|---|- Add **time-of-day filter** to reduce noise during low-volume periods

| 0 | NEW_ENTRY | → HTTP Account → Edit Fields → Compute Size → Parse Order → Submit Order → Persist ORDER |

| 1 | CONFIRM_HOLD | → Notify CONFIRM_HOLD → Build HOLD Persist SQL → Persist HOLD → Telegram CONFIRM_HOLD |---

| 2 | ADD_POSITION | → HTTP Account → Edit Fields → Compute Size → Parse Order → Submit Order → Persist ORDER |

| 3 | REDUCE_EXPOSURE | → Prepare REDUCE → Sell to Close (REDUCE) → Format REDUCE Result → Build REDUCE Persist SQL → Persist REDUCE → Telegram REDUCE + Gather Trade Data |### 5. Greeks Decay / Theta Management Agent

| 4 | REVERSE | → Prepare REVERSE Close → Close Position (REVERSE) → Format REVERSE Close → Build REVERSE Persist SQL → Persist REVERSE → Telegram REVERSE Close → If REVERSE Close OK → HTTP Account (re-enter opposite) |

| 5 | EXIT | → Prepare EXIT → Close Position (EXIT) → Format EXIT Result → Build EXIT Persist SQL → Persist EXIT → Telegram EXIT + Gather Trade Data |**What's missing:** The workflow fetches greeks (delta, gamma, theta, vega, IV) from Alpaca option snapshots but does not **actively manage theta decay** or **IV crush risk**.

| 6 | WAIT | → Notify WAIT → Build WAIT Persist SQL → Persist WAIT → Telegram WAIT |

| 7 | Fallback | (empty) |**What a human does:**

- Avoids buying options with very high IV (IV percentile > 80) unless it's a momentum play

### 9. Post-Trade Evaluation Pipeline ✅- Monitors theta decay and exits before time value erodes too much

Triggered after Persist EXIT, Persist REDUCE, or Persist REVERSE:- Avoids holding 0DTE options through periods of low price movement

- **Gather Trade Data** — builds SQL to fetch complete trade lifecycle from DB- Considers gamma exposure for near-expiry contracts

- **Fetch Trade Lifecycle** — queries `position_journal` JOIN `order_executions` JOIN `trading_decisions`

- **Compute Trade P&L** — calculates price change, P&L per contract, P&L total, outcome, hold duration**Recommendation:**

- **AI Trade Evaluator** — GPT-4.1-mini with evaluation criteria (signal quality, timing quality, risk management quality, grade A–F, score 0–100)- Add **IV Percentile/Rank** check before entry (gate: don't buy if IV rank > X%)

- **Build Eval Persist SQL** → **Persist Evaluation** → **Telegram Evaluation**- Add **Theta Decay Monitor**: if holding time exceeds X minutes and P&L is flat/negative, consider early exit

- Add **DTE-aware sizing**: reduce size for 0DTE, increase for 2–5 DTE

### 10. Database Schema ✅- Add **IV crush warning** before known events (earnings, FOMC)

7 SQL migrations providing:

- `trading.trading_sessions` — daily session tracking---

- `trading.signal_snapshots` — every indicator run recorded

- `trading.trading_decisions` — orchestrator decision log### 6. Market Context / Macro Awareness Agent

- `trading.decision_confirmations` — confirmation/contradiction tracking

- `trading.position_journal` — virtual position lifecycle (OPEN → CLOSED)**What's missing:** The system analyzes individual ticker technicals but is blind to broader market conditions.

- `trading.order_executions` — every Alpaca API call result

- `trading.trade_evaluations` — AI post-trade critiques**What a human does:**

- `trading.broker_positions` — real Alpaca position snapshots- Checks SPY/QQQ trend before trading individual stocks

- `trading.broker_open_orders` — real Alpaca pending orders- Avoids trading against the market (e.g., buying calls on AAPL when SPY is crashing)

- Views: `v_active_positions`, `v_confirmation_streaks`, `v_broker_positions_latest`, `v_broker_open_orders_latest`, `v_evaluation_feedback`, `v_recent_executions`, `v_recent_evaluations`- Watches VIX for overall market fear/greed

- Checks economic calendar for high-impact events (CPI, FOMC, jobs report)

---- Reduces position size during high-uncertainty periods



## Identified Gaps**Recommendation:**

- Add a **Market Context Node** that:

### Gap #1: Hardcoded API Credentials 🔴 Critical Security Risk  - Fetches SPY/QQQ 15m/60m trend (same DMI pipeline)

  - Fetches VIX level and its trend direction

**Evidence**: API keys appear as literal strings in workflow JSON in at least 8 HTTP nodes (bars requests, option contracts, option snapshots, submit order, close position EXIT, close position REVERSE, sell to close REDUCE, account info) plus inline in Sync Broker State `fetch()` calls.  - Checks an economic calendar API for upcoming events

  - Produces a `market_context` object: `{ spy_trend, qqq_trend, vix_level, vix_trend, upcoming_events, market_regime }`

**Risk**: Credentials are stored in plaintext in the workflow JSON file, which is version-controlled. Anyone with access to the repo has broker access.  - The orchestrator uses this as an additional gate (e.g., don't buy calls if SPY is in strong downtrend)



**Recommendation**: Use n8n's built-in credential store (HTTP Header Auth credential type) and reference `credentials.httpHeaderAuth` on each node instead of inline header values. Rotate the keys immediately if this repo is public.---



---### 7. Order Fill Confirmation & Reconciliation



### Gap #2: SQL Injection Vulnerability 🔴 Critical Security Risk**What's missing:** After submitting an order to Alpaca, the workflow does not verify if the order was actually filled, partially filled, or rejected.



**Evidence**: Multiple code nodes build SQL via string interpolation without parameterized queries:**What a human does:**

- `Build EXIT Persist SQL`, `Build REDUCE Persist SQL`, `Build REVERSE Persist SQL`, `Build ORDER Persist SQL`, `Build HOLD Persist SQL`, `Build WAIT Persist SQL`, `Build Eval Persist SQL`- Watches the order book to confirm fill

- `Save Signal Snapshot` — `INSERT INTO trading.signal_snapshots ... '${ticker}'`- Cancels and re-submits if limit order isn't filling

- `Save Orchestration Decision` — `INSERT INTO trading.trading_decisions ... '${reasoning}'`- Adjusts limit price if market is moving away

- Records actual fill price (not intended price) for P&L

While the ticker comes from a controlled input (Telegram message parsed into uppercase symbol), the `reasoning` field comes from AI-generated text. Most fields use `.replace(/'/g, "''")` but not all fields are escaped consistently.

**Recommendation:**

**Risk**: A malformed AI output or unexpected ticker input could break queries or corrupt data.- Add an **Order Reconciliation Node** that:

  - Polls `GET /v2/orders/{order_id}` after submission

**Recommendation**: Use the n8n Postgres node's built-in parameterized query mode (`operation: "insert"` with mapped fields) instead of raw `executeQuery` with string interpolation. Alternatively, use `$1, $2` parameterized queries.  - Handles: `filled` → update position_journal with actual fill price; `partially_filled` → decide to wait or cancel remainder; `rejected` → alert and log reason

  - Implements **order timeout**: if not filled within N seconds, cancel and reassess

---  - Syncs actual fills to `order_executions` table with real fill_price and filled_qty



### Gap #3: No Stop-Loss / Take-Profit Monitoring Between Signals 🟠 High Priority---



**Evidence**: The workflow computes `option_stop_premium` and `option_take_profit_premium` in the Compute Option ATR Stops/TP and Enrich Payload for AI nodes, and stores them in `position_journal.current_stop` / `current_tp`. However:### 8. Broker State Synchronization (Implementation)

- There is **no polling loop** or scheduled check that monitors the current option price against these levels

- The only exit triggers are: (a) AI Decision Orchestrator deciding EXIT/REDUCE/REVERSE on the next signal run, or (b) manual Telegram trigger**What's missing:** The SQL schema for `broker_positions` and `broker_open_orders` exists (migration 006), but the **actual sync implementation** (polling Alpaca API and populating these tables) appears to be missing from the workflow.

- Between signal runs (every 5 minutes in AUTO mode), price can blow through stops with no automated response

**What a human does:**

**Risk**: A fast-moving adverse price move between signal intervals has no automated protection. The system relies entirely on the next scheduled AI evaluation to detect the breach.- Always knows their current positions and open orders before placing new ones

- Never places duplicate orders

**Recommendation**:- Reconciles broker state with their mental model

1. Add a separate scheduled workflow (1-minute interval) that polls option prices against `current_stop` / `current_tp` in `position_journal` where `status = 'OPEN'`

2. Auto-execute EXIT via Alpaca DELETE when stop is hit, or partial close at TP**Recommendation:**

3. Alternatively, use Alpaca's built-in bracket/OTO/OCO order types to attach stop-loss and take-profit at order submission time- Add a **Broker Sync Node** (scheduled every 30–60 sec during market hours) that:

  - Calls `GET /v2/positions` and upserts into `broker_positions`

---  - Calls `GET /v2/orders?status=open` and upserts into `broker_open_orders`

  - Compares broker state with `position_journal` and flags discrepancies

### Gap #4: No Order Fill Confirmation / Status Polling 🟠 High Priority  - Gates new order submissions on `broker_open_orders` (prevent duplicates)



**Evidence**: The Submit Order node POSTs to `/v2/orders` and immediately persists the response. For limit orders, the Alpaca response status will be `"accepted"` or `"new"` — NOT `"filled"`. The workflow:---

- Stores `alpaca_status` from the initial response in `order_executions`

- Never polls `/v2/orders/{id}` to check if the order eventually filled, partially filled, or was cancelled## 🟡 Important Gaps — Would Significantly Improve Performance

- The `position_journal` is updated immediately (optimistically)

### 9. Multi-Ticker Scanning / Watchlist Agent

The same issue exists for DELETE-based exits: while DELETE is typically synchronous for a market close, the response handling doesn't verify fill.

**What's missing:** The workflow only processes one ticker per Telegram message. A human scans multiple tickers to find the best opportunity.

**Risk**: A limit order that never fills leaves the virtual `position_journal` showing an OPEN position that doesn't exist at the broker. The orchestrator will then make decisions based on phantom positions.

**Recommendation:**

**Recommendation**:- Add a **Watchlist Scanner** that runs on a schedule (every 5 min)

1. After Submit Order, add a polling/webhook mechanism to check order status until terminal state (filled/cancelled/expired)- Scans a configurable list of tickers (e.g., SPY, QQQ, AAPL, TSLA, NVDA, AMD)

2. Use Alpaca's WebSocket streaming for real-time trade updates- Ranks opportunities by confidence × R:R × liquidity

3. Or add a periodic reconciliation job that compares `position_journal` against `broker_positions`- Sends top 1–3 alerts to Telegram for human review or auto-execution



------



### Gap #5: Position Journal / Broker State Reconciliation is Passive 🟡 Medium Priority### 10. Evaluation Feedback Loop → Orchestrator Learning



**Evidence**: The `Sync Broker State` node fetches real Alpaca positions and open orders before every orchestrator run and stores them in `broker_positions` / `broker_open_orders`. The orchestrator's system prompt instructs it to "reconcile virtual_positions with broker_positions in your reasoning." However:**What's missing:** `v_recent_evaluations_feedback` view exists (migration 006) but it's unclear if the orchestrator agent actually reads past evaluations to learn from mistakes.

- Reconciliation is purely advisory (AI reasoning text) — no automated correction

- If `position_journal` says OPEN but broker has no position, the orchestrator may issue a REDUCE or EXIT that fails**Recommendation:**

- If broker has a position but `position_journal` is empty, the orchestrator may issue NEW_ENTRY creating a duplicate- Before each new orchestration decision, query the last N evaluations for the same ticker

- Include `lessons_learned` and `evaluation_grade` in the orchestrator's AI prompt context

**Risk**: Virtual and real state drift over time, especially after failed orders, external fills, or system restarts.- Implement **pattern-based adjustment**: if the last 3 trades on ticker X were graded D/F with "entered too late", increase the trigger sensitivity



**Recommendation**: Add a deterministic reconciliation code node after Sync Broker State that auto-corrects mismatches and logs reconciliation actions.---



---### 11. Spread Strategy Support



### Gap #6: No Graceful Failure / Retry on Alpaca API Errors 🟡 Medium Priority**What's missing:** The system only supports **long calls and long puts** (buy_to_open). No spreads.



**Evidence**: Most HTTP nodes have `continueOnFail: true`, which means API failures are swallowed and passed downstream as error objects. The Format EXIT/REDUCE/REVERSE Result nodes check `statusCode` for success/failure and send error Telegram notifications. However:**What a human does (often):**

- No retry logic for transient 429 (rate limit) or 500 (server error) responses- Buys vertical spreads (bull call spread, bear put spread) to reduce cost and cap risk

- The Sync Broker State `fetch()` calls wrap errors in a SQL comment and continue with stale data- Uses spreads to lower theta decay impact

- Adjusts spread legs as the trade progresses

**Risk**: A transient Alpaca API error could cause a missed exit or failed order with no recovery attempt.

**Recommendation (future):**

**Recommendation**: Wrap critical HTTP nodes (Submit Order, Close Position EXIT/REDUCE/REVERSE) with retry logic (n8n's built-in retry on fail setting, or a Wait + retry loop).- Add support for **vertical spreads** (2-leg orders via Alpaca multi-leg)

- Add **spread R:R calculator** (max gain / max loss / breakeven)

---- This is a significant feature expansion but dramatically improves capital efficiency



### Gap #7: Single Telegram Chat ID Hardcoded 🟡 Medium Priority---



**Evidence**: All Telegram nodes reference `chatId: "-4857387406"` as a hardcoded string.### 12. Session Management & Trading Hours Enforcement



**Risk**: Non-functional risk — limits multi-user operation and makes the chat ID a deployment dependency.**What's missing:** The `time_gate_ok` field exists but the implementation is basic. There's no sophisticated session lifecycle management.



**Recommendation**: Store the chat ID as an n8n workflow variable or environment variable.**Recommendation:**

- **Pre-market prep** (9:00–9:30 ET): fetch overnight levels, pre-market volume, gap analysis

---- **Opening range** (9:30–10:00 ET): avoid entries during the first 5 min, analyze opening range breakout

- **Power hour** (3:00–4:00 ET): tighten stops, avoid new entries after 3:30

### Gap #8: No Trailing Stop or Dynamic Stop Adjustment 🟡 Medium Priority- **EOD cleanup** (3:50–4:00 ET): force-close all day trade positions

- Store session state machine: `PRE_MARKET → OPENING → ACTIVE → POWER_HOUR → CLOSING → CLOSED`

**Evidence**: The `position_journal.current_stop` is set once at entry and never updated. The orchestrator can issue REDUCE_EXPOSURE, but there is no mechanism to trail the stop as the position moves favorably or tighten stops after partial profit-taking.

---

**Risk**: Profitable positions can reverse and turn into losses because the initial stop remains static.

### 13. Slippage & Transaction Cost Tracking

**Recommendation**: During CONFIRM_HOLD decisions, add logic to update `position_journal.current_stop` based on new ATR readings or by trailing at a percentage of max favorable excursion.

**What's missing:** P&L calculations don't account for commissions, fees, or slippage.

---

**Recommendation:**

### Gap #9: No Rate Limiting / Cost Tracking on AI API Calls 🟢 Low Priority- Track per-contract commission ($0.65 per contract on Alpaca options)

- Calculate slippage = |fill_price - intended_entry_price|

**Evidence**: 4 separate GPT-4.1-mini agents run per cycle. In AUTO mode (every 5 min), each cycle invokes at least 2–3 AI calls.- Include costs in `trade_evaluations` P&L calculations

- Add cost-adjusted R:R to the pre-trade decision (minimum R:R should cover 2x round-trip costs)

**Risk**: OpenAI API cost accumulation; potential rate limiting from OpenAI.

---

**Recommendation**: Add cost tracking (token counts logged to DB). Consider caching identical payloads or skipping AI calls when indicators haven't changed.

### 14. Alerting & Circuit Breakers

---

**What's missing:** No circuit breakers for system failures or abnormal market conditions.

### Gap #10: No Multi-Ticker Concurrency Control 🟢 Low Priority

**Recommendation:**

**Evidence**: Two simultaneous ticker triggers both call the same Alpaca account endpoint for sizing, meaning available capital could be double-counted.- **API failure circuit breaker**: if Alpaca API returns 3+ consecutive errors, pause trading and alert

- **Data staleness alert**: if bar data is >5 min old, skip the signal (avoid trading on stale data)

**Risk**: Two simultaneous NEW_ENTRY decisions could over-allocate capital.- **Flash crash detector**: if price moves >2% in <1 min, halt new entries

- **Duplicate order guard**: check `broker_open_orders` before every submission

**Recommendation**: Add a semaphore/lock mechanism or serialize order submissions.- **Daily trade count limit**: PDT rule compliance (< 3 day trades in rolling 5 days for accounts < $25K)



------



### Gap #11: Legacy Table Duplication 🟢 Low Priority## 🟢 Nice-to-Have — Polish & Optimization



**Evidence**: `Insert row` writes to `workflow_indicators` and `Insert row1` writes to `workflow_decisions` — legacy tables that duplicate data now captured by the orchestration schema (`signal_snapshots`, `trading_decisions`, `order_executions`).### 15. Historical Backtest Agent



**Risk**: Data duplication, confusion about source of truth.- Replay past signal_snapshots through the orchestrator to test rule changes

- Compare hypothetical P&L vs actual P&L

**Recommendation**: Deprecate and remove legacy inserts once the orchestration schema is validated.

### 16. Dashboard / Web UI

---

- Real-time dashboard showing open positions, P&L curve, today's decisions

### Gap #12: Empty README 🟢 Low Priority- Historical performance charts (win rate, avg R:R, by ticker, by profile)

- Replace or supplement Telegram with a proper web interface

**Evidence**: `README.md` contains only `# day_trade`.

### 17. News / Sentiment Agent

**Recommendation**: Document system architecture, setup instructions, trading strategy overview, and operational procedures.

- NLP-based news scanner (e.g., unusual options activity alerts, SEC filings)

---- Social sentiment (Twitter/X mentions, Reddit WSB)

- Gate trades around earnings dates

## Priority Matrix

### 18. Options Flow / Unusual Activity

| # | Gap | Severity | Effort | Priority |

|---|---|---|---|---|- Monitor options flow data for the ticker (unusual call/put volume)

| 1 | Hardcoded API credentials | 🔴 Critical | Low | **Immediate** |- Dark pool prints at key levels

| 2 | SQL injection via string interpolation | 🔴 Critical | Medium | **Immediate** |- Institutional positioning signals

| 3 | No stop-loss/TP monitoring between signals | 🟠 High | High | **Next sprint** |

| 4 | No order fill confirmation/polling | 🟠 High | Medium | **Next sprint** |### 19. Adaptive Indicator Weighting

| 5 | Position/broker reconciliation is passive | 🟡 Medium | Medium | **Planned** |

| 6 | No retry on Alpaca API errors | 🟡 Medium | Low | **Planned** |- Track which indicators (DMI, TD, candlestick patterns) have the highest predictive value per ticker

| 7 | Hardcoded Telegram chat ID | 🟡 Medium | Low | **Planned** |- Dynamically adjust confidence weights based on historical accuracy

| 8 | No trailing stop / dynamic stop adjustment | 🟡 Medium | Medium | **Planned** |

| 9 | No AI API rate/cost tracking | 🟢 Low | Low | **Backlog** |---

| 10 | No multi-ticker concurrency control | 🟢 Low | Medium | **Backlog** |

| 11 | Legacy table duplication | 🟢 Low | Low | **Backlog** |## Priority Roadmap

| 12 | Empty README | 🟢 Low | Low | **Backlog** |

| Priority | Gap | Impact | Effort |

---|----------|-----|--------|--------|

| � Done | #1 Position Exit Management | **Resolved** — exit path exists (Prepare EXIT → Close Position → Persist EXIT → Eval). Remaining: bracket orders, trailing stops, EOD liquidation | — |
| ✅ Done | #0 If1 Low-Confidence Dead End | **Resolved** (2026-02-23) — If1 false branch now routes to Save Signal Snapshot so orchestrator always runs for EXIT/REDUCE/REVERSE even when confidence < 65% | — |

## Summary| 🔴 P0 | #2 Real-Time Position Monitor | **Critical** — blind to position status after entry | Medium |

| 🔴 P0 | #3 Account Risk Management | **Critical** — can blow up the account | Low |

The workflow is remarkably comprehensive for a self-hosted n8n trading system. It implements a full AI-augmented trading lifecycle: multi-timeframe technical analysis → dual-candidate option selection with liquidity gating → AI analysis with deterministic confidence → AI orchestration with 3-confirmation entry strategy → 7 execution paths (NEW_ENTRY, CONFIRM_HOLD, ADD_POSITION, REDUCE_EXPOSURE, REVERSE, EXIT, WAIT) → post-trade AI evaluation with grading and lessons learned → feedback loop into the orchestrator.| 🔴 P0 | #7 Order Fill Reconciliation | **Critical** — trading on assumed vs actual state | Low |

| 🔴 P1 | #8 Broker Sync Implementation | **High** — prevent duplicates, state mismatch | Low |

The most critical gaps are **security-related** (hardcoded credentials and SQL injection) and should be addressed immediately. The most impactful functional gaps are **real-time stop-loss monitoring** (Gap #3) and **order fill confirmation** (Gap #4), which together represent the system's main exposure to unmanaged risk between signal intervals.| 🔴 P1 | #14 Circuit Breakers | **High** — prevent catastrophic failures | Low |

| 🟡 P2 | #4 Volume / VWAP Analysis | **Medium** — better signal quality | Medium |
| 🟡 P2 | #6 Market Context Agent | **Medium** — avoid trading against the market | Medium |
| 🟡 P2 | #5 Greeks / Theta Management | **Medium** — avoid time decay traps | Medium |
| 🟡 P2 | #12 Session Lifecycle | **Medium** — proper trading hours behavior | Low |
| 🟡 P2 | #13 Slippage / Cost Tracking | **Medium** — accurate P&L | Low |
| 🟡 P3 | #10 Evaluation Feedback Loop | **Medium** — learn from mistakes | Low |
| 🟡 P3 | #9 Multi-Ticker Scanner | **Medium** — find best opportunities | Medium |
| 🟢 P4 | #11 Spread Strategies | **Low** — capital efficiency | High |
| 🟢 P4 | #15–19 Backtest, Dashboard, News, Flow, Adaptive | **Low** — optimization & polish | High |

---

## Summary

The current system is strong at **signal generation** (analytics), **entry decision-making** (orchestration + order submission), and **signal-driven exit execution** (EXIT / REDUCE / REVERSE paths submit real orders to Alpaca and persist results). The biggest remaining gaps are on the **proactive position lifecycle management** side — bracket orders (stop-loss/take-profit), trailing stops, EOD liquidation, and continuous position monitoring independent of the signal loop. The P0 items (#2–3, #7) should be addressed before running the system with real capital at any meaningful size.
