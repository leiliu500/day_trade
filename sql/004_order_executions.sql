-- ============================================================================
-- Migration: Add order_executions table for tracking real broker executions
-- ============================================================================
-- When the workflow executes EXIT, REDUCE_EXPOSURE, or REVERSE decisions
-- via Alpaca API, the result (order ID, fill status, errors) must be
-- persisted so the AI Orchestrator can see what actually happened —
-- not just what it planned.
--
-- Usage:
--   psql -U postgres -d day_trade -f 004_order_executions.sql
-- ============================================================================

\connect day_trade;

SET search_path TO trading, public;

-- ============================================================================
-- 1. order_executions
--    Tracks every real Alpaca API call made by the execution nodes.
--    One row per API call (EXIT close, REDUCE sell, REVERSE close, etc.)
-- ============================================================================
CREATE TABLE IF NOT EXISTS order_executions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticker              VARCHAR(20) NOT NULL,
    profile             VARCHAR(5),                  -- S / M / L
    trade_date          DATE DEFAULT CURRENT_DATE,

    -- Which orchestrator decision triggered this execution?
    decision_type       VARCHAR(30) NOT NULL,        -- EXIT / REDUCE_EXPOSURE / REVERSE / NEW_ENTRY / ADD_POSITION
    execution_action    VARCHAR(30) NOT NULL,        -- CLOSE_ALL / SELL_PARTIAL / CLOSE_FOR_REVERSE / BUY_NEW

    -- What was sent to Alpaca?
    contract_symbol     VARCHAR(60),                 -- OCC option symbol or underlying
    side                VARCHAR(10),                 -- buy / sell
    qty                 INTEGER,
    order_type          VARCHAR(20),                 -- market / limit / delete_position
    request_payload     JSONB,                       -- full request body sent

    -- What came back from Alpaca?
    alpaca_order_id     VARCHAR(60),                 -- Alpaca order UUID
    alpaca_status       VARCHAR(30),                 -- accepted / filled / rejected / etc.
    fill_price          NUMERIC(12,4),
    filled_qty          INTEGER,
    http_status_code    INTEGER,
    response_payload    JSONB,                       -- full API response

    -- Execution outcome
    success             BOOLEAN NOT NULL DEFAULT false,
    error_message       TEXT,

    -- Orchestrator context at execution time
    orchestration_reasoning TEXT,
    ai_confidence       NUMERIC(8,4),

    executed_at         TIMESTAMPTZ DEFAULT NOW(),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_order_exec_ticker_date
    ON order_executions(ticker, trade_date, executed_at DESC);

CREATE INDEX IF NOT EXISTS idx_order_exec_decision_type
    ON order_executions(decision_type, executed_at DESC);

-- ============================================================================
-- 2. View: v_recent_executions
--    For the orchestrator to quickly see what was actually executed today.
-- ============================================================================
CREATE OR REPLACE VIEW v_recent_executions AS
SELECT
    oe.*
FROM order_executions oe
WHERE oe.trade_date = CURRENT_DATE
ORDER BY oe.executed_at DESC
LIMIT 50;

-- ============================================================================
-- 3. Update 003_cleanup_database.sql awareness
--    NOTE: Add order_executions to your TRUNCATE list in 003_cleanup_database.sql
--    when running full cleanups:
--
--    TRUNCATE TABLE
--        trading.order_executions,
--        trading.decision_confirmations,
--        trading.position_journal,
--        ...
-- ============================================================================
