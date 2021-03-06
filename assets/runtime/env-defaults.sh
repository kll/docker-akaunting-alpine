#!/usr/bin/env sh

## DEBUGGING
DEBUG=${DEBUG:-false}

## CORE
AKAUNTING_CONFIG_DIR=${AKAUNTING_CONFIG_DIR:-$AKAUNTING_DATA_DIR/config}
AKAUNTING_UPLOADS_DIR=${AKAUNTING_UPLOADS_DIR:-$AKAUNTING_DATA_DIR/uploads}
AKAUNTING_BACKUPS_DIR=${AKAUNTING_BACKUPS_DIR:-$AKAUNTING_DATA_DIR/backups}

AKAUNTING_COMPANY_NAME=${AKAUNTING_COMPANY_NAME:-Acme Inc.}
AKAUNTING_COMPANY_EMAIL=${AKAUNTING_COMPANY_EMAIL:-contact@example.com}

AKAUNTING_ADMIN_EMAIL=${AKAUNTING_ADMIN_EMAIL:-admin@example.com}
AKAUNTING_ADMIN_PASSWORD=${AKAUNTING_ADMIN_PASSWORD:-password}

AKAUNTING_URL=${AKAUNTING_URL:-http://localhost}

## BACKUPS
AKAUNTING_BACKUPS_EXPIRY=${AKAUNTING_BACKUPS_EXPIRY:-0}

## APP
APP_LOCALE=${APP_LOCALE:-en-GB}

## DATABASE
DB_TYPE=${DB_TYPE:-mysql}
DB_HOST=${DB_HOST:-}
DB_PORT=${DB_PORT:-}
DB_NAME=${DB_NAME:-}
DB_USER=${DB_USER:-}
DB_PASS=${DB_PASS:-}
