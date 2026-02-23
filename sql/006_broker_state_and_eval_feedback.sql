-- 006_broker_state_and_eval_feedback.sql
-- Adds broker state synchronization tables and a view for evaluation feedback.
--
-- GAP 1: Real Alpaca positions are not tracked — only virtual position_journal.
--         If orders fill/cancel externally, the orchestrator is blind.
-- GAP 2: Open/pending orders are not checked before submitting new ones,
--         risking duplicate orders.
-- GAP 3: Trade evaluation grades/lessons are not fed back to the orchestrator
--         for learning from past mistakes.
--
-- This migration adds:
--   1. trading.broker_positions   — snapshot of real Alpaca positions
--   2. trading.broker_open_orders — snapshot of real Alpaca open/pending orders
--   3. trading.v_recent_evaluations_feedback — compact view for AI orchestrator

-- ============================================================
-- 1. BROKER POSITIONS (real Alpaca positions snapshot)
-- ============================================================
CREATE TABLE IF NOT EXISTS trading.broker_positions (
  id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  ticker          VARCHAR(20)   NOT NULL,
  symbol          VARCHAR(60)   NOT NULL,          -- OCC option symbol or equity symbol
  asset_class     VARCHAR(20)   DEFAULT 'us_option',
  side            VARCHAR(10),                     -- long / short
  qty             NUMERIC(18,4),
  avg_entry_price NUMERIC(18,4),
  market_value    NUMERIC(18,4),
  cost_basis      NUMERIC(18,4),
  unrealized_pl   NUMERIC(18,4),
  unrealized_plpc NUMERIC(18,6),
  current_price   NUMERIC(18,4),
  change_today    NUMERIC(18,6),
  asset_id        VARCHAR(60),
  raw_payload     JSONB,
  synced_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_broker_positions_ticker
  ON trading.broker_positions (ticker, synced_at DESC);

-- ============================================================
-- 2. BROKER OPEN ORDERS (real Alpaca open/pending orders snapshot)
-- ============================================================
CREATE TABLE IF NOT EXISTS trading.broker_open_orders (
  id                UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  ticker            VARCHAR(20)   NOT NULL,
  alpaca_order_id   VARCHAR(60),
  client_order_id   VARCHAR(60),
  symbol            VARCHAR(60)   NOT NULL,          -- OCC option symbol or equity
  asset_class       VARCHAR(20)   DEFAULT 'us_option',
  side              VARCHAR(10),                     -- buy / sell
  qty               NUMERIC(18,4),
  filled_qty        NUMERIC(18,4),
  order_type        VARCHAR(20),                     -- limit / market / stop / stop_limit
  time_in_force     VARCHAR(10),                     -- day / gtc / ioc
  limit_price       NUMERIC(18,4),
  stop_price        NUMERIC(18,4),
  status            VARCHAR(30),                     -- new, partially_filled, accepted, pending_new
  position_intent   VARCHAR(30),                     -- buy_to_open, sell_to_close, etc.
  submitted_at      TIMESTAMPTZ,
  created_at_broker TIMESTAMPTZ,
  raw_payload       JSONB,
  synced_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_broker_open_orders_ticker
  ON trading.broker_open_orders (ticker, synced_at DESC);

-- ============================================================
-- 3. VIEW: Latest broker positions (most recent sync only)
-- ============================================================
CREATE OR REPLACE VIEW trading.v_broker_positions_latest AS
SELECT bp.*
FROM trading.broker_positions bp
WHERE bp.synced_at = (
  SELECT MAX(synced_at) FROM trading.broker_positions
);

-- ============================================================
-- 4. VIEW: Latest broker open orders (most recent sync only)
-- ============================================================
CREATE OR REPLACE VIEW trading.v_broker_open_orders_latest AS
SELECT boo.*
FROM trading.broker_open_orders boo
WHERE boo.synced_at = (
  SELECT MAX(synced_at) FROM trading.broker_open_orders
);

-- ============================================================
-- 5. VIEW: Recent trade evaluations feedback for orchestrator
--    Compact view showing the AI evaluator's grades and lessons
--    from recent closed trades, so the orchestrator can learn.
-- ============================================================
CREATE OR REPLACE VIEW trading.v_evaluation_feedback AS
SELECT
  ticker,
  profile,
  trade_date,
  decision_type,
  contract_symbol,
  outcome,
  evaluation_grade,
  evaluation_score,
  signal_quality,
  timing_quality,
  risk_management_quality,
  critique,
  lessons_learned,
  would_take_again,
  entry_price,
  exit_price,
  pnl_total,
  price_change_pct,
  hold_duration_minutes,
  created_at
FROM trading.trade_evaluations
ORDER BY created_at DESC;
