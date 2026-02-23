-- ============================================================================
-- Migration: Add trade_evaluations table for AI Trade Evaluation Agent
-- ============================================================================
-- After an order is closed (EXIT, REDUCE, REVERSE), the AI Trade Evaluation
-- Agent critiques what the orchestration agent did:
--   - Compares entry price vs exit/close price
--   - Determines if outcome was positive or negative
--   - Calculates realized P&L per contract and total
--   - AI generates a critique of the orchestration decision quality
--   - Sends alert via Telegram
--   - Persists evaluation for historical tracking and improvement
--
-- Usage:
--   psql -U postgres -d day_trade -f 005_trade_evaluations.sql
-- ============================================================================

\connect day_trade;

SET search_path TO trading, public;

-- ============================================================================
-- 1. trade_evaluations
--    One row per completed trade evaluation. Tracks entry vs exit comparison,
--    P&L, and AI critique of the orchestration agent's decision.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trade_evaluations (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticker                  VARCHAR(20) NOT NULL,
    profile                 VARCHAR(5),                  -- S / M / L
    trade_date              DATE DEFAULT CURRENT_DATE,

    -- Trade identification
    decision_type           VARCHAR(30) NOT NULL,        -- EXIT / REDUCE_EXPOSURE / REVERSE
    contract_symbol         VARCHAR(60),                 -- OCC option symbol

    -- Entry details (from position_journal / order_executions)
    entry_price             NUMERIC(12,4),               -- entry premium or fill price
    entry_time              TIMESTAMPTZ,
    entry_side              VARCHAR(10),                 -- CALL / PUT
    entry_qty               INTEGER,

    -- Exit details (from the close execution)
    exit_price              NUMERIC(12,4),               -- exit/close fill price
    exit_time               TIMESTAMPTZ,
    exit_reason             VARCHAR(30),                 -- EXIT_EXECUTED / REDUCE_TO_ZERO / REVERSE_EXECUTED / STOP_HIT / TARGET_HIT

    -- P&L Calculation
    price_change            NUMERIC(12,4),               -- exit_price - entry_price
    price_change_pct        NUMERIC(10,4),               -- (exit - entry) / entry * 100
    pnl_per_contract        NUMERIC(12,4),               -- (exit - entry) * multiplier (100 for options)
    pnl_total               NUMERIC(14,4),               -- pnl_per_contract * qty
    outcome                 VARCHAR(10) NOT NULL,        -- POSITIVE / NEGATIVE / BREAKEVEN
    hold_duration_minutes   INTEGER,                     -- how long the position was held

    -- Orchestration context at entry time
    entry_confidence        NUMERIC(8,4),                -- AI confidence when entry was made
    entry_trend_direction   VARCHAR(20),                 -- trend at entry time
    entry_option_decision   VARCHAR(20),                 -- BUY_CALL / BUY_PUT
    entry_risk_reward       NUMERIC(8,4),                -- planned R:R at entry

    -- AI Evaluation Agent critique
    evaluation_grade        VARCHAR(5),                  -- A / B / C / D / F
    evaluation_score        NUMERIC(5,2),                -- 0-100 score
    critique                TEXT NOT NULL,                -- AI-generated critique text
    what_went_well          TEXT,                        -- strengths of the decision
    what_went_wrong         TEXT,                        -- weaknesses / mistakes
    lessons_learned         TEXT,                        -- actionable improvements
    would_take_again        BOOLEAN,                     -- would AI take this trade again?

    -- Signal quality assessment
    signal_quality          VARCHAR(20),                 -- EXCELLENT / GOOD / FAIR / POOR
    timing_quality          VARCHAR(20),                 -- EXCELLENT / GOOD / FAIR / POOR
    risk_management_quality VARCHAR(20),                 -- EXCELLENT / GOOD / FAIR / POOR

    -- Raw data for reproducibility
    entry_snapshot          JSONB,                       -- signal snapshot at entry
    exit_snapshot           JSONB,                       -- execution data at exit
    raw_evaluation          JSONB,                       -- full AI evaluation output

    evaluated_at            TIMESTAMPTZ DEFAULT NOW(),
    created_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trade_eval_ticker_date
    ON trade_evaluations(ticker, trade_date, evaluated_at DESC);

CREATE INDEX IF NOT EXISTS idx_trade_eval_outcome
    ON trade_evaluations(outcome, trade_date);

CREATE INDEX IF NOT EXISTS idx_trade_eval_grade
    ON trade_evaluations(evaluation_grade, trade_date);

-- ============================================================================
-- 2. View: v_recent_evaluations
--    For quick review of recent trade evaluations.
-- ============================================================================
CREATE OR REPLACE VIEW v_recent_evaluations AS
SELECT
    te.id,
    te.ticker,
    te.profile,
    te.trade_date,
    te.decision_type,
    te.contract_symbol,
    te.entry_price,
    te.exit_price,
    te.price_change,
    te.price_change_pct,
    te.pnl_per_contract,
    te.pnl_total,
    te.outcome,
    te.evaluation_grade,
    te.evaluation_score,
    te.hold_duration_minutes,
    te.critique,
    te.would_take_again,
    te.evaluated_at
FROM trade_evaluations te
WHERE te.trade_date >= CURRENT_DATE - INTERVAL '7 days'
ORDER BY te.evaluated_at DESC
LIMIT 50;

-- ============================================================================
-- 3. View: v_evaluation_summary
--    Aggregated performance metrics for the orchestration agent.
-- ============================================================================
CREATE OR REPLACE VIEW v_evaluation_summary AS
SELECT
    trade_date,
    COUNT(*) AS total_trades,
    COUNT(*) FILTER (WHERE outcome = 'POSITIVE') AS winning_trades,
    COUNT(*) FILTER (WHERE outcome = 'NEGATIVE') AS losing_trades,
    COUNT(*) FILTER (WHERE outcome = 'BREAKEVEN') AS breakeven_trades,
    ROUND(100.0 * COUNT(*) FILTER (WHERE outcome = 'POSITIVE') / NULLIF(COUNT(*), 0), 1) AS win_rate_pct,
    ROUND(AVG(evaluation_score)::NUMERIC, 1) AS avg_eval_score,
    ROUND(SUM(pnl_total)::NUMERIC, 2) AS daily_pnl,
    ROUND(AVG(pnl_per_contract)::NUMERIC, 2) AS avg_pnl_per_contract,
    ROUND(AVG(hold_duration_minutes)::NUMERIC, 0) AS avg_hold_minutes,
    MODE() WITHIN GROUP (ORDER BY evaluation_grade) AS most_common_grade
FROM trade_evaluations
GROUP BY trade_date
ORDER BY trade_date DESC;
