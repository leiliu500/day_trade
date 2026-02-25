# Multi-Order & Multi-Ticker Lifecycle Management

> **Date:** 2026-02-24  
> **Status:** Design Proposal  
> **Scope:** Scaling the orchestrator from 1-3 orders/ticker to 10+ orders across multiple tickers  
> **Migration:** `008_order_lifecycle_and_portfolio_risk.sql`

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current Architecture Bottlenecks](#2-current-architecture-bottlenecks)
3. [Proposed Architecture](#3-proposed-architecture)
4. [Order Lifecycle State Machine](#4-order-lifecycle-state-machine)
5. [Multi-Ticker Orchestration Strategy](#5-multi-ticker-orchestration-strategy)
6. [Portfolio Risk Management](#6-portfolio-risk-management)
7. [Workflow Refactoring Plan](#7-workflow-refactoring-plan)
8. [Migration Guide](#8-migration-guide)
9. [Implementation Phases](#9-implementation-phases)
10. [Liquidity Gate & Workflow Orchestration Control](#10-liquidity-gate--workflow-orchestration-control)

---

## 1. Problem Statement

### Current Scale

The system currently operates as:
- **1 ticker per signal trigger** (Telegram: `SPY S`)
- **1-3 orders per day per ticker** (NEW_ENTRY → maybe ADD_POSITION → EXIT)
- **No cross-ticker awareness** (SPY orchestrator doesn't know about AAPL positions)
- **No portfolio-level risk aggregation**

### Target Scale

We need to support:
- **5-10 tickers monitored simultaneously** (SPY, QQQ, AAPL, TSLA, NVDA, AMD, META, AMZN, MSFT, GOOGL)
- **2-4 orders per ticker per day** = **10-40 total orders per day**
- **5+ simultaneous open positions** across different tickers
- **Independent lifecycle per order** (each order has its own stop, target, state)
- **Portfolio-level risk gates** (max exposure, max concurrent positions, daily loss limit)

### What Breaks at Scale

| Scenario | Current Behavior | Problem |
|---|---|---|
| SPY entry + AAPL entry in same minute | Both call `HTTP Account` → `Compute Size` | **Capital double-counted** — both see full buying power |
| SPY has 3 open positions, TSLA signal fires | Orchestrator only sees SPY context | **No portfolio awareness** — could exceed risk limits |
| 10 open orders across 5 tickers | All tracked in `position_journal` + `order_executions` (separate tables) | **No unified order state** — split across tables, hard to query |
| ADD_POSITION on SPY (3rd add) | No limit on per-ticker positions | **Unlimited stacking** — could have 10 SPY positions |
| Morning loss streak (-$400) on AAPL, then SPY signal | Orchestrator doesn't check daily P&L | **No circuit breaker** — keeps trading after losses |
| Limit order pending on SPY, new signal fires | Orchestrator may issue another NEW_ENTRY | **Duplicate orders** — `broker_open_orders` check is advisory only |

---

## 2. Current Architecture Bottlenecks

### Bottleneck 1: Split Order State

Currently, order state is split across **3 tables**:

```
position_journal          → Virtual position (OPEN/CLOSED)
order_executions          → Execution log (one row per API call)
broker_positions          → Snapshot of Alpaca state (advisory)
```

**Problem:** To answer "what is the state of order X?", you need to JOIN 3 tables and reconcile discrepancies. There's no single source of truth for an order's lifecycle.

**Example:** After a limit order is submitted:
- `position_journal` shows `status = 'OPEN'` (optimistic)
- `order_executions` shows `alpaca_status = 'accepted'` (not filled yet)
- `broker_positions` may not show it (hasn't filled)

The orchestrator sees an "open position" that doesn't actually exist at the broker.

### Bottleneck 2: Ticker-Scoped Context

All SQL queries in `Save Signal Snapshot` are scoped to the **current ticker**:

```sql
-- Every query is WHERE ticker = '${ticker}'
SELECT * FROM trading.position_journal WHERE ticker = '${ticker}' AND status = 'OPEN';
SELECT * FROM trading.trading_decisions WHERE ticker = '${ticker}' AND trade_date = '${today}';
SELECT * FROM trading.v_confirmation_streaks WHERE ticker = '${ticker}';
```

**Problem:** The orchestrator is blind to positions in other tickers. With 5 open SPY positions and a new AAPL signal, the orchestrator has no idea the account is already heavily allocated.

### Bottleneck 3: No Capital Serialization

```
Signal SPY → HTTP Account (equity=$10K) → Compute Size (qty=3, cost=$750)
Signal AAPL → HTTP Account (equity=$10K) → Compute Size (qty=3, cost=$750)
                                         ↑ sees same $10K, not $10K-$750
```

**Problem:** In AUTO mode (5-min schedule), two tickers can trigger simultaneously. Both see the full account equity, both compute size, both submit orders → double allocation.

### Bottleneck 4: No Relationship Between Orders

When the orchestrator issues REVERSE:
1. Close the current position (sell_to_close)
2. Open the opposite position (buy_to_open)

These are tracked as **two independent rows** in `order_executions`. There's no link between them. If step 1 fails, step 2 may still proceed (or vice versa).

Similarly, ADD_POSITION creates a new `position_journal` row with no link to the original entry, making it hard to track the total position size.

### Bottleneck 5: No Order Fill Tracking

After `Submit Order → POST /v2/orders`, the workflow:
1. Gets back `status: "accepted"` (not filled)
2. Immediately creates `position_journal` row with `status: 'OPEN'`
3. Never checks if the order actually filled

This means `position_journal` can show OPEN positions that were never filled, cancelled, or expired.

---

## 3. Proposed Architecture

### 3.1 New Data Model

Replace the 3-table split with a **single `order_lifecycle` table** that tracks each order through its complete lifecycle:

```
┌─────────────────────────────────────────────────────────────────────┐
│                     NEW DATA MODEL                                   │
│                                                                      │
│  order_lifecycle (single source of truth per order)                  │
│  ├─ Identity: ticker, contract_symbol, decision_type                │
│  ├─ Order: side, qty, limit_price, order_type                       │
│  ├─ State: INTENT → SUBMITTED → FILLED → MONITORING → CLOSED       │
│  ├─ Position: stop_level, target_level, trail_offset                │
│  ├─ Result: avg_fill_price, close_fill_price, realized_pnl         │
│  └─ Timestamps: created_at, submitted_at, filled_at, closed_at     │
│                                                                      │
│  order_groups (relationships between orders)                         │
│  ├─ BRACKET: entry + stop_loss + take_profit                        │
│  ├─ REVERSE_PAIR: close + re-open                                   │
│  ├─ ADD_CHAIN: entry + add-on entries                               │
│  └─ SCALE_OUT: partial close chain                                  │
│                                                                      │
│  portfolio_risk_limits (configurable risk gates)                     │
│  ├─ max_concurrent_positions: 5                                     │
│  ├─ max_positions_per_ticker: 2                                     │
│  ├─ max_daily_loss_usd: $500                                        │
│  ├─ max_portfolio_risk_pct: 3%                                      │
│  └─ ... (10 configurable limits)                                    │
│                                                                      │
│  portfolio_risk_state (real-time risk snapshot)                      │
│  └─ Updated before every order decision                             │
│                                                                      │
│  EXISTING TABLES (unchanged, still populated):                       │
│  ├─ position_journal    — kept for backward compatibility           │
│  ├─ order_executions    — kept as execution audit log               │
│  ├─ trading_decisions   — kept as decision audit log                │
│  └─ signal_snapshots    — kept as signal history                    │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 Relationship to Existing Tables

The new `order_lifecycle` table **does not replace** existing tables — it **unifies** them:

| Existing Table | Keeps | New Role |
|---|---|---|
| `position_journal` | ✅ Still populated | Backward-compatible audit log |
| `order_executions` | ✅ Still populated | Execution audit log (every API call) |
| `trading_decisions` | ✅ Still populated | Decision audit log (AI reasoning) |
| `order_lifecycle` | 🆕 NEW | Single source of truth for order state |

The orchestrator should query `order_lifecycle` instead of `position_journal` for current state.

### 3.3 New Views for Orchestrator

| View | Purpose | Scope |
|---|---|---|
| `v_active_orders` | All non-terminal orders | Cross-ticker |
| `v_open_positions_live` | Filled/monitoring positions | Cross-ticker, today |
| `v_portfolio_summary` | Aggregate exposure & risk | Cross-ticker |
| `v_daily_pnl` | Today's realized P&L | Cross-ticker |
| `v_pending_orders` | Orders awaiting fill | Cross-ticker |
| `v_orders_needing_attention` | Stale, errored, retryable | Cross-ticker |

---

## 4. Order Lifecycle State Machine

```
                    ┌──────────┐
                    │  INTENT   │  Orchestrator decides to place an order
                    └────┬─────┘
                         │ Submit to Alpaca
                         ▼
                    ┌──────────┐
                    │ SUBMITTED │  POST /v2/orders sent
                    └────┬─────┘
                         │ Alpaca response
                    ┌────┴────────────────────────┐
                    │                              │
                    ▼                              ▼
              ┌──────────┐                  ┌──────────┐
              │ ACCEPTED  │                  │ REJECTED  │  → Terminal
              └────┬─────┘                  └──────────┘
                   │
         ┌────────┼─────────────────────┐
         │        │                      │
         ▼        ▼                      ▼
   ┌──────────┐ ┌────────────────┐ ┌──────────┐
   │  FILLED   │ │PARTIALLY_FILLED│ │ CANCELLED │  → Terminal
   └────┬─────┘ └────────┬───────┘ └──────────┘
        │                │
        │                │ (more fills arrive)
        │                ▼
        │          ┌──────────┐
        │          │  FILLED   │
        │          └────┬─────┘
        │               │
        ▼               ▼
   ┌──────────────┐
   │  MONITORING   │  Position is open, actively managed
   └────┬─────────┘
        │
        │ Stop hit / Target hit / EXIT signal / EOD
        ▼
   ┌──────────┐
   │  CLOSING  │  Close order submitted to Alpaca
   └────┬─────┘
        │
        ▼
   ┌──────────┐
   │  CLOSED   │  → Terminal (P&L computed)
   └──────────┘
```

### State Transition Rules

| From | To | Trigger |
|---|---|---|
| INTENT | SUBMITTED | Order sent to Alpaca |
| INTENT | CANCELLED | Pre-submit validation failed |
| SUBMITTED | ACCEPTED | Alpaca confirms receipt |
| SUBMITTED | FILLED | Immediate fill (market order) |
| SUBMITTED | REJECTED | Broker rejects (insufficient BP, invalid symbol) |
| ACCEPTED | FILLED | All qty filled |
| ACCEPTED | PARTIALLY_FILLED | Some qty filled |
| ACCEPTED | CANCELLED | We cancel (or Alpaca cancels) |
| ACCEPTED | EXPIRED | TIF=day and market closed |
| PARTIALLY_FILLED | FILLED | Remaining qty filled |
| PARTIALLY_FILLED | CANCELLED | Cancel remaining |
| FILLED | MONITORING | Transition to active monitoring |
| MONITORING | CLOSING | Close order submitted |
| MONITORING | CLOSED | Immediate close (DELETE /v2/positions) |
| CLOSING | CLOSED | Close order filled |
| CLOSING | ERROR | Close order failed |

---

## 5. Multi-Ticker Orchestration Strategy

### 5.1 Current: Single-Ticker Pipeline

```
Trigger (SPY S)
    → Signal Pipeline (SPY only)
    → Orchestrator Context (SPY queries only)
    → AI Decision (SPY context only)
    → Execute (SPY order)
```

### 5.2 Proposed: Ticker-Scoped + Portfolio-Aware

The workflow **keeps** the single-ticker signal pipeline (it's the right design for signal generation), but **adds** cross-ticker context to the orchestrator:

```
Trigger (SPY S)
    → Signal Pipeline (SPY only)            ← unchanged
    → Save Signal Snapshot (SPY)            ← unchanged
    → Sync Broker State                     ← unchanged
    ──────────────────────────────────────── ← NEW: Portfolio Context
    → Risk Check (cross-ticker)             ← NEW
    → Build Orchestrator Context            ← MODIFIED (add portfolio context)
    → AI Decision (SPY signal + portfolio)  ← MODIFIED (sees all positions)
    → Execute (SPY order)                   ← unchanged
```

### 5.3 Modified SQL Queries for Orchestrator

The `Save Signal Snapshot` node currently builds 8 SQL queries, all ticker-scoped. Add 3 more **cross-ticker** queries:

```sql
-- NEW Query 9: Portfolio summary (all tickers)
SELECT * FROM trading.v_portfolio_summary;

-- NEW Query 10: All open positions across all tickers
SELECT ticker, contract_symbol, side, avg_fill_price, filled_qty,
       stop_level, target_level, status, filled_at,
       EXTRACT(EPOCH FROM (NOW() - filled_at)) / 60 AS hold_minutes
FROM trading.order_lifecycle
WHERE status IN ('FILLED', 'MONITORING')
  AND trade_date = CURRENT_DATE
ORDER BY ticker, filled_at;

-- NEW Query 11: Portfolio risk check
SELECT trading.check_portfolio_risk_limits('${ticker}', ${equity});
```

### 5.4 Modified AI Orchestrator Prompt

Add portfolio context section to the orchestrator's system prompt:

```
## Portfolio Context (Cross-Ticker Awareness)

You manage a PORTFOLIO, not just one ticker. Before any NEW_ENTRY or ADD_POSITION:

1. Check portfolio_risk_check.allowed — if false, output WAIT with blocked_reasons.
2. Review all_open_positions to understand total portfolio exposure.
3. Consider correlation: don't open SPY CALL + QQQ CALL + IWM CALL simultaneously
   (all are long equities — concentrated directional risk).
4. Respect per-ticker limits: max 2 positions per ticker.
5. Prioritize higher-confidence signals when multiple tickers are actionable.
6. Consider total buying power — leave reserve for exits and adjustments.

### Portfolio Risk Gates (HARD LIMITS — you CANNOT override these):
- max_concurrent_positions: {limit_value}
- max_positions_per_ticker: {limit_value}
- max_daily_loss_usd: ${limit_value}
- If portfolio_risk_check.allowed = false → output WAIT, do NOT suggest entry.
```

### 5.5 Multi-Ticker AUTO Mode

For scanning multiple tickers in AUTO mode, there are two approaches:

#### Option A: Sequential Scan (Recommended for v1)

Run the existing workflow for each ticker in sequence:

```
Schedule Trigger (every 5 min)
    → Watchlist: ["SPY","QQQ","AAPL","TSLA","NVDA"]
    → SplitInBatches (1 item at a time)
    → For each ticker:
        → Full signal pipeline
        → Orchestrator (with portfolio context)
        → Execute if approved
    → Next ticker
```

**Pros:** No concurrency issues, capital serialized naturally  
**Cons:** Slow for 10 tickers (5-10 sec each = 50-100 sec total)

#### Option B: Parallel Scan + Serialized Execution (Advanced)

```
Schedule Trigger (every 5 min)
    → Watchlist: ["SPY","QQQ","AAPL","TSLA","NVDA"]
    → Parallel signal generation (all tickers at once)
    → Collect & rank all signals by confidence × R:R
    → Serialized orchestration (one at a time, portfolio context updated between each)
    → Execute approved orders
```

**Pros:** Fast signal generation, best opportunities prioritized  
**Cons:** More complex workflow, needs careful n8n design

#### Recommendation

Start with **Option A** (sequential scan). It's simpler, naturally serializes capital allocation, and handles 5-10 tickers within the 5-minute interval. Upgrade to Option B only if signal freshness becomes an issue.

---

## 6. Portfolio Risk Management

### 6.1 Risk Check Flow

```
Before NEW_ENTRY / ADD_POSITION:

┌──────────────────────────────────┐
│     check_portfolio_risk_limits  │
│     (Postgres function)          │
│                                  │
│  ✓ open_positions < max (5)      │
│  ✓ ticker_positions < max (2)    │
│  ✓ daily_orders < max (20)       │
│  ✓ daily_loss < max ($500)       │
│  ✓ portfolio_risk < max (3%)     │
│  ✓ ticker_exposure < max (1.5%)  │
│                                  │
│  ANY FAIL → allowed: false       │
│  ALL PASS → allowed: true        │
└──────────┬───────────────────────┘
           │
     ┌─────┴─────┐
     │            │
     ▼            ▼
  allowed      blocked
     │            │
     ▼            ▼
  Proceed    Force WAIT
  to order   (log reasons)
```

### 6.2 Capital Serialization

To prevent double-allocation when two tickers trigger simultaneously:

**Approach: Postgres Advisory Lock**

```sql
-- In the workflow, before Compute Size:
SELECT pg_advisory_lock(42);  -- acquire lock

-- Read account equity, compute size, submit order,
-- update order_lifecycle status = 'SUBMITTED'

SELECT pg_advisory_unlock(42);  -- release lock
```

This ensures only one order submission runs at a time. For n8n, this can be implemented by:
1. Using a **Postgres transaction** that locks the `order_lifecycle` table
2. Or using n8n's **webhook-based queue** pattern (more complex)

**Simpler Alternative:** Sequential ticker scanning (Option A above) naturally serializes orders.

### 6.3 Configurable Limits

All limits are stored in `portfolio_risk_limits` and can be adjusted without code changes:

```sql
-- Example: Increase max positions for a high-conviction day
UPDATE trading.portfolio_risk_limits
SET limit_value = 8
WHERE limit_name = 'max_concurrent_positions';

-- Example: Tighten daily loss limit after a losing streak
UPDATE trading.portfolio_risk_limits
SET limit_value = 300
WHERE limit_name = 'max_daily_loss_usd';
```

---

## 7. Workflow Refactoring Plan

### 7.1 What Changes in the Workflow

| Node | Change | Complexity |
|---|---|---|
| `Save Signal Snapshot` | Add 3 cross-ticker SQL queries (portfolio summary, all open positions, risk check) | Low |
| `Build Orchestrator Context` | Add `portfolio_context` bucket to the 7 existing context buckets | Low |
| `AI Decision Orchestrator` | Add portfolio awareness rules to system prompt | Low |
| `Compute Size` | Check `check_portfolio_risk_limits()` result before sizing | Medium |
| `Parse Order Payload` | Create `order_lifecycle` row (status=INTENT) before submitting | Medium |
| `Submit Order` | Transition to SUBMITTED → update with Alpaca response | Medium |
| `Persist ORDER` | Update `order_lifecycle` instead of only `order_executions` | Medium |
| NEW: `Order Fill Checker` | Poll `/v2/orders/{id}` until terminal state | Medium |
| NEW: `Risk Gate` code node | Call `check_portfolio_risk_limits()` and block if not allowed | Low |
| Exit paths (EXIT/REDUCE/REVERSE) | Update `order_lifecycle` status through close flow | Medium |

### 7.2 New `Save Signal Snapshot` Queries

Add these to the existing SQL multi-statement query:

```javascript
// Query 9: Portfolio summary (cross-ticker)
const queryPortfolioSQL = `
SELECT * FROM trading.v_portfolio_summary;
`;

// Query 10: All open positions (cross-ticker)
const queryAllPositionsSQL = `
SELECT ticker, contract_symbol, side, avg_fill_price, filled_qty,
       stop_level, target_level, status, decision_type, conviction_tier,
       filled_at,
       EXTRACT(EPOCH FROM (NOW() - COALESCE(filled_at, created_at))) / 60.0 AS hold_minutes
FROM trading.order_lifecycle
WHERE status IN ('FILLED', 'MONITORING')
  AND trade_date = '${today}'
ORDER BY ticker, filled_at;
`;

// Query 11: Risk check for this ticker
const queryRiskCheckSQL = `
SELECT trading.check_portfolio_risk_limits('${ticker}');
`;
```

### 7.3 Modified `Build Orchestrator Context`

Add an 8th context bucket:

```javascript
// Existing 7 buckets:
// signal_history, active_positions, confirmation_streaks,
// recent_executions, broker_positions, broker_open_orders, evaluation_feedback

// NEW 8th bucket: portfolio context
const portfolioContext = {
    summary: portfolioRows[0] || {},        // from v_portfolio_summary
    all_open_positions: allPositionsRows,    // from query 10
    risk_check: riskCheckRows[0] || {},     // from check_portfolio_risk_limits()
};

context_for_ai.portfolio = portfolioContext;
```

### 7.4 Order Lifecycle Integration Points

```
NEW_ENTRY Flow (modified):
    → Risk Gate (check_portfolio_risk_limits) ← NEW
    → Compute Size                           ← unchanged
    → Parse Order Payload                    ← unchanged
    → Create order_lifecycle (INTENT)        ← NEW
    → Submit Order                           ← unchanged
    → Update order_lifecycle (SUBMITTED)     ← NEW
    → Wait for fill (poll/webhook)           ← NEW (optional phase 2)
    → Update order_lifecycle (FILLED)        ← NEW
    → Persist ORDER (order_executions)       ← unchanged (backward compat)
    → Update position_journal                ← unchanged (backward compat)

EXIT Flow (modified):
    → Update order_lifecycle (CLOSING)       ← NEW
    → Close Position (Alpaca API)            ← unchanged
    → Update order_lifecycle (CLOSED)        ← NEW
    → Compute P&L on order_lifecycle         ← NEW
    → Persist EXIT (order_executions)        ← unchanged (backward compat)
    → Trade Evaluation pipeline              ← unchanged
```

---

## 8. Migration Guide

### 8.1 Database Migration

```bash
# Apply the migration
psql -U postgres -d day_trade -f sql/008_order_lifecycle_and_portfolio_risk.sql
```

### 8.2 Backward Compatibility

The migration is **purely additive**:
- No existing tables are modified
- No existing views are changed
- `position_journal` and `order_executions` continue to work
- Existing SQL queries in the workflow are unchanged

The workflow changes are also additive:
- Old queries keep running
- New queries are added alongside
- `order_lifecycle` is populated IN ADDITION TO existing tables
- If `order_lifecycle` is empty/missing, the orchestrator falls back to old behavior

### 8.3 Backfill Existing Data (Optional)

To populate `order_lifecycle` from existing `position_journal` + `order_executions`:

```sql
-- Backfill from position_journal (open positions)
INSERT INTO trading.order_lifecycle (
    ticker, profile, trade_date, decision_type, contract_symbol,
    side, position_intent, order_type, avg_fill_price, requested_qty,
    filled_qty, stop_level, target_level, status,
    created_at, filled_at, monitoring_since
)
SELECT
    pj.ticker, pj.profile, pj.trade_date,
    'NEW_ENTRY', COALESCE(pj.option_contract_symbol, pj.contract_symbol),
    CASE WHEN pj.side = 'CALL' THEN 'buy' ELSE 'buy' END,
    'buy_to_open', 'limit',
    COALESCE(pj.avg_entry_premium, pj.entry_price),
    COALESCE(pj.virtual_qty, pj.qty, 1),
    COALESCE(pj.virtual_qty, pj.qty, 1),
    pj.current_stop, pj.current_tp,
    CASE WHEN pj.status = 'OPEN' THEN 'MONITORING' ELSE 'CLOSED' END,
    pj.created_at, pj.entry_time, pj.entry_time
FROM trading.position_journal pj
WHERE NOT EXISTS (
    SELECT 1 FROM trading.order_lifecycle ol
    WHERE ol.contract_symbol = COALESCE(pj.option_contract_symbol, pj.contract_symbol)
      AND ol.ticker = pj.ticker
      AND ol.trade_date = pj.trade_date
);
```

---

## 9. Implementation Phases

### Phase 1: Database + Read-Only Context (Low Risk)

**Effort:** 1-2 days  
**Risk:** None (purely additive)

1. ✅ Apply `008_order_lifecycle_and_portfolio_risk.sql`
2. Add 3 cross-ticker queries to `Save Signal Snapshot`
3. Add `portfolio` bucket to `Build Orchestrator Context`
4. Update AI Orchestrator prompt with portfolio awareness rules
5. Orchestrator can now SEE portfolio state, but doesn't WRITE to `order_lifecycle` yet

**Benefit:** Orchestrator becomes portfolio-aware immediately. Can say "WAIT — too many open positions" even without `order_lifecycle` writes.

### Phase 2: Write Integration (Medium Risk)

**Effort:** 2-3 days  
**Risk:** Medium (new write paths)

1. Add `Risk Gate` code node before `Compute Size` → calls `check_portfolio_risk_limits()`
2. Modify `Parse Order Payload` → also creates `order_lifecycle` row (INTENT)
3. Modify `Submit Order` handling → updates `order_lifecycle` (SUBMITTED → FILLED)
4. Modify EXIT/REDUCE/REVERSE paths → update `order_lifecycle` (CLOSING → CLOSED)
5. Both old tables AND new table are populated (dual-write)

**Benefit:** `order_lifecycle` becomes the source of truth. Portfolio risk is enforced automatically.

### Phase 3: Order Fill Reconciliation (High Value)

**Effort:** 2-3 days  
**Risk:** Medium

1. Add **Order Fill Checker** sub-workflow (triggered after Submit Order)
2. Polls `GET /v2/orders/{id}` every 5 seconds for up to 30 seconds
3. Updates `order_lifecycle` with actual fill status
4. Handles: FILLED, PARTIALLY_FILLED, CANCELLED, EXPIRED
5. Alerts via Telegram on unexpected states

### Phase 4: Multi-Ticker AUTO Mode (Advanced)

**Effort:** 3-5 days  
**Risk:** Medium-High

1. Add **Watchlist** configuration (list of tickers + profiles)
2. Modify Schedule Trigger → loop through watchlist
3. Sequential execution with portfolio context updated between tickers
4. Rank signals by confidence × R:R when multiple tickers are actionable
5. Daily summary Telegram with all tickers' performance

### Phase 5: Advanced Order Types (Future)

**Effort:** 5+ days  
**Risk:** High

1. Bracket orders (entry + stop_loss + take_profit as linked orders)
2. `order_groups` table for tracking linked orders
3. Trailing stops (update `high_water_mark` and `stop_level` on CONFIRM_HOLD)
4. OCO (one-cancels-other) for stop/target
5. Multi-leg spreads (future)

---

## 10. Liquidity Gate & Workflow Orchestration Control

### 10.1 Problem: Workflow Must Stop Before Order Entry

The signal pipeline produces a trade plan (ticker, direction, option contract, entry/stop/TP), but the workflow **must not proceed to order submission** unless the option contract passes liquidity checks **and** portfolio risk limits allow a new entry. Two critical gate nodes enforce this:

1. **`Liquidity OK?`** — IF node that checks `option_liquidity_ok === true`
2. **`Force WAIT (Liquidity Gate)`** — Code node that halts the pipeline and forces a WAIT decision

Without these gates, the workflow could:
- Submit orders on illiquid options (wide spreads → bad fills → instant loss)
- Submit orders when portfolio risk limits are exceeded (max positions, daily loss limit)
- Create `order_lifecycle` rows in SUBMITTED state that can never fill properly

### 10.2 Current Flow: Liquidity Gate

```
Compare Candidates
    │
    ▼
┌──────────────┐
│ Liquidity OK? │  IF node: option_liquidity_ok === true
└───┬──────┬───┘
    │      │
   TRUE   FALSE
    │      │
    ▼      ▼
Get Option    Force WAIT
Snapshot      (Liquidity Gate)
    │              │
    ▼              ▼
Enrich Payload ◄───┘  ✅ FIXED: Force WAIT now connects to Enrich Payload for AI
for AI                    (previously a dead-end with no outgoing connections)
    │
    ▼
Compute Option
Metrics
    │
    ▼
Compute Trend
& Confidence
    │
    ▼
AI Indicator
Analyst
    │
    ▼
Normalize
Confidence
    │
    ▼
Switch
    │
    ▼
Output Telegram → HTTP Account → Compute Size → Parse Order Payload → Submit Order
```

### 10.3 Node Details

#### `Liquidity OK?` (IF Node)

- **Type:** `n8n-nodes-base.if`
- **Condition:** `$json.option_liquidity_ok === true`
- **TRUE output →** `Get Option Snapshot` (continues pipeline toward order)
- **FALSE output →** `Force WAIT (Liquidity Gate)` (halts pipeline)

This is a **hard gate**: if the winner candidate from `Compare Candidates` has `option_liquidity_ok = false` (spread too wide, missing bid/ask, stale quote), the workflow does NOT proceed to snapshot, enrichment, AI analysis, sizing, or order submission.

#### `Force WAIT (Liquidity Gate)` (Code Node)

- **Type:** `n8n-nodes-base.code` (Run Once for Each Item)
- **Purpose:** Produce an AI-like output forcing `option_decision = "WAIT"` with a clear explanation of WHY
- **Output:** ✅ Connects to `Enrich Payload for AI` (previously dead-end — **fixed**)

Key fields set by this node:

| Field | Value | Purpose |
|---|---|---|
| `option_decision` | `"WAIT"` | Forces WAIT regardless of signal quality |
| `option_contract_symbol` | `null` | Clears contract — no order can be placed |
| `option_bid/ask/mid/spread_pct` | `null` | Clears quote data — stale/invalid |
| `option_entry/stop/tp_premium` | `null` | Clears pricing — prevents accidental sizing |
| `option_risk_reward` | `null` | Clears R:R — no risk calculation possible |
| `key_factors` | Includes liquidity gate reason | Audit trail for Telegram/DB |
| `plain_explanation` | `"Forced WAIT: {reason}"` | Human-readable explanation |
| `_gate_blocked` | `true` | Signals downstream that a gate blocked this item |
| `_gate_blocked_by` | `"liquidity"` | Which gate blocked the trade |
| `_gate_blocked_reason` | Liquidity reason string | Detailed reason for blocking |
| `_gate_blocked_at` | ISO timestamp | When the gate blocked |

### 10.4 Integration with Order Lifecycle Tracking

When the Liquidity Gate blocks a trade, the `order_lifecycle` table should **still record the intent** so we have a complete audit trail of what the orchestrator wanted to do but couldn't:

```
┌──────────────────────────────────────────────────────────────────────┐
│  FLOW WITH ORDER LIFECYCLE INTEGRATION                              │
│                                                                      │
│  Compare Candidates                                                  │
│      │                                                               │
│      ▼                                                               │
│  ┌────────────────────────────────────────────┐                      │
│  │ Create order_lifecycle (status = INTENT)    │  ← NEW (Phase 2)   │
│  │ Records: ticker, contract, side, decision   │                     │
│  │ conviction_score, confidence_at_order        │                     │
│  └────────────┬───────────────────────────────┘                      │
│               │                                                      │
│               ▼                                                      │
│  ┌──────────────┐                                                    │
│  │ Liquidity OK? │                                                   │
│  └───┬──────┬───┘                                                    │
│      │      │                                                        │
│     TRUE   FALSE                                                     │
│      │      │                                                        │
│      │      ▼                                                        │
│      │  ┌──────────────────────────────────┐                         │
│      │  │ Force WAIT (Liquidity Gate)       │                         │
│      │  │ + Update order_lifecycle:          │  ← NEW (Phase 2)      │
│      │  │   status = CANCELLED               │                       │
│      │  │   close_reason = LIQUIDITY_GATE    │                       │
│      │  │   error_message = reason            │                       │
│      │  └──────────────────────────────────┘                         │
│      │                                                               │
│      ▼                                                               │
│  [Continue to Get Option Snapshot → ... → Submit Order]              │
│      │                                                               │
│      ▼                                                               │
│  ┌──────────────────────────────────┐                                │
│  │ Portfolio Risk Gate               │  ← NEW (Phase 2)             │
│  │ check_portfolio_risk_limits()     │                               │
│  └───┬──────┬───────────────────────┘                                │
│      │      │                                                        │
│    PASS    FAIL                                                      │
│      │      │                                                        │
│      │      ▼                                                        │
│      │  ┌──────────────────────────────────┐                         │
│      │  │ Force WAIT (Portfolio Risk Gate)  │  ← NEW (Phase 2)      │
│      │  │ + Update order_lifecycle:          │                       │
│      │  │   status = CANCELLED               │                       │
│      │  │   close_reason = RISK_LIMIT        │                       │
│      │  │   error_message = blocked_reasons   │                      │
│      │  └──────────────────────────────────┘                         │
│      │                                                               │
│      ▼                                                               │
│  HTTP Account → Compute Size → Parse Order Payload                   │
│      │                                                               │
│      ▼                                                               │
│  Update order_lifecycle (SUBMITTED)                                  │
│      │                                                               │
│      ▼                                                               │
│  Submit Order → Alpaca API                                           │
│      │                                                               │
│      ▼                                                               │
│  Update order_lifecycle (FILLED / REJECTED / ERROR)                  │
└──────────────────────────────────────────────────────────────────────┘
```

### 10.5 Liquidity Checks Performed

The `Select Contract (Liquid)` node (upstream of `Compare Candidates`) evaluates each option snapshot against these criteria:

| Check | Threshold | Source |
|---|---|---|
| Bid/Ask present | `bid != null && ask != null && ask > 0` | `snapshot.latestQuote.bp / .ap` |
| Spread % | `spread_pct ≤ max_spread_pct` (default 2%) | `(ask - bid) / mid` |
| Quote freshness | `quote_age ≤ max_quote_age_sec` (default 120s) | `snapshot.latestQuote.t` vs `Date.now()` |

If NO option passes all three checks, the candidate gets `option_liquidity_ok = false` with a diagnostic reason string like:

```
No option passed liquidity filters. total=8, missingBidAsk=2, wideSpread=5, staleQuote=1.
```

### 10.6 Override Reasons Tracked

The `Output Telegram` node already tracks WHY a WAIT was forced. The `overrideReasons` array captures all gate failures:

```javascript
const overrideReasons = [];
if (payload.time_gate_ok === false)
  overrideReasons.push(`time_gate_ok=false (${payload.time_gate_reason})`);
if (payload.option_liquidity_ok === false)
  overrideReasons.push(`option_liquidity_ok=false (${payload.option_liquidity_reason})`);
if (payload.candidate_pass === false)
  overrideReasons.push("candidate_pass=false");
if (rr != null && rr < 0.6)
  overrideReasons.push(`option_risk_reward ${rr} < 0.6 (RR way too low)`);
if (missingLevels)
  overrideReasons.push("missing underlying levels (trigger/invalidation/target)");
```

### 10.7 Portfolio Risk Gate (Phase 2 — New)

In Phase 2, a second gate node will be added **after** the Liquidity Gate but **before** `Compute Size`. This gate calls `trading.check_portfolio_risk_limits()`:

```
Enrich Payload for AI
    │
    ▼
Compute Option Metrics → Compute Trend & Confidence → AI Analyst → Normalize Confidence
    │
    ▼
Switch (confidence >= 65%?)
    │
    ▼
Output Telegram
    │
    ▼
Save Signal Snapshot (includes Risk Check query)
    │
    ▼
┌───────────────────────────────────┐
│ Portfolio Risk Gate (NEW)          │
│ IF: risk_check.allowed === true    │
└───┬──────────┬────────────────────┘
    │          │
  PASS       FAIL
    │          │
    ▼          ▼
 HTTP Account  Force WAIT (Portfolio Risk Gate)
    │          │
    ▼          └─→ Update order_lifecycle: CANCELLED (RISK_LIMIT)
 Compute Size      + Telegram notification
    │
    ▼
 Parse Order Payload
    │
    ▼
 Submit Order
```

The Risk Gate checks:

| Limit | Default | Action on Breach |
|---|---|---|
| `max_concurrent_positions` | 5 | Block NEW_ENTRY |
| `max_positions_per_ticker` | 2 | Block NEW_ENTRY for this ticker |
| `max_daily_orders` | 20 | Block all new entries |
| `max_daily_loss_usd` | $500 | Circuit breaker — stop trading |
| `max_portfolio_risk_pct` | 3% | Block new entries |
| `max_ticker_exposure_pct` | 1.5% | Block entries for this ticker |

### 10.8 Compute Size Risk Guard (Already Implemented — Bug Fixed)

The `Compute Size` node already has a **risk guard** that checks `_risk_blocked`:

```javascript
// ---- OPTIONS-ONLY sizing ----
const isOptionBuy = decision.startsWith("BUY_CALL") || decision.startsWith("BUY_PUT");

// ---- RISK GATE: Block if portfolio risk limits exceeded ----
const riskBlocked = plan._risk_blocked === true;
const riskBlockedReasons = plan._risk_blocked_reasons || [];
if (riskBlocked && isOptionBuy) {
  return [{
    json: {
      ...plan,
      qty: 0,
      sizing: {
        mode: "blocked_by_risk_limits",
        reason: `Portfolio risk limits exceeded: ${riskBlockedReasons.join(', ')}`,
        risk_blocked: true,
        risk_blocked_reasons: riskBlockedReasons,
      }
    }
  }];
}
```

> **✅ Bug Fix:** Previously `isOptionBuy` was referenced **before** its `const` declaration,
> causing a ReferenceError at runtime. The declaration has been moved above the risk gate
> check so the guard now works correctly.

This is a **defense-in-depth** layer: even if the Portfolio Risk Gate node fails to block, `Compute Size` will output `qty: 0`, and the downstream `If Order1` node will prevent submission (since qty=0 → no order payload).

### 10.9 Complete Gate Chain (Defense in Depth)

The orchestration pipeline has **5 layers of protection** that stop the workflow before order submission:

```
Layer 1: Select Contract (Liquid)     → option_liquidity_ok = false → candidate_pass = false
Layer 2: Liquidity OK? (IF node)      → FALSE → Force WAIT → Enrich Payload for AI (WAIT decision)
Layer 3: Compare Candidates           → candidate_pass = false → option_decision = WAIT
Layer 4: Switch (confidence gate)     → confidencePct < 65 → skip execution path
Layer 5: Compute Size (risk guard)    → _risk_blocked = true → qty = 0 → If Order1 → skip
```

With `order_lifecycle` integration (Phase 2), each gate also **records** the blocked intent:

| Gate | order_lifecycle Status | close_reason |
|---|---|---|
| Liquidity Gate | `CANCELLED` | `LIQUIDITY_GATE` |
| Portfolio Risk Gate | `CANCELLED` | `RISK_LIMIT` |
| Confidence Gate | Not recorded (INTENT only) | `LOW_CONFIDENCE` |
| Compute Size Guard | `CANCELLED` | `SIZE_BLOCKED` |
| If Order1 (qty=0) | `CANCELLED` | `ZERO_QTY` |

This gives complete visibility into WHY orders were blocked and enables analysis like:
- "How many trades did we miss due to liquidity?" 
- "How often does the portfolio risk limit block entries?"
- "What's the opportunity cost of the confidence gate?"

### 10.10 Implementation Status

| Fix | Status | Details |
|---|---|---|
| **Force WAIT dead-end** | ✅ Done | Connected `Force WAIT (Liquidity Gate)` → `Enrich Payload for AI` in workflow connections |
| **`isOptionBuy` used-before-declared** | ✅ Done | Moved `const isOptionBuy` declaration above the risk gate check in `Compute Size` |
| **Gate-blocked metadata** | ✅ Done | `Force WAIT` now sets `_gate_blocked`, `_gate_blocked_by`, `_gate_blocked_reason`, `_gate_blocked_at` |
| **order_lifecycle INTENT** | ✅ Exists | Already implemented in `Save Orchestration Decision` (creates INTENT for NEW_ENTRY/REVERSE) |
| **Portfolio Risk Guard** | ✅ Exists | `Edit Fields` passes `_risk_blocked` → `Compute Size` blocks with `qty: 0` (now works with isOptionBuy fix) |
| **Portfolio Risk Gate node** | ⏳ Phase 2 | Dedicated IF node calling `check_portfolio_risk_limits()` not yet added as a separate gate |
| **order_lifecycle CANCELLED on gate block** | ⏳ Phase 2 | Downstream persist node needs to check `_gate_blocked` flag and update lifecycle accordingly |

---

## Summary: Does the Current Approach Scale?

| Aspect | Scales? | Why / Fix |
|---|---|---|
| **Signal pipeline** (indicators, options selection) | ✅ Yes | Already per-ticker, no changes needed |
| **Database schema** (sessions, snapshots, decisions) | ✅ Yes | All tables are ticker-scoped with proper indexes |
| **Orchestrator context** | ❌ No | Queries are ticker-only — needs cross-ticker views |
| **Capital management** | ❌ No | No serialization, no portfolio-level limits |
| **Order state tracking** | ❌ No | Split across 3 tables — needs unified `order_lifecycle` |
| **Order fill confirmation** | ❌ No | Never checks if orders actually filled |
| **AI orchestrator prompt** | ⚠️ Partial | Works per-ticker but needs portfolio awareness rules |
| **Workflow structure** | ⚠️ Partial | Single-ticker pipeline is fine; needs watchlist loop for multi-ticker |

**Bottom line:** The signal pipeline and database schema scale fine. The bottleneck is in the **orchestration layer** — specifically the lack of portfolio-level awareness, unified order state, and capital serialization. The `008_order_lifecycle_and_portfolio_risk.sql` migration + the workflow changes in Phases 1-2 fix the critical gaps with minimal disruption to the existing system.
