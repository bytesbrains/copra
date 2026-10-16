#!/usr/bin/env bash
# Setup git hooks for Copra Protocol
set -e

echo "🥥 Configuring git hooks..."
git config core.hooksPath .githooks
chmod +x .githooks/*
echo "✅ Git hooks configured to .githooks (pre-commit & pre-push active)"
