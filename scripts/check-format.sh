#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun swift-format lint --strict --recursive --configuration .swift-format Package.swift Sources Tests
