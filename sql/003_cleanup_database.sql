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
