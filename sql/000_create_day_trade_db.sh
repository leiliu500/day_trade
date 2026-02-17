#!/bin/bash
# Creates the day_trade database if it doesn't already exist.
# This script runs as part of postgres docker-entrypoint-initdb.d
# and executes BEFORE 001_trading_orchestration.sql (alphabetical order).

set -e

TRADING_DB="${TRADING_DB:-day_trade}"

echo "Creating database '$TRADING_DB' if it does not exist..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE ${TRADING_DB}'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${TRADING_DB}')\gexec
    GRANT ALL PRIVILEGES ON DATABASE ${TRADING_DB} TO ${POSTGRES_USER};
EOSQL

echo "Database '$TRADING_DB' is ready."
