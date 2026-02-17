-- ============================================================================
-- Day Trade AI Agent Orchestration Schema
-- ============================================================================
-- This schema tracks all trading data in Postgres so that AI agents can
-- orchestrate decisions like a human trader — reviewing signal history,
-- confirming or adjusting existing decisions, and journaling every action.
--
-- No broker position/order APIs are called. All state lives here.
-- ============================================================================

-- Connect to the day_trade database (created by 000_create_day_trade_db.sh)
\connect day_trade;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================================
-- 1. trading_sessions
--    One row per trading day per ticker. Groups all signals & decisions.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading_sessions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticker          VARCHAR(20) NOT NULL,
    trading_date    DATE NOT NULL DEFAULT CURRENT_DATE,
    profile         VARCHAR(5),                          -- S / M / L
    mode            VARCHAR(10) DEFAULT 'AUTO',          -- AUTO / MANUAL
    status          VARCHAR(20) DEFAULT 'ACTIVE',        -- ACTIVE / CLOSED / EXPIRED
    opened_at       TIMESTAMPTZ DEFAULT NOW(),
    closed_at       TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(ticker, trading_date, profile)
);

CREATE INDEX IF NOT EXISTS idx_sessions_ticker_date
    ON trading_sessions(ticker, trading_date);

-- ============================================================================
-- 2. signal_snapshots
--    Every indicator run produces a snapshot. This is the "tape" of all signals
--    the AI sees over the day — like a human's chart observation journal.
-- ============================================================================
CREATE TABLE IF NOT EXISTS signal_snapshots (
    id                      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id              UUID REFERENCES trading_sessions(id),
    ticker                  VARCHAR(20) NOT NULL,
    snapshot_time           TIMESTAMPTZ DEFAULT NOW(),

    -- Multi-TF trend summary
    trend_direction         VARCHAR(20),     -- uptrend / downtrend / mixed
    trend_strength          VARCHAR(20),     -- weak / moderate / strong
    trend_strength_score    NUMERIC(6,2),
    alignment               VARCHAR(30),     -- all_aligned / htf_mtf_aligned / mixed
    confidence              NUMERIC(5,4),    -- 0.0000 .. 1.0000
    confidence_pct          NUMERIC(6,2),    -- 0.00 .. 100.00
    technical_bias          VARCHAR(20),     -- bullish / bearish / null

    -- ADX confirmation
    adx_confirmation        VARCHAR(20),     -- confirmed / not_confirmed

    -- Underlying price levels
    trigger_price           NUMERIC(12,4),
    invalidation_level      NUMERIC(12,4),
    target_level            NUMERIC(12,4),
    underlying_rr           NUMERIC(8,4),

    -- Option signal details
    option_decision         VARCHAR(20),     -- BUY_CALL / BUY_PUT / WAIT
    desired_option_right    VARCHAR(10),     -- call / put
    option_contract_symbol  VARCHAR(40),
    option_bid              NUMERIC(10,4),
    option_ask              NUMERIC(10,4),
    option_mid              NUMERIC(10,4),
    option_spread_pct       NUMERIC(8,6),
    option_entry_premium    NUMERIC(10,4),
    option_stop_premium     NUMERIC(10,4),
    option_tp_premium       NUMERIC(10,4),
    option_risk_reward      NUMERIC(8,4),
    option_delta            NUMERIC(8,6),

    -- Gates
    time_gate_ok            BOOLEAN,
    option_liquidity_ok     BOOLEAN,
    candidate_pass          BOOLEAN,

    -- DMI per-TF details (JSONB for flexibility)
    dmi_data                JSONB,           -- { "2m": { diPlus, diMinus, adx }, ... }

    -- TD Sequential / Demark per-TF
    demark_data             JSONB,

    -- Candlestick patterns per-TF
    candle_patterns         JSONB,           -- { "2m": { hammer, shooting_star, ... }, ... }

    -- Full AI analyst output text
    ai_explanation          TEXT,
    key_factors             JSONB,           -- string array

    -- Raw payload (for full reproducibility)
    raw_payload             JSONB,

    created_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_snapshots_session
    ON signal_snapshots(session_id);
CREATE INDEX IF NOT EXISTS idx_snapshots_ticker_time
    ON signal_snapshots(ticker, snapshot_time DESC);

-- ============================================================================
-- 3. trading_decisions
--    AI Agent orchestration decisions — like a human trader's decision log.
--    Each row is a deliberate trading decision: NEW_ENTRY, CONFIRM_HOLD,
--    ADD_POSITION, REDUCE_EXPOSURE, REVERSE, EXIT, or WAIT.
-- ============================================================================
CREATE TABLE IF NOT EXISTS trading_decisions (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id          UUID REFERENCES trading_sessions(id),
    snapshot_id         UUID REFERENCES signal_snapshots(id),
    ticker              VARCHAR(20) NOT NULL,
    decision_time       TIMESTAMPTZ DEFAULT NOW(),

    -- The orchestration decision (like a human trader would make)
    decision_type       VARCHAR(30) NOT NULL,
    -- Possible values:
    --   NEW_ENTRY        : First signal, open a tracked position
    --   CONFIRM_HOLD     : Signal confirms existing direction, hold position
    --   ADD_POSITION     : Signal strengthened, add to position
    --   REDUCE_EXPOSURE  : Signal weakening, scale down
    --   REVERSE          : Signal flipped direction, close & open opposite
    --   EXIT             : Signal says exit (invalidation hit, TD exhaustion, etc.)
    --   WAIT             : No actionable signal, stay flat

    -- Direction of this decision
    direction           VARCHAR(10),         -- LONG_CALL / LONG_PUT / FLAT
    option_right        VARCHAR(10),         -- call / put / null

    -- The reasoning (AI-generated, human-readable)
    reasoning           TEXT NOT NULL,

    -- Confidence in this specific orchestration decision
    orchestration_confidence NUMERIC(5,4),   -- 0..1

    -- What changed vs last decision?
    prior_decision_id   UUID REFERENCES trading_decisions(id),
    signal_change       TEXT,                -- e.g. "trend flipped bearish->bullish"
    confirmation_count  INTEGER DEFAULT 0,   -- how many consecutive confirms

    -- Tracked position state (no broker API — purely journal-based)
    tracked_side        VARCHAR(10),         -- CALL / PUT / null
    tracked_contract    VARCHAR(40),         -- OCC symbol being tracked
    tracked_entry_price NUMERIC(10,4),       -- intended entry price
    tracked_qty         INTEGER DEFAULT 0,   -- intended quantity
    tracked_stop        NUMERIC(10,4),
    tracked_target      NUMERIC(10,4),
    tracked_status      VARCHAR(20) DEFAULT 'PLANNED',
    -- PLANNED / ACTIVE / STOPPED_OUT / TARGET_HIT / EXPIRED / CLOSED

    -- Key metrics at decision time
    current_confidence  NUMERIC(5,4),
    current_trend       VARCHAR(20),
    current_rr          NUMERIC(8,4),

    -- AI agent metadata
    agent_model         VARCHAR(50) DEFAULT 'gpt-4.1-mini',
    agent_version       VARCHAR(20) DEFAULT 'v1',

    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_decisions_session
    ON trading_decisions(session_id);
CREATE INDEX IF NOT EXISTS idx_decisions_ticker_time
    ON trading_decisions(ticker, decision_time DESC);

-- ============================================================================
-- 4. decision_confirmations
--    Tracks how many consecutive signals confirm or contradict a decision.
--    Like a human checking "is my thesis still valid?" every 5 minutes.
-- ============================================================================
CREATE TABLE IF NOT EXISTS decision_confirmations (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    decision_id         UUID REFERENCES trading_decisions(id) NOT NULL,
    snapshot_id         UUID REFERENCES signal_snapshots(id) NOT NULL,
    ticker              VARCHAR(20) NOT NULL,
    confirmed_at        TIMESTAMPTZ DEFAULT NOW(),

    -- Does this snapshot confirm or contradict the active decision?
    confirms            BOOLEAN NOT NULL,     -- true = confirms, false = contradicts
    confirmation_type   VARCHAR(30),
    -- STRONG_CONFIRM   : all TFs agree with decision
    -- WEAK_CONFIRM     : majority TFs agree
    -- NEUTRAL          : mixed signals
    -- WEAK_CONTRADICT  : majority TFs disagree
    -- STRONG_CONTRADICT: all TFs flip against decision

    -- What specifically changed?
    detail              TEXT,

    -- Running tally
    consecutive_confirms    INTEGER DEFAULT 0,
    consecutive_contradicts INTEGER DEFAULT 0,

    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_confirmations_decision
    ON decision_confirmations(decision_id, confirmed_at DESC);

-- ============================================================================
-- 5. position_journal
--    Virtual position tracking — no broker APIs involved.
--    Like a paper trading journal that tracks theoretical P&L.
-- ============================================================================
CREATE TABLE IF NOT EXISTS position_journal (
    id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id          UUID REFERENCES trading_sessions(id),
    decision_id         UUID REFERENCES trading_decisions(id),
    ticker              VARCHAR(20) NOT NULL,

    -- Position details (theoretical)
    side                VARCHAR(10) NOT NULL,  -- CALL / PUT
    contract_symbol     VARCHAR(40),
    entry_price         NUMERIC(10,4),
    entry_time          TIMESTAMPTZ DEFAULT NOW(),

    stop_price          NUMERIC(10,4),
    target_price        NUMERIC(10,4),
    qty                 INTEGER DEFAULT 1,

    -- Exit tracking
    exit_price          NUMERIC(10,4),
    exit_time           TIMESTAMPTZ,
    exit_reason         VARCHAR(30),
    -- STOP_HIT / TARGET_HIT / MANUAL_EXIT / REVERSAL / SESSION_CLOSE / EXPIRED

    -- Theoretical P&L
    pnl_per_contract    NUMERIC(10,4),
    pnl_total           NUMERIC(12,4),

    -- Status
    status              VARCHAR(20) DEFAULT 'OPEN',
    -- OPEN / CLOSED / EXPIRED

    notes               TEXT,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_journal_session
    ON position_journal(session_id);
CREATE INDEX IF NOT EXISTS idx_journal_ticker_status
    ON position_journal(ticker, status);

-- ============================================================================
-- 6. Helpful views
-- ============================================================================

-- Active positions (virtual) for quick orchestration queries
CREATE OR REPLACE VIEW v_active_positions AS
SELECT
    pj.*,
    td.decision_type,
    td.direction,
    td.reasoning AS decision_reasoning,
    ts.trading_date,
    ts.profile
FROM position_journal pj
JOIN trading_decisions td ON td.id = pj.decision_id
JOIN trading_sessions ts ON ts.id = pj.session_id
WHERE pj.status = 'OPEN'
  AND ts.status = 'ACTIVE';

-- Latest decision per ticker (for orchestration context)
CREATE OR REPLACE VIEW v_latest_decisions AS
SELECT DISTINCT ON (ticker)
    td.*,
    ts.trading_date,
    ts.profile,
    ts.status AS session_status
FROM trading_decisions td
JOIN trading_sessions ts ON ts.id = td.session_id
WHERE ts.trading_date = CURRENT_DATE
ORDER BY ticker, td.decision_time DESC;

-- Signal trend for ticker today (last N snapshots)
CREATE OR REPLACE VIEW v_today_signals AS
SELECT
    ss.*,
    ts.trading_date,
    ts.profile
FROM signal_snapshots ss
JOIN trading_sessions ts ON ts.id = ss.session_id
WHERE ts.trading_date = CURRENT_DATE
ORDER BY ss.ticker, ss.snapshot_time DESC;

-- Confirmation streak per active decision
CREATE OR REPLACE VIEW v_confirmation_streaks AS
SELECT
    dc.decision_id,
    td.ticker,
    td.decision_type,
    td.direction,
    COUNT(*) FILTER (WHERE dc.confirms = true) AS total_confirms,
    COUNT(*) FILTER (WHERE dc.confirms = false) AS total_contradicts,
    MAX(dc.consecutive_confirms) AS max_consecutive_confirms,
    MAX(dc.consecutive_contradicts) AS max_consecutive_contradicts,
    MAX(dc.confirmed_at) AS last_check_at
FROM decision_confirmations dc
JOIN trading_decisions td ON td.id = dc.decision_id
GROUP BY dc.decision_id, td.ticker, td.decision_type, td.direction;

-- ============================================================================
-- 7. workflow_indicators
--    Replaces the n8n DataTable "day_trade_indicators".
--    Stores the Telegram output text and confidence from each workflow run.
-- ============================================================================
CREATE TABLE IF NOT EXISTS workflow_indicators (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticker          VARCHAR(20),
    text            TEXT,
    confidence      NUMERIC(6,2),
    raw_payload     JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_workflow_indicators_ticker
    ON workflow_indicators(ticker, created_at DESC);

-- ============================================================================
-- 8. workflow_decisions
--    Replaces the n8n DataTable "day_trade_decisions".
--    Stores order decisions and action types from each trade execution.
-- ============================================================================
CREATE TABLE IF NOT EXISTS workflow_decisions (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticker          VARCHAR(20),
    action_type     VARCHAR(30),
    decision        TEXT,
    raw_payload     JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_workflow_decisions_ticker
    ON workflow_decisions(ticker, created_at DESC);
