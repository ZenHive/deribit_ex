#!/usr/bin/env bash

# This script updates module names and references 
# from MarketMaker.WS.* to DeribitEx.*

set -e

# Find all Elixir files
echo "Updating module names in Elixir files..."
find lib test -name "*.ex" -o -name "*.exs" | xargs sed -i '' -e 's/MarketMaker\.WS\./DeribitEx./g'

# Update module definitions
echo "Updating defmodule declarations..."
find lib test -name "*.ex" -o -name "*.exs" | xargs sed -i '' -e 's/defmodule MarketMaker\.WS\./defmodule DeribitEx./g'

# Update config references
echo "Updating config references..."
find lib test config -name "*.ex" -o -name "*.exs" | xargs sed -i '' -e 's/:market_maker/:deribit_ex/g'

# Update telemetry event paths
echo "Updating telemetry event paths..."
find lib test -name "*.ex" -o -name "*.exs" | xargs sed -i '' -e 's/\[:market_maker,/[:deribit_ex,/g'

echo "Module renaming complete."
