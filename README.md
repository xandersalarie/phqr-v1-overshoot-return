# PHQR V1 — Original Overshoot & Return

Source file: `PHQR_V1_OriginalOvershoot.mq5`

## What changed from the previous V1

The previous V1 placed a blind SELL LIMIT at Q75 at the start of every eligible H1 setup window. That behavior has been removed.

The revised V1 preserves the existing closed-H1 quartile calculations, MagicNumber isolation, risk sizing, one-position-at-a-time protection, trade transaction handling, Q50 break-even management, chart visualization, dashboard, CSV logging, and restart recovery where those components remain compatible with the new entry logic.

The entry sequence is now:

1. Use the immediately previous fully closed H1 candle.
2. Freeze H, L, Q75, Q50, Q25 for the following H1 setup window.
3. Calculate `OvershootLevel = Q75 + OvershootPercent * R`.
4. Wait until Bid reaches or exceeds OvershootLevel while still below H.
5. Arm the setup permanently for that H1 window.
6. Wait for Bid to return downward through Q75: `PreviousBid > Q75 && CurrentBid <= Q75`.
7. Submit a market SELL as close as execution permits to Q75.
8. Keep exact `SL = H` and `TP = Q25`; levels are never shifted for spread or broker convenience.
9. When the open short reaches `Ask <= Q50`, move SL once to the actual entry price.

## State machine

Normal path:

`WAITING_FOR_NEW_H1 -> REFERENCE_READY -> WAITING_FOR_OVERSHOOT -> OVERSHOOT_ARMED -> WAITING_FOR_Q75_RETURN -> POSITION_OPEN -> SETUP_FINISHED`

Alternative terminal paths before entry:

- Bid reaches H first -> `SETUP_INVALIDATED`
- Setup H1 window ends -> `SETUP_EXPIRED`
- Existing PHQR V1 position -> new setup is logged as blocked
- Broker/position-size rejection at the Q75 return -> `SETUP_FINISHED` with rejection reason

`OVERSHOOT_ARMED` is represented as the moment the setup becomes armed; once armed, the operating state becomes `WAITING_FOR_Q75_RETURN` until entry, invalidation, or expiry.

## OvershootPercent

Default input:

`OvershootPercent = 0.05`

For a previous H1 range `R = H - L`, the overshoot level is:

`OvershootLevel = Q75 + 0.05 * R`

Example: H=2900, L=2880, R=20, Q75=2895 -> OvershootLevel=2896.

The parameter is fixed/configurable only. The EA does not optimize or adapt it.

If a user-selected OvershootPercent puts OvershootLevel outside the geometrically valid interval between Q75 and H, that reference setup is rejected rather than changing the level.

## Bid/Ask assumptions

- Previous-H1 candle levels, overshoot detection, pre-entry High invalidation, and the Q75 downward return are evaluated with Bid. This keeps the signal sequence on the same price side as the MT5 bar series and prevents spread from becoming an extra signal filter.
- A market SELL executes on Bid.
- Break-even uses Ask <= Q50 because Ask is the executable close-side price for a short.
- The exact SL at H must still be technically valid relative to current Ask when the sell is submitted. If broker stop restrictions prevent the exact H/Q25 geometry, the trade is rejected instead of moving either level.

## Position sizing

This overshoot specification uses risk-based sizing, not the earlier fixed-lot modification.

Default:

`RiskPercent = 0.50`

Volume is calculated from current account equity and the intended Q75-to-H risk distance using:

- `SYMBOL_TRADE_TICK_SIZE`
- `SYMBOL_TRADE_TICK_VALUE`
- `SYMBOL_VOLUME_MIN`
- `SYMBOL_VOLUME_MAX`
- `SYMBOL_VOLUME_STEP`

Volume is rounded down to the broker step so the configured risk is not exceeded because of upward lot rounding.

Maximum PHQR V1 open positions per symbol is hard-coded to 1.

## Break-even

The original manual phrase “way past the sell” is mechanicalized as Q50.

When an open short reaches `Ask <= Q50`, the EA attempts exactly one stop modification:

`New SL = ActualEntryPrice`

There is no +1R trigger, M5-close trigger, ATR trigger, or trailing stop after break-even.

## Restart recovery

The EA first recovers any live position belonging to `_Symbol` and `MagicNumber`.

When there is no live position and MT5/EA starts during an already-forming H1 setup candle, it requests historical ticks from the start of that H1 candle through the current time and replays the sequence chronologically:

- previous High reached first -> invalidated
- overshoot reached but no return yet -> recover armed state and continue waiting
- Q75 return already happened while the EA was offline -> do not retroactively enter; log `ENTRY_MISSED_DURING_RESTART`
- tick history unavailable -> fail safe and log `STATE_RECOVERY_UNCERTAIN`

Any legacy PHQR pending sell order using the same symbol/MagicNumber is removed on initialization because this version no longer uses a blind Q75 pending entry.

## Strategy Tester configuration

Recommended:

- Model: **Every tick based on real ticks** when available
- Symbol: the broker's actual symbol (`XAUUSD`, `XAUUSDm`, `GOLD`, etc.)
- Chart/test timeframe: H1 or M5 are both acceptable; reference calculations explicitly use `PERIOD_H1`
- Date range: large enough for a statistically meaningful sample and adequate tick history
- Spread: use the tester/broker's historical execution conditions; do not manually compensate the strategy levels
- Optimization: **disabled**
- Forward optimization: not required for the control test
- Visual mode: optional, useful for checking sequence fidelity

The code does not claim profitability and no parameter should be optimized as part of the original-control test.

## CSV fields

The CSV is written to the MT5 Common Files area when `EnableCSVLogging=true` and includes one finalized record per reference setup/trade where the terminal observed or reconstructed the terminal event.

Fields:

- `reference_timestamp`, `symbol`, `reference_open`, `reference_high`, `reference_low`, `reference_close`, `range`
- `Q75`, `Q50`, `Q25`
- `overshoot_percent`, `overshoot_level`, `overshoot_detected`, `overshoot_time`
- `previous_high_reached_before_entry`
- `Q75_return_detected`, `Q75_return_time`
- `entry_attempted`, `entry_filled`
- `target_entry`, `actual_entry`, `entry_slippage`
- `spread_at_entry`
- `SL`, `TP`
- `lot_size`, `risk_percent`, `initial_risk_currency`, `theoretical_RR`
- `Q50_reached`, `break_even_activated`, `break_even_time`
- `maximum_favorable_excursion_price`, `maximum_favorable_excursion_R`
- `maximum_adverse_excursion_price`, `maximum_adverse_excursion_R`
- `exit_time`, `exit_price`, `exit_reason`
- `profit_currency`, `result_R`
- `signal_expired`, `existing_position_blocked`, `broker_rejection_reason`

`entry_slippage = ActualEntry - Q75`. A negative value means the short filled below the intended Q75 entry.

`result_R` is realized net P/L divided by the initial risk currency calculated from the intended Q75-to-H geometry and actual normalized volume.

## Compilation

1. Copy `PHQR_V1_OriginalOvershoot.mq5` into `MQL5/Experts/`.
2. Open it in current MetaEditor.
3. Press F7 / Compile.
4. Resolve any broker/build-specific compiler message before live or tester use.

A MetaEditor executable is not installed in the build environment used to prepare this file, so an actual MetaEditor compile could not be run here. The source was statically checked for balanced delimiters, complete helper definitions, matching CSV column counts, removal of blind `SellLimit` entry calls, and use of documented current MQL5 APIs.

## Purpose

This remains a V1 control strategy for testing the original overshoot-and-return quartile concept itself. It does not add V2 rejection candles, ATR/expansion filters, MinRR filters, stop buffers, trend/session/news filters, or M5 close-based confirmation. No claim is made that this strategy is profitable or superior/inferior to PHQR V2.

## v1.11 compile-fix patch
- Added `datetime fill_time` to `SetupLogRecord` because fill/recovery/exit accounting already referenced that field.
- Added `fill_time` to `CopySetupLogRecord()` so it survives state promotion/copying.
- Explicitly zero-initialized the local `ReferenceData ref` used by restart position recovery to remove the MetaEditor uninitialized-variable warning.
- No strategy rules were changed by this patch.
