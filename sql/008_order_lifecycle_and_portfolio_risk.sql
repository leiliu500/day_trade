-- ============================================================================
-- Migration 008: Order Lifecycle Management & Portfolio Risk Controls
-- ============================================================================
-- Adds dedicated tables for tracking individual orders through their
-- complete lifecycle, enforcing portfolio-level risk limits, and enabling
-- multi-ticker / multi-order orchestration at scale (10+ concurrent orders).
--
-- Problem:
--   The current system tracks orders as a side-effect of orchestration
--   decisions (position_journal + order_executions). When scaling to
--   10+ orders across multiple tickers, several issues emerge:
--     1. No per-order state machine (PENDING → SUBMITTED → FILLED → CLOSED)
--     2. No portfolio-level risk aggregation (total exposure, max positions)
--     3. No cross-ticker awareness in the orchestrator context
--     4. No concurrency control (two triggers can double-allocate capital)
--     5. No parent-child order relationships (brackets, OCO, legs)
--
-- This migration adds:
--   1. trading.order_lifecycle       — per-order state machine
--   2. trading.portfolio_risk_state  — real-time portfolio risk snapshot
--   3. trading.portfolio_risk_limits — configurable risk limits
--   4. trading.order_groups          — parent-child order grouping
--   5. Views for cross-ticker orchestration context
--
-- Usage:
--   psql -U postgres -d day_trade -f 008_order_lifecycle_and_portfolio_risk.sql
-- ============================================================================

\connect day_trade;

SET search_path TO trading, public;

-- ============================================================================
-- 1. order_lifecycle
--    One row per order. Tracks an order from intent through execution
--    to final resolution. This is the single source of truth for
--    "what is the state of each order?" — replaces the split between
--    position_journal (virtual) and order_executions (execution log).
--
--    State Machine:
--      INTENT → SUBMITTED → ACCEPTED → PARTIALLY_FILLED → FILLED
--                                                        → CANCELLED
--                                                        → REJECTED
--                                                        → EXPIRED
--      FILLED → MONITORING → CLOSING → CLOSED
--
--    Each state transition is timestamped. The orchestrator reads
--    the current state to decide next actions.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading.order_lifecycle (
    id                  UUID DEFAULT gen_random_uuid() PRIMARY KEY,

    -- Identity
    ticker              VARCHAR(20)   NOT NULL,
    profile             VARCHAR(5),                      -- S / M / L
    trade_date          DATE          NOT NULL DEFAULT CURRENT_DATE,

    -- Grouping
    group_id            UUID,                            -- FK to order_groups (brackets, legs)
    group_role          VARCHAR(20),                     -- ENTRY / STOP_LOSS / TAKE_PROFIT / LEG_1 / LEG_2

    -- What triggered this order?
    decision_id         UUID,                            -- FK to trading_decisions
    decision_type       VARCHAR(30)   NOT NULL,          -- NEW_ENTRY / ADD_POSITION / REDUCE_EXPOSURE / EXIT / REVERSE
    signal_snapshot_id  UUID,                            -- FK to signal_snapshots

    -- Order identity
    client_order_id     VARCHAR(60),                     -- our generated ID (for idempotency)
    alpaca_order_id     VARCHAR(60),                     -- Alpaca's UUID

    -- Order details
    contract_symbol     VARCHAR(60)   NOT NULL,          -- OCC option symbol
    asset_class         VARCHAR(20)   DEFAULT 'us_option',
    side                VARCHAR(10)   NOT NULL,          -- buy / sell
    position_intent     VARCHAR(30),                     -- buy_to_open / sell_to_close / buy_to_close / sell_to_open
    order_type          VARCHAR(20)   NOT NULL,          -- market / limit / stop / stop_limit
    time_in_force       VARCHAR(10)   DEFAULT 'day',

    -- Prices
    limit_price         NUMERIC(12,4),
    stop_price          NUMERIC(12,4),
    intended_entry      NUMERIC(12,4),                   -- what we wanted
    avg_fill_price      NUMERIC(12,4),                   -- what we got

    -- Quantities
    requested_qty       INTEGER       NOT NULL DEFAULT 1,
    filled_qty          INTEGER       DEFAULT 0,
    remaining_qty       INTEGER       GENERATED ALWAYS AS (requested_qty - filled_qty) STORED,

    -- Position management levels (set at entry, updated on CONFIRM_HOLD)
    stop_level          NUMERIC(12,4),                   -- current stop-loss premium
    target_level        NUMERIC(12,4),                   -- current take-profit premium
    trail_offset        NUMERIC(12,4),                   -- trailing stop offset (if trailing)
    high_water_mark     NUMERIC(12,4),                   -- highest premium reached (for trailing)

    -- State machine
    status              VARCHAR(20)   NOT NULL DEFAULT 'INTENT',
    -- INTENT           : decision made, order not yet submitted
    -- SUBMITTED        : POST /v2/orders sent
    -- ACCEPTED         : Alpaca accepted (status=accepted/new)
    -- PARTIALLY_FILLED : some qty filled
    -- FILLED           : all qty filled
    -- MONITORING       : position open, actively managed
    -- CLOSING          : close order submitted
    -- CLOSED           : position fully closed
    -- CANCELLED        : order was cancelled (by us or broker)
    -- REJECTED         : broker rejected the order
    -- EXPIRED          : order expired (TIF=day, market closed)
    -- ERROR            : unrecoverable error

    close_reason        VARCHAR(30),                     -- STOP_HIT / TARGET_HIT / EXIT_SIGNAL / REDUCE / REVERSE / EOD / MANUAL
    close_fill_price    NUMERIC(12,4),
    close_order_id      VARCHAR(60),                     -- Alpaca order ID for the close

    -- P&L (computed after close)
    realized_pnl        NUMERIC(14,4),                   -- (close_fill - avg_fill) * filled_qty * multiplier
    pnl_per_contract    NUMERIC(12,4),
    multiplier          INTEGER       DEFAULT 100,       -- 100 for options, 1 for equity

    -- Context at order time
    confidence_at_order NUMERIC(8,4),
    trend_at_order      VARCHAR(20),
    alignment_at_order  VARCHAR(30),
    conviction_score    INTEGER,
    conviction_tier     VARCHAR(20),                     -- REGULAR / SIZABLE / MAX_CONVICTION

    -- Error tracking
    error_message       TEXT,
    retry_count         INTEGER       DEFAULT 0,
    max_retries         INTEGER       DEFAULT 3,

    -- Timestamps (state machine transitions)
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    submitted_at        TIMESTAMPTZ,
    accepted_at         TIMESTAMPTZ,
    first_fill_at       TIMESTAMPTZ,
    filled_at           TIMESTAMPTZ,
    monitoring_since    TIMESTAMPTZ,
    close_submitted_at  TIMESTAMPTZ,
    closed_at           TIMESTAMPTZ,
    cancelled_at        TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Primary query patterns
CREATE INDEX IF NOT EXISTS idx_ol_ticker_date_status
    ON trading.order_lifecycle (ticker, trade_date, status);

CREATE INDEX IF NOT EXISTS idx_ol_status
    ON trading.order_lifecycle (status) WHERE status NOT IN ('CLOSED', 'CANCELLED', 'REJECTED', 'EXPIRED', 'ERROR');

CREATE INDEX IF NOT EXISTS idx_ol_alpaca_order_id
    ON trading.order_lifecycle (alpaca_order_id) WHERE alpaca_order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ol_group_id
    ON trading.order_lifecycle (group_id) WHERE group_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_ol_trade_date
    ON trading.order_lifecycle (trade_date, created_at DESC);

-- Unique constraint: one Alpaca order ID per row (prevent duplicates)
CREATE UNIQUE INDEX IF NOT EXISTS idx_ol_alpaca_unique
    ON trading.order_lifecycle (alpaca_order_id) WHERE alpaca_order_id IS NOT NULL;

COMMENT ON TABLE trading.order_lifecycle IS
  'Single source of truth for every order from intent to close. Replaces the split between position_journal (virtual) and order_executions (log).';


-- ============================================================================
-- 2. order_groups
--    Groups related orders together (bracket orders, multi-leg spreads,
--    REVERSE close+open pairs, ADD_POSITION chains).
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading.order_groups (
    id                  UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    ticker              VARCHAR(20)   NOT NULL,
    trade_date          DATE          NOT NULL DEFAULT CURRENT_DATE,
    group_type          VARCHAR(30)   NOT NULL,
    -- BRACKET          : entry + stop_loss + take_profit
    -- REVERSE_PAIR     : close old + open opposite
    -- ADD_CHAIN        : original entry + add-on entries
    -- SPREAD           : multi-leg spread (future)
    -- SCALE_OUT        : partial close chain

    parent_order_id     UUID,                            -- the "primary" order in the group
    status              VARCHAR(20)   DEFAULT 'ACTIVE',  -- ACTIVE / COMPLETED / CANCELLED
    notes               TEXT,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Add FK now that both tables exist
-- (order_lifecycle.group_id → order_groups.id)
-- We use DO block to avoid error if constraint already exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'fk_ol_group'
    ) THEN
        ALTER TABLE trading.order_lifecycle
            ADD CONSTRAINT fk_ol_group
            FOREIGN KEY (group_id) REFERENCES trading.order_groups(id);
    END IF;
END $$;


-- ============================================================================
-- 3. portfolio_risk_limits
--    Configurable risk limits. One row per limit type.
--    The orchestrator checks these BEFORE allowing new orders.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading.portfolio_risk_limits (
    id                  UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    limit_name          VARCHAR(60)   NOT NULL UNIQUE,
    limit_value         NUMERIC(18,4) NOT NULL,
    description         TEXT,
    enabled             BOOLEAN       DEFAULT TRUE,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- Seed default limits (idempotent: ON CONFLICT DO NOTHING)
INSERT INTO trading.portfolio_risk_limits (limit_name, limit_value, description, enabled) VALUES
    ('max_concurrent_positions',    5,       'Maximum number of simultaneously open positions across all tickers', TRUE),
    ('max_positions_per_ticker',    2,       'Maximum open positions per single ticker (e.g., call + put)', TRUE),
    ('max_daily_orders',           20,       'Maximum total orders (entries) per day', TRUE),
    ('max_daily_loss_usd',       500.00,     'Stop trading after daily realized loss exceeds this amount', TRUE),
    ('max_daily_loss_pct',         2.00,     'Stop trading after daily realized loss exceeds this % of equity', TRUE),
    ('max_single_order_risk_pct',  0.50,     'Maximum risk per single order as % of equity', TRUE),
    ('max_portfolio_risk_pct',     3.00,     'Maximum total portfolio risk (all open positions) as % of equity', TRUE),
    ('max_ticker_exposure_pct',    1.50,     'Maximum total exposure to a single ticker as % of equity', TRUE),
    ('min_buying_power_reserve',  500.00,    'Keep at least this much buying power in reserve', TRUE),
    ('max_correlated_positions',    3,       'Maximum positions in correlated tickers (e.g., SPY+QQQ+IWM)', TRUE)
ON CONFLICT (limit_name) DO NOTHING;


-- ============================================================================
-- 4. portfolio_risk_state
--    Snapshot of current portfolio risk metrics.
--    Updated by the orchestrator or a dedicated risk-check node
--    before every order decision.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading.portfolio_risk_state (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    snapshot_time           TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    trade_date              DATE          NOT NULL DEFAULT CURRENT_DATE,

    -- Account state
    equity                  NUMERIC(18,4),
    buying_power            NUMERIC(18,4),
    cash                    NUMERIC(18,4),

    -- Position counts
    open_position_count     INTEGER       DEFAULT 0,
    open_tickers            JSONB,                       -- ["SPY","AAPL","TSLA"]
    positions_by_ticker     JSONB,                       -- {"SPY":2,"AAPL":1}

    -- Risk aggregation
    total_exposure_usd      NUMERIC(18,4) DEFAULT 0,     -- sum of (fill_price * qty * multiplier)
    total_risk_usd          NUMERIC(18,4) DEFAULT 0,     -- sum of (entry - stop) * qty * multiplier
    total_unrealized_pnl    NUMERIC(18,4) DEFAULT 0,

    -- Daily P&L
    daily_realized_pnl      NUMERIC(18,4) DEFAULT 0,
    daily_order_count       INTEGER       DEFAULT 0,
    daily_win_count         INTEGER       DEFAULT 0,
    daily_loss_count        INTEGER       DEFAULT 0,

    -- Limit checks (computed)
    can_open_new_position   BOOLEAN       DEFAULT TRUE,
    blocked_reasons         JSONB,                       -- ["max_concurrent_positions","max_daily_loss_usd"]

    created_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_prs_trade_date
    ON trading.portfolio_risk_state (trade_date, snapshot_time DESC);


-- ============================================================================
-- 5. VIEWS — Cross-Ticker Orchestration Context
-- ============================================================================

-- 5a. All active orders (not yet closed/cancelled/expired)
CREATE OR REPLACE VIEW trading.v_active_orders AS
SELECT
    ol.id,
    ol.ticker,
    ol.profile,
    ol.trade_date,
    ol.decision_type,
    ol.contract_symbol,
    ol.side,
    ol.position_intent,
    ol.order_type,
    ol.status,
    ol.intended_entry,
    ol.avg_fill_price,
    ol.requested_qty,
    ol.filled_qty,
    ol.remaining_qty,
    ol.stop_level,
    ol.target_level,
    ol.confidence_at_order,
    ol.conviction_tier,
    ol.group_id,
    ol.group_role,
    ol.created_at,
    ol.updated_at
FROM trading.order_lifecycle ol
WHERE ol.status NOT IN ('CLOSED', 'CANCELLED', 'REJECTED', 'EXPIRED', 'ERROR')
ORDER BY ol.created_at DESC;

-- 5b. Open positions (FILLED or MONITORING status)
CREATE OR REPLACE VIEW trading.v_open_positions_live AS
SELECT
    ol.id AS order_id,
    ol.ticker,
    ol.profile,
    ol.trade_date,
    ol.contract_symbol,
    ol.side,
    ol.position_intent,
    ol.avg_fill_price,
    ol.requested_qty,
    ol.filled_qty,
    ol.stop_level,
    ol.target_level,
    ol.trail_offset,
    ol.high_water_mark,
    ol.confidence_at_order,
    ol.trend_at_order,
    ol.alignment_at_order,
    ol.conviction_tier,
    ol.status,
    ol.decision_type,
    ol.group_id,
    ol.created_at,
    ol.filled_at,
    ol.monitoring_since,
    -- Duration in minutes since fill
    EXTRACT(EPOCH FROM (NOW() - COALESCE(ol.filled_at, ol.created_at))) / 60.0 AS hold_minutes
FROM trading.order_lifecycle ol
WHERE ol.status IN ('FILLED', 'MONITORING')
  AND ol.trade_date = CURRENT_DATE
ORDER BY ol.ticker, ol.filled_at;

-- 5c. Portfolio summary (cross-ticker) for the orchestrator
CREATE OR REPLACE VIEW trading.v_portfolio_summary AS
SELECT
    COUNT(*) AS total_open_positions,
    COUNT(DISTINCT ticker) AS distinct_tickers,
    ARRAY_AGG(DISTINCT ticker) AS tickers,
    JSONB_OBJECT_AGG(
        ticker,
        (SELECT COUNT(*) FROM trading.order_lifecycle sub
         WHERE sub.ticker = ol.ticker
           AND sub.status IN ('FILLED','MONITORING')
           AND sub.trade_date = CURRENT_DATE)
    ) AS positions_per_ticker,
    COALESCE(SUM(avg_fill_price * filled_qty * COALESCE(multiplier,100)), 0) AS total_exposure_usd,
    COALESCE(SUM(
        CASE WHEN stop_level IS NOT NULL
             THEN (avg_fill_price - stop_level) * filled_qty * COALESCE(multiplier,100)
             ELSE 0 END
    ), 0) AS total_risk_usd
FROM trading.order_lifecycle ol
WHERE ol.status IN ('FILLED', 'MONITORING')
  AND ol.trade_date = CURRENT_DATE;

-- 5d. Daily P&L from closed orders today
CREATE OR REPLACE VIEW trading.v_daily_pnl AS
SELECT
    trade_date,
    COUNT(*) AS closed_orders,
    COUNT(*) FILTER (WHERE realized_pnl > 0) AS wins,
    COUNT(*) FILTER (WHERE realized_pnl < 0) AS losses,
    COUNT(*) FILTER (WHERE realized_pnl = 0) AS breakeven,
    COALESCE(SUM(realized_pnl), 0) AS total_realized_pnl,
    ROUND(AVG(realized_pnl)::NUMERIC, 2) AS avg_pnl_per_order,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE realized_pnl > 0)
        / NULLIF(COUNT(*), 0), 1
    ) AS win_rate_pct
FROM trading.order_lifecycle
WHERE status = 'CLOSED'
  AND trade_date = CURRENT_DATE
GROUP BY trade_date;

-- 5e. Pending orders (SUBMITTED/ACCEPTED/PARTIALLY_FILLED — awaiting fill)
CREATE OR REPLACE VIEW trading.v_pending_orders AS
SELECT
    ol.id,
    ol.ticker,
    ol.contract_symbol,
    ol.side,
    ol.order_type,
    ol.status,
    ol.limit_price,
    ol.requested_qty,
    ol.filled_qty,
    ol.remaining_qty,
    ol.alpaca_order_id,
    ol.client_order_id,
    ol.submitted_at,
    EXTRACT(EPOCH FROM (NOW() - ol.submitted_at)) AS seconds_since_submit,
    ol.retry_count
FROM trading.order_lifecycle ol
WHERE ol.status IN ('SUBMITTED', 'ACCEPTED', 'PARTIALLY_FILLED')
ORDER BY ol.submitted_at;

-- 5f. Orders needing attention (stale pending, errored, retryable)
CREATE OR REPLACE VIEW trading.v_orders_needing_attention AS
SELECT
    ol.id,
    ol.ticker,
    ol.contract_symbol,
    ol.status,
    ol.error_message,
    ol.retry_count,
    ol.max_retries,
    CASE
        WHEN ol.status = 'ERROR' AND ol.retry_count < ol.max_retries THEN 'RETRYABLE'
        WHEN ol.status IN ('SUBMITTED','ACCEPTED') AND ol.submitted_at < NOW() - INTERVAL '2 minutes' THEN 'STALE_PENDING'
        WHEN ol.status = 'PARTIALLY_FILLED' AND ol.submitted_at < NOW() - INTERVAL '5 minutes' THEN 'PARTIAL_STALE'
        ELSE 'REVIEW'
    END AS attention_type,
    ol.submitted_at,
    ol.created_at
FROM trading.order_lifecycle ol
WHERE (
    (ol.status = 'ERROR' AND ol.retry_count < ol.max_retries)
    OR (ol.status IN ('SUBMITTED','ACCEPTED') AND ol.submitted_at < NOW() - INTERVAL '2 minutes')
    OR (ol.status = 'PARTIALLY_FILLED' AND ol.submitted_at < NOW() - INTERVAL '5 minutes')
)
AND ol.trade_date = CURRENT_DATE
ORDER BY ol.created_at;


-- ============================================================================
-- 6. FUNCTION: check_portfolio_risk_limits()
--    Called before every NEW_ENTRY / ADD_POSITION to enforce limits.
--    Returns JSON with { allowed: bool, blocked_reasons: [...] }
-- ============================================================================
CREATE OR REPLACE FUNCTION trading.check_portfolio_risk_limits(
    p_ticker VARCHAR,
    p_equity NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_limits          RECORD;
    v_blocked         JSONB := '[]'::JSONB;
    v_open_count      INTEGER;
    v_ticker_count    INTEGER;
    v_daily_orders    INTEGER;
    v_daily_loss      NUMERIC;
    v_total_risk      NUMERIC;
    v_ticker_exposure NUMERIC;
BEGIN
    -- Count open positions
    SELECT COUNT(*) INTO v_open_count
    FROM trading.order_lifecycle
    WHERE status IN ('FILLED','MONITORING')
      AND trade_date = CURRENT_DATE;

    -- Count open positions for this ticker
    SELECT COUNT(*) INTO v_ticker_count
    FROM trading.order_lifecycle
    WHERE status IN ('FILLED','MONITORING')
      AND trade_date = CURRENT_DATE
      AND ticker = p_ticker;

    -- Count today's entry orders
    SELECT COUNT(*) INTO v_daily_orders
    FROM trading.order_lifecycle
    WHERE trade_date = CURRENT_DATE
      AND decision_type IN ('NEW_ENTRY','ADD_POSITION');

    -- Today's realized loss
    SELECT COALESCE(SUM(realized_pnl), 0) INTO v_daily_loss
    FROM trading.order_lifecycle
    WHERE status = 'CLOSED'
      AND trade_date = CURRENT_DATE
      AND realized_pnl < 0;

    -- Total risk of open positions
    SELECT COALESCE(SUM(
        CASE WHEN stop_level IS NOT NULL
             THEN (avg_fill_price - stop_level) * filled_qty * COALESCE(multiplier,100)
             ELSE avg_fill_price * filled_qty * COALESCE(multiplier,100) * 0.05 -- assume 5% risk if no stop
        END
    ), 0) INTO v_total_risk
    FROM trading.order_lifecycle
    WHERE status IN ('FILLED','MONITORING')
      AND trade_date = CURRENT_DATE;

    -- Ticker exposure
    SELECT COALESCE(SUM(avg_fill_price * filled_qty * COALESCE(multiplier,100)), 0)
    INTO v_ticker_exposure
    FROM trading.order_lifecycle
    WHERE status IN ('FILLED','MONITORING')
      AND trade_date = CURRENT_DATE
      AND ticker = p_ticker;

    -- Check each limit
    FOR v_limits IN
        SELECT limit_name, limit_value FROM trading.portfolio_risk_limits WHERE enabled = TRUE
    LOOP
        CASE v_limits.limit_name
            WHEN 'max_concurrent_positions' THEN
                IF v_open_count >= v_limits.limit_value THEN
                    v_blocked := v_blocked || jsonb_build_array(
                        format('max_concurrent_positions: %s open >= limit %s', v_open_count, v_limits.limit_value)
                    );
                END IF;
            WHEN 'max_positions_per_ticker' THEN
                IF v_ticker_count >= v_limits.limit_value THEN
                    v_blocked := v_blocked || jsonb_build_array(
                        format('max_positions_per_ticker: %s has %s open >= limit %s', p_ticker, v_ticker_count, v_limits.limit_value)
                    );
                END IF;
            WHEN 'max_daily_orders' THEN
                IF v_daily_orders >= v_limits.limit_value THEN
                    v_blocked := v_blocked || jsonb_build_array(
                        format('max_daily_orders: %s orders today >= limit %s', v_daily_orders, v_limits.limit_value)
                    );
                END IF;
            WHEN 'max_daily_loss_usd' THEN
                IF ABS(v_daily_loss) >= v_limits.limit_value THEN
                    v_blocked := v_blocked || jsonb_build_array(
                        format('max_daily_loss_usd: daily loss $%s >= limit $%s', ABS(v_daily_loss), v_limits.limit_value)
                    );
                END IF;
            WHEN 'max_daily_loss_pct' THEN
                IF p_equity IS NOT NULL AND p_equity > 0 THEN
                    IF (ABS(v_daily_loss) / p_equity * 100) >= v_limits.limit_value THEN
                        v_blocked := v_blocked || jsonb_build_array(
                            format('max_daily_loss_pct: daily loss %s%% >= limit %s%%',
                                ROUND(ABS(v_daily_loss) / p_equity * 100, 2), v_limits.limit_value)
                        );
                    END IF;
                END IF;
            WHEN 'max_portfolio_risk_pct' THEN
                IF p_equity IS NOT NULL AND p_equity > 0 THEN
                    IF (v_total_risk / p_equity * 100) >= v_limits.limit_value THEN
                        v_blocked := v_blocked || jsonb_build_array(
                            format('max_portfolio_risk_pct: portfolio risk %s%% >= limit %s%%',
                                ROUND(v_total_risk / p_equity * 100, 2), v_limits.limit_value)
                        );
                    END IF;
                END IF;
            WHEN 'max_ticker_exposure_pct' THEN
                IF p_equity IS NOT NULL AND p_equity > 0 THEN
                    IF (v_ticker_exposure / p_equity * 100) >= v_limits.limit_value THEN
                        v_blocked := v_blocked || jsonb_build_array(
                            format('max_ticker_exposure_pct: %s exposure %s%% >= limit %s%%',
                                p_ticker, ROUND(v_ticker_exposure / p_equity * 100, 2), v_limits.limit_value)
                        );
                    END IF;
                END IF;
            WHEN 'min_buying_power_reserve' THEN
                -- Checked at order submission time by the workflow, not here
                NULL;
            ELSE
                NULL;
        END CASE;
    END LOOP;

    RETURN jsonb_build_object(
        'allowed', jsonb_array_length(v_blocked) = 0,
        'blocked_reasons', v_blocked,
        'open_positions', v_open_count,
        'ticker_positions', v_ticker_count,
        'daily_orders', v_daily_orders,
        'daily_realized_loss', v_daily_loss,
        'total_risk_usd', v_total_risk,
        'ticker_exposure_usd', v_ticker_exposure,
        'checked_at', NOW()
    );
END;
$$;

COMMENT ON FUNCTION trading.check_portfolio_risk_limits IS
  'Pre-order risk gate. Call with (ticker, equity) before every NEW_ENTRY/ADD_POSITION. Returns {allowed, blocked_reasons, ...}.';


-- ============================================================================
-- 7. FUNCTION: transition_order_status()
--    Enforces valid state transitions and updates timestamps.
-- ============================================================================
CREATE OR REPLACE FUNCTION trading.transition_order_status(
    p_order_id      UUID,
    p_new_status    VARCHAR,
    p_fill_price    NUMERIC DEFAULT NULL,
    p_filled_qty    INTEGER DEFAULT NULL,
    p_error_msg     TEXT DEFAULT NULL,
    p_close_reason  VARCHAR DEFAULT NULL,
    p_alpaca_id     VARCHAR DEFAULT NULL
)
RETURNS trading.order_lifecycle
LANGUAGE plpgsql
AS $$
DECLARE
    v_order trading.order_lifecycle;
    v_valid BOOLEAN := FALSE;
BEGIN
    SELECT * INTO v_order FROM trading.order_lifecycle WHERE id = p_order_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found', p_order_id;
    END IF;

    -- Validate state transition
    v_valid := CASE v_order.status
        WHEN 'INTENT' THEN p_new_status IN ('SUBMITTED', 'CANCELLED', 'ERROR')
        WHEN 'SUBMITTED' THEN p_new_status IN ('ACCEPTED', 'FILLED', 'PARTIALLY_FILLED', 'REJECTED', 'CANCELLED', 'ERROR')
        WHEN 'ACCEPTED' THEN p_new_status IN ('FILLED', 'PARTIALLY_FILLED', 'CANCELLED', 'EXPIRED', 'ERROR')
        WHEN 'PARTIALLY_FILLED' THEN p_new_status IN ('FILLED', 'CANCELLED', 'ERROR')
        WHEN 'FILLED' THEN p_new_status IN ('MONITORING', 'CLOSING', 'CLOSED')
        WHEN 'MONITORING' THEN p_new_status IN ('CLOSING', 'CLOSED')
        WHEN 'CLOSING' THEN p_new_status IN ('CLOSED', 'ERROR')
        ELSE FALSE
    END;

    IF NOT v_valid THEN
        RAISE EXCEPTION 'Invalid transition: % → %', v_order.status, p_new_status;
    END IF;

    -- Apply transition
    UPDATE trading.order_lifecycle SET
        status = p_new_status,
        alpaca_order_id = COALESCE(p_alpaca_id, alpaca_order_id),
        avg_fill_price = COALESCE(p_fill_price, avg_fill_price),
        filled_qty = COALESCE(p_filled_qty, filled_qty),
        error_message = COALESCE(p_error_msg, error_message),
        close_reason = COALESCE(p_close_reason, close_reason),
        -- Timestamp transitions
        submitted_at = CASE WHEN p_new_status = 'SUBMITTED' THEN NOW() ELSE submitted_at END,
        accepted_at = CASE WHEN p_new_status = 'ACCEPTED' THEN NOW() ELSE accepted_at END,
        first_fill_at = CASE WHEN p_new_status IN ('PARTIALLY_FILLED','FILLED') AND first_fill_at IS NULL THEN NOW() ELSE first_fill_at END,
        filled_at = CASE WHEN p_new_status = 'FILLED' THEN NOW() ELSE filled_at END,
        monitoring_since = CASE WHEN p_new_status = 'MONITORING' THEN NOW() ELSE monitoring_since END,
        close_submitted_at = CASE WHEN p_new_status = 'CLOSING' THEN NOW() ELSE close_submitted_at END,
        closed_at = CASE WHEN p_new_status = 'CLOSED' THEN NOW() ELSE closed_at END,
        cancelled_at = CASE WHEN p_new_status IN ('CANCELLED','REJECTED','EXPIRED') THEN NOW() ELSE cancelled_at END,
        updated_at = NOW()
    WHERE id = p_order_id
    RETURNING * INTO v_order;

    -- If closed, compute P&L
    IF p_new_status = 'CLOSED' AND v_order.avg_fill_price IS NOT NULL AND v_order.close_fill_price IS NOT NULL THEN
        UPDATE trading.order_lifecycle SET
            pnl_per_contract = (close_fill_price - avg_fill_price) *
                CASE WHEN position_intent = 'sell_to_close' THEN 1
                     WHEN side = 'sell' THEN -1
                     ELSE 1 END,
            realized_pnl = (close_fill_price - avg_fill_price) *
                CASE WHEN position_intent = 'sell_to_close' THEN 1
                     WHEN side = 'sell' THEN -1
                     ELSE 1 END * filled_qty * COALESCE(multiplier, 100),
            updated_at = NOW()
        WHERE id = p_order_id
        RETURNING * INTO v_order;
    END IF;

    RETURN v_order;
END;
$$;


-- ============================================================================
-- 8. Update 003_cleanup_database.sql awareness
-- ============================================================================
-- When running full cleanups, add these tables to your TRUNCATE list:
--
--   TRUNCATE TABLE
--       trading.portfolio_risk_state,
--       trading.order_lifecycle,
--       trading.order_groups,
--       ... (existing tables) ...
--   RESTART IDENTITY CASCADE;
--
-- To reset risk limits to defaults:
--   DELETE FROM trading.portfolio_risk_limits;
--   Re-run the INSERT above.
-- ============================================================================
