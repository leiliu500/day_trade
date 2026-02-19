-- ============================================================================
-- Migration: Widen NUMERIC columns to prevent "numeric field overflow"
-- ============================================================================
-- The original NUMERIC(5,4) for confidence can only hold -9.9999..9.9999.
-- If an upstream node passes confidence as a percentage (e.g. 75 instead of
-- 0.75), the INSERT fails with "numeric field overflow".
--
-- This migration widens the columns as a safety net. The workflow code is also
-- updated to normalize confidence to 0..1 before inserting.
-- ============================================================================

\connect day_trade;

SET search_path TO trading, public;

-- Drop dependent views first (they reference columns being altered)
DROP VIEW IF EXISTS trading.v_today_signals CASCADE;
DROP VIEW IF EXISTS trading.v_latest_decisions CASCADE;
DROP VIEW IF EXISTS trading.v_active_positions CASCADE;
DROP VIEW IF EXISTS trading.v_confirmation_streaks CASCADE;

-- signal_snapshots
ALTER TABLE trading.signal_snapshots
  ALTER COLUMN confidence TYPE NUMERIC(8,4),
  ALTER COLUMN confidence_pct TYPE NUMERIC(8,2);

-- trading_decisions
ALTER TABLE trading.trading_decisions
  ALTER COLUMN orchestration_confidence TYPE NUMERIC(8,4),
  ALTER COLUMN ai_confidence TYPE NUMERIC(8,4),
  ALTER COLUMN current_confidence TYPE NUMERIC(8,4);

-- workflow_indicators (also has a confidence column)
ALTER TABLE trading.workflow_indicators
  ALTER COLUMN confidence TYPE NUMERIC(8,2);

-- Recreate views (aliased to avoid duplicate "profile" column)
CREATE OR REPLACE VIEW v_active_positions AS
SELECT
    pj.*,
    td.decision_type,
    td.direction,
    td.reasoning AS decision_reasoning,
    ts.trading_date,
    ts.profile AS session_profile
FROM position_journal pj
JOIN trading_decisions td ON td.id = pj.decision_id
JOIN trading_sessions ts ON ts.id = pj.session_id
WHERE pj.status = 'OPEN'
  AND ts.status = 'ACTIVE';

CREATE OR REPLACE VIEW v_latest_decisions AS
SELECT DISTINCT ON (ticker)
    td.*,
    ts.trading_date,
    ts.profile AS session_profile,
    ts.status AS session_status
FROM trading_decisions td
JOIN trading_sessions ts ON ts.id = td.session_id
WHERE ts.trading_date = CURRENT_DATE
ORDER BY ticker, td.decision_time DESC;

CREATE OR REPLACE VIEW v_today_signals AS
SELECT
    ss.*,
    ts.trading_date,
    ts.profile AS session_profile
FROM signal_snapshots ss
JOIN trading_sessions ts ON ts.id = ss.session_id
WHERE ts.trading_date = CURRENT_DATE
ORDER BY ss.ticker, ss.snapshot_time DESC;

CREATE OR REPLACE VIEW v_confirmation_streaks AS
SELECT
    dc.decision_id,
    td.ticker,
    td.trade_date,
    td.decision_type,
    td.direction,
    COUNT(*) FILTER (WHERE dc.confirms = true) AS total_confirms,
    COUNT(*) FILTER (WHERE dc.confirms = false) AS total_contradicts,
    MAX(dc.consecutive_confirms) AS max_consecutive_confirms,
    MAX(dc.consecutive_contradicts) AS max_consecutive_contradicts,
    MAX(dc.confirmed_at) AS last_check_at
FROM decision_confirmations dc
JOIN trading_decisions td ON td.id = dc.decision_id
GROUP BY dc.decision_id, td.ticker, td.trade_date, td.decision_type, td.direction;
