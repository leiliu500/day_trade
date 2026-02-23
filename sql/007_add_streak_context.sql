-- 007_add_streak_context.sql
-- Add streak_context column to trading_decisions table.
-- This stores the AI orchestrator's confirmation buildup tracking
-- (e.g., "2nd consecutive BUY_PUT, conviction building") so that
-- subsequent decisions can accurately count the confirmation streak
-- without relying solely on parsing signal_summary JSONB.

SET search_path TO trading, public;

ALTER TABLE trading_decisions
  ADD COLUMN IF NOT EXISTS streak_context TEXT;

COMMENT ON COLUMN trading_decisions.streak_context IS
  'AI orchestrator streak/buildup context string, e.g. "3rd consecutive BUY_PUT, confirmed entry"';
