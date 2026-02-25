-- ============================================================================
-- Cleanup Script for day_trade Database
-- ============================================================================
-- Purges all data from the trading schema while preserving the schema
-- structure (tables, views, indexes, extensions).
--
-- Usage:
--   psql -U postgres -d day_trade -f 003_cleanup_database.sql
--
-- Foreign-key-safe order: child tables are truncated before parents.
-- RESTART IDENTITY resets all UUID/sequence generators.
-- ============================================================================

\connect day_trade;

SET search_path TO trading, public;

BEGIN;

-- -------------------------------------------------------
-- 1. Truncate all tables (cascade handles FK dependencies)
-- -------------------------------------------------------
-- TRUNCATE is faster than DELETE and resets table storage.
-- CASCADE will automatically truncate dependent tables,
-- but we list them explicitly for clarity.

TRUNCATE TABLE
    trading.portfolio_risk_state,
    trading.order_lifecycle,
    trading.order_groups,
    trading.broker_positions,
    trading.broker_open_orders,
    trading.trade_evaluations,
    trading.order_executions,
    trading.decision_confirmations,
    trading.position_journal,
    trading.trading_decisions,
    trading.signal_snapshots,
    trading.trading_sessions,
    trading.workflow_indicators,
    trading.workflow_decisions
RESTART IDENTITY CASCADE;

-- Reset portfolio risk limits to defaults
DELETE FROM trading.portfolio_risk_limits;
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
    ('max_correlated_positions',    3,       'Maximum positions in correlated tickers (e.g., SPY+QQQ+IWM)', TRUE);

COMMIT;

-- -------------------------------------------------------
-- 2. Verify cleanup
-- -------------------------------------------------------
DO $$
DECLARE
    tbl   TEXT;
    cnt   BIGINT;
    total BIGINT := 0;
BEGIN
    FOR tbl IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'trading'
        ORDER BY tablename
    LOOP
        EXECUTE format('SELECT count(*) FROM trading.%I', tbl) INTO cnt;
        total := total + cnt;
        RAISE NOTICE '  %-35s %s rows', tbl, cnt;
    END LOOP;

    IF total = 0 THEN
        RAISE NOTICE '✓ All trading tables are empty. Cleanup complete.';
    ELSE
        RAISE WARNING '✗ Some tables still contain data (% rows total).', total;
    END IF;
END
$$;
