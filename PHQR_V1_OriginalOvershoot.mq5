#property copyright "PHQR V1"
#property version   "1.11"
#property strict
#property description "PHQR V1 - Original Overshoot & Return"
#property description "Short-only previous-H1 quartile strategy with overshoot then Q75 return entry."

#include <Trade/Trade.mqh>

// ============================================================================
// PHQR V1 — Original Overshoot & Return
// ----------------------------------------------------------------------------
// Previous completed H1 candle:
//   H   = previous H1 High
//   L   = previous H1 Low
//   R   = H - L
//   Q75 = L + 0.75 * R
//   Q50 = L + 0.50 * R
//   Q25 = L + 0.25 * R
//
// Signal sequence (short only):
//   1) During the next H1 candle, Bid must first reach:
//        OvershootLevel = Q75 + OvershootPercent * R
//      while Bid remains below H.
//   2) Once armed, Bid must return-cross Q75 from above:
//        PreviousBid > Q75 && CurrentBid <= Q75
//   3) Submit a market SELL with exact SL = H and exact TP = Q25.
//   4) When Ask <= Q50, move SL once to the actual entry price.
//
// No V2 filters, no indicators, no session/news filters, no long logic.
// ============================================================================

input double RiskPercent      = 0.50;
input double OvershootPercent = 0.05;
input ulong  MagicNumber      = 51017502;
input bool   EnableCSVLogging = true;

const int MAX_OPEN_TRADES = 1;

enum PHQR_SETUP_STATE
  {
   WAITING_FOR_NEW_H1     = 0,
   REFERENCE_READY        = 1,
   WAITING_FOR_OVERSHOOT  = 2,
   OVERSHOOT_ARMED        = 3,
   WAITING_FOR_Q75_RETURN = 4,
   POSITION_OPEN          = 5,
   SETUP_INVALIDATED      = 6,
   SETUP_EXPIRED          = 7,
   SETUP_FINISHED         = 8
  };

struct ReferenceData
  {
   bool     valid;
   datetime time;
   double   open;
   double   high;
   double   low;
   double   close;
   double   range;
   double   q75;
   double   q50;
   double   q25;
  };

struct SetupLogRecord
  {
   bool          valid;
   ReferenceData ref;

   double        overshoot_percent;
   double        overshoot_level;
   bool          overshoot_detected;
   datetime      overshoot_time;
   bool          previous_high_reached_before_entry;
   bool          q75_return_detected;
   datetime      q75_return_time;

   bool          entry_attempted;
   bool          entry_filled;
   datetime      fill_time;
   double        target_entry;
   double        actual_entry;
   double        entry_slippage;
   double        spread_at_entry;
   double        sl;
   double        tp;
   double        lot_size;
   double        risk_percent;
   double        initial_risk_currency;
   double        theoretical_rr;

   bool          q50_reached;
   bool          break_even_activated;
   datetime      break_even_time;

   double        mfe_price;
   double        mfe_r;
   double        mae_price;
   double        mae_r;

   datetime      exit_time;
   double        exit_price;
   string        exit_reason;
   double        profit_currency;
   double        result_r;

   bool          signal_expired;
   bool          existing_position_blocked;
   string        broker_rejection_reason;
  };

struct SetupContext
  {
   bool           active;
   datetime       setup_open;
   datetime       expiry;
   bool           previous_bid_valid;
   double         previous_bid;
   SetupLogRecord rec;
  };

struct TradeContext
  {
   bool           active;
   ulong          position_ticket;
   ulong          position_identifier;
   bool           break_even_attempted;
   SetupLogRecord rec;
  };

CTrade           g_trade_api;
PHQR_SETUP_STATE g_state = WAITING_FOR_NEW_H1;
ReferenceData    g_reference;
SetupContext     g_setup;
TradeContext     g_position;

datetime         g_last_h1_open = 0;
string           g_last_action = "Initialising";
string           g_last_error  = "";
string           g_csv_filename = "";
string           g_object_prefix = "";

// ============================================================================
// Forward declarations
// ============================================================================
bool   DetectNewH1();
void   ProcessNewH1();
bool   CalculateReferenceLevels(ReferenceData &ref);
bool   LoadReferenceByTime(const datetime ref_time, ReferenceData &ref);
bool   BeginSetup(const bool reconstruct_history);
bool   ReconstructCurrentSetupState();
void   ManageSetup();
void   ExpireCurrentSetup(const string reason_text);
void   InvalidateCurrentSetup(const string reason_text);
void   SubmitReturnSell(const MqlTick &tick);
double CalculatePositionSize(const ReferenceData &ref, double &initial_risk_currency, string &error_text);
void   RecoverSubmittedEntryIfNeeded();
int    CountOwnOpenPositions();
void   ManageOpenPosition();
void   CheckBreakEven();
void   RecoverExistingState();
void   RemoveLegacyPendingOrders();
void   DrawLevels();
void   DrawPositionLevels();
void   RemoveChartObjects();
void   UpdateDashboard();
void   WriteSetupLog(SetupLogRecord &rec);
void   WriteTradeLog(SetupLogRecord &rec);
void   WriteCSVRecord(SetupLogRecord &rec);

// ============================================================================
// Utility helpers
// ============================================================================
string BoolText(const bool value)
  {
   return(value ? "true" : "false");
  }

string YesNo(const bool value)
  {
   return(value ? "yes" : "no");
  }

string TimeText(const datetime value)
  {
   if(value <= 0)
      return("");
   return(TimeToString(value, TIME_DATE | TIME_SECONDS));
  }

string PriceText(const double value)
  {
   if(value == 0.0)
      return("0");
   return(DoubleToString(value, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
  }

string VolumeText(const double value)
  {
   return(DoubleToString(value, 8));
  }

string MoneyText(const double value)
  {
   return(DoubleToString(value, 2));
  }

string NumberText(const double value, const int digits = 6)
  {
   return(DoubleToString(value, digits));
  }

string TicketText(const ulong ticket)
  {
   return(StringFormat("%I64u", ticket));
  }

string StateText(const PHQR_SETUP_STATE state)
  {
   switch(state)
     {
      case WAITING_FOR_NEW_H1:     return("WAITING_FOR_NEW_H1");
      case REFERENCE_READY:        return("REFERENCE_READY");
      case WAITING_FOR_OVERSHOOT:  return("WAITING_FOR_OVERSHOOT");
      case OVERSHOOT_ARMED:        return("OVERSHOOT_ARMED");
      case WAITING_FOR_Q75_RETURN: return("WAITING_FOR_Q75_RETURN");
      case POSITION_OPEN:          return("POSITION_OPEN");
      case SETUP_INVALIDATED:      return("SETUP_INVALIDATED");
      case SETUP_EXPIRED:          return("SETUP_EXPIRED");
      case SETUP_FINISHED:         return("SETUP_FINISHED");
     }
   return("UNKNOWN");
  }

bool IsTradeRetcodeSuccess(const uint retcode, const bool allow_no_changes = false)
  {
   if(retcode == TRADE_RETCODE_DONE ||
      retcode == TRADE_RETCODE_PLACED ||
      retcode == TRADE_RETCODE_DONE_PARTIAL)
      return(true);

   if(allow_no_changes && retcode == TRADE_RETCODE_NO_CHANGES)
      return(true);

   return(false);
  }

string TradeResultDetails()
  {
   return(StringFormat("retcode=%u (%s), broker_comment=%s, last_error=%d",
                       g_trade_api.ResultRetcode(),
                       g_trade_api.ResultRetcodeDescription(),
                       g_trade_api.ResultComment(),
                       GetLastError()));
  }

void SetLastErrorText(const string text)
  {
   g_last_error = text;
   Print("PHQR V1 ERROR: ", text);
  }

void SetLastAction(const string text)
  {
   g_last_action = text;
   Print("PHQR V1: ", text);
  }

string SafeFilenameSymbol()
  {
   string s = _Symbol;
   StringReplace(s, "\\", "_");
   StringReplace(s, "/", "_");
   StringReplace(s, ":", "_");
   StringReplace(s, "*", "_");
   StringReplace(s, "?", "_");
   StringReplace(s, "\"", "_");
   StringReplace(s, "<", "_");
   StringReplace(s, ">", "_");
   StringReplace(s, "|", "_");
   return(s);
  }

string AttemptGlobalVariableName()
  {
   string name = StringFormat("PHQRV1O_ATT_%I64u_%s", MagicNumber, SafeFilenameSymbol());
   if(StringLen(name) > 63)
      name = StringSubstr(name, 0, 63);
   return(name);
  }

string FinalizedGlobalVariableName()
  {
   string name = StringFormat("PHQRV1O_FIN_%I64u_%s", MagicNumber, SafeFilenameSymbol());
   if(StringLen(name) > 63)
      name = StringSubstr(name, 0, 63);
   return(name);
  }

datetime LastAttemptedReference()
  {
   string name = AttemptGlobalVariableName();
   if(!GlobalVariableCheck(name))
      return(0);
   return((datetime)(long)GlobalVariableGet(name));
  }

void MarkReferenceAttempted(const datetime ref_time)
  {
   datetime previous = LastAttemptedReference();
   if(ref_time > previous)
      GlobalVariableSet(AttemptGlobalVariableName(), (double)ref_time);
  }

datetime LastFinalizedReference()
  {
   string name = FinalizedGlobalVariableName();
   if(!GlobalVariableCheck(name))
      return(0);
   return((datetime)(long)GlobalVariableGet(name));
  }

void MarkReferenceFinalized(const datetime ref_time)
  {
   datetime previous = LastFinalizedReference();
   if(ref_time > previous)
      GlobalVariableSet(FinalizedGlobalVariableName(), (double)ref_time);
  }

void CopyReferenceData(const ReferenceData &src, ReferenceData &dst)
  {
   dst.valid = src.valid;
   dst.time  = src.time;
   dst.open  = src.open;
   dst.high  = src.high;
   dst.low   = src.low;
   dst.close = src.close;
   dst.range = src.range;
   dst.q75   = src.q75;
   dst.q50   = src.q50;
   dst.q25   = src.q25;
  }

void CopySetupLogRecord(const SetupLogRecord &src, SetupLogRecord &dst)
  {
   dst.valid = src.valid;
   CopyReferenceData(src.ref, dst.ref);
   dst.overshoot_percent = src.overshoot_percent;
   dst.overshoot_level = src.overshoot_level;
   dst.overshoot_detected = src.overshoot_detected;
   dst.overshoot_time = src.overshoot_time;
   dst.previous_high_reached_before_entry = src.previous_high_reached_before_entry;
   dst.q75_return_detected = src.q75_return_detected;
   dst.q75_return_time = src.q75_return_time;
   dst.entry_attempted = src.entry_attempted;
   dst.entry_filled = src.entry_filled;
   dst.fill_time = src.fill_time;
   dst.target_entry = src.target_entry;
   dst.actual_entry = src.actual_entry;
   dst.entry_slippage = src.entry_slippage;
   dst.spread_at_entry = src.spread_at_entry;
   dst.sl = src.sl;
   dst.tp = src.tp;
   dst.lot_size = src.lot_size;
   dst.risk_percent = src.risk_percent;
   dst.initial_risk_currency = src.initial_risk_currency;
   dst.theoretical_rr = src.theoretical_rr;
   dst.q50_reached = src.q50_reached;
   dst.break_even_activated = src.break_even_activated;
   dst.break_even_time = src.break_even_time;
   dst.mfe_price = src.mfe_price;
   dst.mfe_r = src.mfe_r;
   dst.mae_price = src.mae_price;
   dst.mae_r = src.mae_r;
   dst.exit_time = src.exit_time;
   dst.exit_price = src.exit_price;
   dst.exit_reason = src.exit_reason;
   dst.profit_currency = src.profit_currency;
   dst.result_r = src.result_r;
   dst.signal_expired = src.signal_expired;
   dst.existing_position_blocked = src.existing_position_blocked;
   dst.broker_rejection_reason = src.broker_rejection_reason;
  }

void InitialiseLogRecord(const ReferenceData &ref, SetupLogRecord &rec)
  {
   ZeroMemory(rec);
   rec.valid                   = true;
   CopyReferenceData(ref, rec.ref);
   rec.overshoot_percent       = OvershootPercent;
   rec.overshoot_level         = ref.q75 + OvershootPercent * ref.range;
   rec.target_entry            = ref.q75;
   rec.sl                      = ref.high;
   rec.tp                      = ref.q25;
   rec.risk_percent            = RiskPercent;
   rec.theoretical_rr          = 2.0;
   rec.exit_reason             = "";
   rec.broker_rejection_reason = "";
  }

bool IsNettingAccount()
  {
   ENUM_ACCOUNT_MARGIN_MODE mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   return(mode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING || mode == ACCOUNT_MARGIN_MODE_EXCHANGE);
  }

int CountOwnOpenPositions()
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; ++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;
      ++count;
     }
   return(count);
  }

ulong FindOwnPositionTicket(ulong &identifier)
  {
   identifier = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; ++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
         identifier = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         return(ticket);
        }
     }
   return(0);
  }

ulong FindOwnPositionTicketByIdentifier(const ulong identifier)
  {
   int total = PositionsTotal();
   for(int i = 0; i < total; ++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;
      if((ulong)PositionGetInteger(POSITION_IDENTIFIER) == identifier)
         return(ticket);
     }
   return(0);
  }

bool HasForeignPositionOnSymbol()
  {
   int total = PositionsTotal();
   for(int i = 0; i < total; ++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         return(true);
     }
   return(false);
  }

bool ParseReferenceTimeFromComment(const string comment, datetime &ref_time)
  {
   ref_time = 0;
   const string prefix = "PHQRV1O|";
   if(StringFind(comment, prefix) != 0)
      return(false);

   string number = StringSubstr(comment, StringLen(prefix));
   long value = StringToInteger(number);
   if(value <= 0)
      return(false);

   ref_time = (datetime)value;
   return(true);
  }

bool InferReferenceFromEventTime(const datetime event_time, ReferenceData &ref)
  {
   int setup_shift = iBarShift(_Symbol, PERIOD_H1, event_time, false);
   if(setup_shift < 0)
      return(false);

   int ref_shift = setup_shift + 1;
   datetime ref_time = iTime(_Symbol, PERIOD_H1, ref_shift);
   if(ref_time <= 0)
      return(false);

   return(LoadReferenceByTime(ref_time, ref));
  }

bool ValidateReferenceGeometry(const ReferenceData &ref, const double overshoot_level, string &reason)
  {
   reason = "";
   if(!ref.valid)
     {
      reason = "INVALID_REFERENCE_DATA";
      return(false);
     }
   if(ref.range <= 0.0)
     {
      reason = "ZERO_OR_NEGATIVE_REFERENCE_RANGE";
      return(false);
     }
   if(!(ref.high > ref.q75 && ref.q75 > ref.q50 && ref.q50 > ref.q25 && ref.q25 > ref.low))
     {
      reason = "INVALID_QUARTILE_GEOMETRY";
      return(false);
     }
   if(!(overshoot_level > ref.q75 && overshoot_level < ref.high))
     {
      reason = "OVERSHOOT_LEVEL_NOT_BETWEEN_Q75_AND_HIGH";
      return(false);
     }
   return(true);
  }

bool ValidateBrokerMarketEntry(const ReferenceData &ref, const MqlTick &tick, string &reason)
  {
   reason = "";

   if(tick.bid <= 0.0 || tick.ask <= 0.0)
     {
      reason = "NO_CURRENT_EXECUTABLE_PRICE";
      return(false);
     }

   if(tick.bid >= ref.high)
     {
      reason = "PREVIOUS_HIGH_REACHED_BEFORE_ENTRY";
      return(false);
     }

   // The exact short SL at H must still be above current Ask at submission.
   if(ref.high <= tick.ask)
     {
      reason = "BROKER_STOP_RESTRICTION";
      return(false);
     }

   if(ref.q25 >= tick.bid)
     {
      reason = "BROKER_STOP_RESTRICTION";
      return(false);
     }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stops_level_points = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minimum_distance = (double)stops_level_points * point;

   if(minimum_distance > 0.0)
     {
      const double eps = point * 0.01;
      if((ref.high - tick.ask) + eps < minimum_distance ||
         (tick.bid - ref.q25) + eps < minimum_distance)
        {
         reason = "BROKER_STOP_RESTRICTION";
         return(false);
        }
     }

   return(true);
  }

// ============================================================================
// Reference-candle logic
// ============================================================================
bool DetectNewH1()
  {
   datetime current_h1_open = iTime(_Symbol, PERIOD_H1, 0);
   if(current_h1_open <= 0)
      return(false);

   if(g_last_h1_open == 0)
     {
      g_last_h1_open = current_h1_open;
      return(false);
     }

   if(current_h1_open != g_last_h1_open)
     {
      g_last_h1_open = current_h1_open;
      return(true);
     }

   return(false);
  }

bool CalculateReferenceLevels(ReferenceData &ref)
  {
   ZeroMemory(ref);

   datetime ref_time = iTime(_Symbol, PERIOD_H1, 1);
   if(ref_time <= 0)
      return(false);

   ref.time  = ref_time;
   ref.open  = iOpen(_Symbol, PERIOD_H1, 1);
   ref.high  = iHigh(_Symbol, PERIOD_H1, 1);
   ref.low   = iLow(_Symbol, PERIOD_H1, 1);
   ref.close = iClose(_Symbol, PERIOD_H1, 1);

   if(ref.high <= 0.0 || ref.low <= 0.0 || ref.high < ref.low)
      return(false);

   ref.range = ref.high - ref.low;
   ref.q50   = (ref.high + ref.low) / 2.0;
   ref.q75   = (ref.high + ref.q50) / 2.0;
   ref.q25   = (ref.q50 + ref.low) / 2.0;
   ref.valid = true;
   return(true);
  }

bool LoadReferenceByTime(const datetime ref_time, ReferenceData &ref)
  {
   ZeroMemory(ref);

   int shift = iBarShift(_Symbol, PERIOD_H1, ref_time, true);
   if(shift < 0)
      return(false);

   datetime exact_time = iTime(_Symbol, PERIOD_H1, shift);
   if(exact_time != ref_time)
      return(false);

   ref.time  = exact_time;
   ref.open  = iOpen(_Symbol, PERIOD_H1, shift);
   ref.high  = iHigh(_Symbol, PERIOD_H1, shift);
   ref.low   = iLow(_Symbol, PERIOD_H1, shift);
   ref.close = iClose(_Symbol, PERIOD_H1, shift);

   if(ref.high <= 0.0 || ref.low <= 0.0 || ref.high < ref.low)
      return(false);

   ref.range = ref.high - ref.low;
   ref.q50   = (ref.high + ref.low) / 2.0;
   ref.q75   = (ref.high + ref.q50) / 2.0;
   ref.q25   = (ref.q50 + ref.low) / 2.0;
   ref.valid = true;
   return(true);
  }

void ProcessNewH1()
  {
   if(g_setup.active && !g_setup.rec.entry_filled)
      ExpireCurrentSetup("NEW_H1_SETUP_EXPIRY");

   if(!CalculateReferenceLevels(g_reference))
     {
      ZeroMemory(g_reference);
      ZeroMemory(g_setup);
      g_state = WAITING_FOR_NEW_H1;
      SetLastErrorText("Could not load the immediately previous completed H1 candle.");
      return;
     }

   DrawLevels();
   BeginSetup(false);
  }

bool BeginSetup(const bool reconstruct_history)
  {
   ZeroMemory(g_setup);

   if(!g_reference.valid)
     {
      g_state = WAITING_FOR_NEW_H1;
      return(false);
     }

   SetupLogRecord rec;
   InitialiseLogRecord(g_reference, rec);
   g_state = REFERENCE_READY;

   string geometry_reason;
   if(!ValidateReferenceGeometry(g_reference, rec.overshoot_level, geometry_reason))
     {
      rec.broker_rejection_reason = geometry_reason;
      rec.exit_reason = "BROKER_REJECTED";
      WriteSetupLog(rec);
      g_state = SETUP_FINISHED;
      SetLastErrorText(geometry_reason);
      return(false);
     }

   int own_open_positions = CountOwnOpenPositions();
   if(own_open_positions >= MAX_OPEN_TRADES)
     {
      rec.existing_position_blocked = true;
      rec.broker_rejection_reason = "EXISTING_POSITION_BLOCKED_NEW_SETUP";
      WriteSetupLog(rec);
      g_state = POSITION_OPEN;
      SetLastAction(StringFormat("EXISTING_POSITION_BLOCKED_NEW_SETUP (%d/%d open)",
                                 own_open_positions, MAX_OPEN_TRADES));
      return(false);
     }

   if(IsNettingAccount() && HasForeignPositionOnSymbol())
     {
      rec.broker_rejection_reason = "NETTING_FOREIGN_POSITION_BLOCKED";
      rec.exit_reason = "BROKER_REJECTED";
      WriteSetupLog(rec);
      g_state = SETUP_FINISHED;
      SetLastAction("NETTING_FOREIGN_POSITION_BLOCKED");
      return(false);
     }

   if(LastFinalizedReference() >= g_reference.time)
     {
      g_state = SETUP_FINISHED;
      SetLastAction("Reference already finalized; duplicate setup processing prevented");
      return(false);
     }

   if(LastAttemptedReference() >= g_reference.time)
     {
      g_state = SETUP_FINISHED;
      SetLastAction("Reference already had an entry attempt; duplicate entry prevented");
      return(false);
     }

   g_setup.active = true;
   g_setup.setup_open = iTime(_Symbol, PERIOD_H1, 0);
   g_setup.expiry = g_setup.setup_open + PeriodSeconds(PERIOD_H1);
   CopySetupLogRecord(rec, g_setup.rec);
   g_state = WAITING_FOR_OVERSHOOT;

   if(reconstruct_history)
      return(ReconstructCurrentSetupState());

   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick) && tick.bid > 0.0)
     {
      g_setup.previous_bid = tick.bid;
      g_setup.previous_bid_valid = true;
     }

   g_last_error = "";
   SetLastAction("New H1 setup ready; waiting for overshoot above Q75");
   return(true);
  }

bool ReconstructCurrentSetupState()
  {
   if(!g_setup.active)
      return(false);

   if(TimeCurrent() >= g_setup.expiry)
     {
      ExpireCurrentSetup("RESTART_AFTER_SETUP_WINDOW");
      return(false);
     }

   MqlTick ticks[];
   ulong from_msc = (ulong)g_setup.setup_open * 1000;
   ulong to_msc = (ulong)TimeCurrent() * 1000 + 999;
   int copied = CopyTicksRange(_Symbol, ticks, COPY_TICKS_ALL, from_msc, to_msc);

   if(copied <= 0)
     {
      g_setup.rec.broker_rejection_reason = "STATE_RECOVERY_UNCERTAIN";
      WriteSetupLog(g_setup.rec);
      g_setup.active = false;
      g_state = SETUP_FINISHED;
      SetLastErrorText("STATE_RECOVERY_UNCERTAIN - tick history unavailable for current H1 setup");
      return(false);
     }

   bool previous_valid = false;
   double previous_bid = 0.0;

   for(int i = 0; i < copied; ++i)
     {
      double bid = ticks[i].bid;
      double ask = ticks[i].ask;
      if(bid <= 0.0 || ask <= 0.0)
         continue;

      if(bid >= g_setup.rec.ref.high)
        {
         g_setup.rec.previous_high_reached_before_entry = true;
         g_setup.rec.exit_reason = "PREVIOUS_HIGH_INVALIDATED";
         g_setup.rec.broker_rejection_reason = "PREVIOUS_HIGH_REACHED_BEFORE_ENTRY";
         WriteSetupLog(g_setup.rec);
         g_setup.active = false;
         g_state = SETUP_INVALIDATED;
         SetLastAction("Recovered setup state: previous H1 High had already been reached before entry");
         return(false);
        }

      if(!g_setup.rec.overshoot_detected &&
         bid >= g_setup.rec.overshoot_level && bid < g_setup.rec.ref.high)
        {
         g_setup.rec.overshoot_detected = true;
         g_setup.rec.overshoot_time = (datetime)ticks[i].time;
        }

      if(g_setup.rec.overshoot_detected && previous_valid &&
         previous_bid > g_setup.rec.ref.q75 && bid <= g_setup.rec.ref.q75)
        {
         g_setup.rec.q75_return_detected = true;
         g_setup.rec.q75_return_time = (datetime)ticks[i].time;
         g_setup.rec.broker_rejection_reason = "ENTRY_MISSED_DURING_RESTART";
         WriteSetupLog(g_setup.rec);
         g_setup.active = false;
         g_state = SETUP_FINISHED;
         SetLastAction("Recovered setup state: Q75 return occurred while EA was offline; no retroactive entry");
         return(false);
        }

      previous_bid = bid;
      previous_valid = true;
     }

   if(previous_valid)
     {
      g_setup.previous_bid = previous_bid;
      g_setup.previous_bid_valid = true;
     }

   if(g_setup.rec.overshoot_detected)
     {
      g_state = WAITING_FOR_Q75_RETURN;
      SetLastAction("Recovered armed setup from tick history; waiting for downward Q75 return");
     }
   else
     {
      g_state = WAITING_FOR_OVERSHOOT;
      SetLastAction("Recovered current H1 setup; waiting for overshoot");
     }

   g_last_error = "";
   return(true);
  }

void ExpireCurrentSetup(const string reason_text)
  {
   if(!g_setup.active)
      return;

   if(!g_setup.rec.entry_filled)
     {
      g_setup.rec.signal_expired = true;
      g_setup.rec.exit_reason = "SETUP_EXPIRED";
      WriteSetupLog(g_setup.rec);
     }

   g_setup.active = false;
   g_state = SETUP_EXPIRED;
   SetLastAction("SETUP_EXPIRED - " + reason_text);
  }

void InvalidateCurrentSetup(const string reason_text)
  {
   if(!g_setup.active)
      return;

   g_setup.rec.previous_high_reached_before_entry = true;
   g_setup.rec.exit_reason = "PREVIOUS_HIGH_INVALIDATED";
   g_setup.rec.broker_rejection_reason = reason_text;
   WriteSetupLog(g_setup.rec);
   g_setup.active = false;
   g_state = SETUP_INVALIDATED;
   SetLastAction(reason_text);
  }

void ManageSetup()
  {
   if(!g_setup.active || g_position.active)
      return;

   if(g_setup.rec.entry_attempted)
      return;

   if(TimeCurrent() >= g_setup.expiry)
     {
      ExpireCurrentSetup("TIME_EXPIRY");
      return;
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   // H comes from the broker's H1 price series. Use Bid for the pre-entry
   // signal invalidation so spread does not become an extra signal filter.
   if(tick.bid >= g_setup.rec.ref.high)
     {
      InvalidateCurrentSetup("PREVIOUS_HIGH_REACHED_BEFORE_ENTRY");
      return;
     }

   if(!g_setup.rec.overshoot_detected &&
      tick.bid >= g_setup.rec.overshoot_level && tick.bid < g_setup.rec.ref.high)
     {
      g_setup.rec.overshoot_detected = true;
      g_setup.rec.overshoot_time = TimeCurrent();
      g_state = OVERSHOOT_ARMED;
      SetLastAction(StringFormat("Overshoot reached at/above %s; setup armed",
                                 PriceText(g_setup.rec.overshoot_level)));
     }

   if(g_setup.rec.overshoot_detected)
     {
      g_state = WAITING_FOR_Q75_RETURN;

      // Entry is valid only on a downward return-cross from ABOVE Q75.
      if(g_setup.previous_bid_valid &&
         g_setup.previous_bid > g_setup.rec.ref.q75 &&
         tick.bid <= g_setup.rec.ref.q75)
        {
         g_setup.rec.q75_return_detected = true;
         g_setup.rec.q75_return_time = TimeCurrent();
         SubmitReturnSell(tick);
         return;
        }
     }

   g_setup.previous_bid = tick.bid;
   g_setup.previous_bid_valid = true;
  }

// ============================================================================
// Risk-based position sizing and Q75 return entry
// ============================================================================
double CalculatePositionSize(const ReferenceData &ref, double &initial_risk_currency, string &error_text)
  {
   initial_risk_currency = 0.0;
   error_text = "";

   if(RiskPercent <= 0.0)
     {
      error_text = "RiskPercent must be greater than zero.";
      return(0.0);
     }

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double vol_min    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vol_max    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vol_step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(equity <= 0.0 || tick_size <= 0.0 || tick_value <= 0.0 ||
      vol_min <= 0.0 || vol_max <= 0.0 || vol_step <= 0.0)
     {
      error_text = "Invalid account/symbol sizing properties.";
      return(0.0);
     }

   // The strategy sizes from the intended Q75 entry to the original SL at H.
   double risk_distance = ref.high - ref.q75;
   if(risk_distance <= 0.0)
     {
      error_text = "Invalid Q75-to-H risk distance.";
      return(0.0);
     }

   double risk_money   = equity * (RiskPercent / 100.0);
   double ticks_to_sl  = risk_distance / tick_size;
   double risk_per_lot = ticks_to_sl * tick_value;

   if(risk_money <= 0.0 || ticks_to_sl <= 0.0 || risk_per_lot <= 0.0)
     {
      error_text = "Position-size risk calculation produced a non-positive result.";
      return(0.0);
     }

   double raw_volume = risk_money / risk_per_lot;

   // Round DOWN to the broker volume step so the configured risk is not exceeded.
   double steps = MathFloor((raw_volume / vol_step) + 1e-12);
   double volume = steps * vol_step;

   if(volume > vol_max)
     {
      double max_steps = MathFloor((vol_max / vol_step) + 1e-12);      volume = max_steps * vol_step;
     }

   volume = NormalizeDouble(volume, 8);

   if(volume < vol_min - 1e-12)
     {
      error_text = StringFormat("Calculated volume %.8f is below broker minimum %.8f.", volume, vol_min);
      return(0.0);
     }

   if(volume <= 0.0)
     {
      error_text = "Calculated volume is zero after volume-step normalization.";
      return(0.0);
     }

   initial_risk_currency = volume * risk_per_lot;
   return(volume);
  }

void SubmitReturnSell(const MqlTick &tick)
  {
   if(!g_setup.active || g_setup.rec.entry_attempted)
      return;

   // This reference candle gets at most one entry attempt, even across restarts.
   g_setup.rec.entry_attempted = true;
   MarkReferenceAttempted(g_setup.rec.ref.time);

   if(CountOwnOpenPositions() >= MAX_OPEN_TRADES)
     {
      g_setup.rec.existing_position_blocked = true;
      g_setup.rec.broker_rejection_reason = "EXISTING_POSITION_BLOCKED_NEW_SETUP";
      WriteSetupLog(g_setup.rec);
      g_setup.active = false;
      g_state = POSITION_OPEN;
      SetLastAction("EXISTING_POSITION_BLOCKED_NEW_SETUP at Q75 return");
      return;
     }

   if(IsNettingAccount() && HasForeignPositionOnSymbol())
     {
      g_setup.rec.broker_rejection_reason = "NETTING_FOREIGN_POSITION_BLOCKED";
      g_setup.rec.exit_reason = "BROKER_REJECTED";
      WriteSetupLog(g_setup.rec);
      g_setup.active = false;
      g_state = SETUP_FINISHED;
      SetLastAction("NETTING_FOREIGN_POSITION_BLOCKED at Q75 return");
      return;
     }

   string broker_reason;
   if(!ValidateBrokerMarketEntry(g_setup.rec.ref, tick, broker_reason))
     {
      if(broker_reason == "PREVIOUS_HIGH_REACHED_BEFORE_ENTRY")
        {
         g_setup.rec.previous_high_reached_before_entry = true;
         g_setup.rec.exit_reason = "PREVIOUS_HIGH_INVALIDATED";
        }
      else
         g_setup.rec.exit_reason = "BROKER_REJECTED";

      g_setup.rec.broker_rejection_reason = broker_reason;
      WriteSetupLog(g_setup.rec);
      g_setup.active = false;
      g_state = (broker_reason == "PREVIOUS_HIGH_REACHED_BEFORE_ENTRY" ? SETUP_INVALIDATED : SETUP_FINISHED);
      SetLastErrorText(broker_reason);
      return;
     }

   double initial_risk_currency = 0.0;
   string sizing_error;
   double volume = CalculatePositionSize(g_setup.rec.ref, initial_risk_currency, sizing_error);
   if(volume <= 0.0)
     {
      g_setup.rec.broker_rejection_reason = "POSITION_SIZE_ERROR: " + sizing_error;
      g_setup.rec.exit_reason = "BROKER_REJECTED";
      WriteSetupLog(g_setup.rec);
      g_setup.active = false;
      g_state = SETUP_FINISHED;
      SetLastErrorText(g_setup.rec.broker_rejection_reason);
      return;
     }

   g_setup.rec.lot_size = volume;
   g_setup.rec.initial_risk_currency = initial_risk_currency;
   g_setup.rec.spread_at_entry = tick.ask - tick.bid;
   g_setup.rec.target_entry = g_setup.rec.ref.q75;
   g_setup.rec.sl = g_setup.rec.ref.high;
   g_setup.rec.tp = g_setup.rec.ref.q25;

   string comment = "PHQRV1O|" + IntegerToString((long)g_setup.rec.ref.time);

   g_trade_api.SetExpertMagicNumber(MagicNumber);
   g_trade_api.SetMarginMode();
   g_trade_api.SetTypeFillingBySymbol(_Symbol);

   ResetLastError();
   bool ok = g_trade_api.Sell(volume,
                              _Symbol,
                              0.0,
                              g_setup.rec.ref.high,
                              g_setup.rec.ref.q25,
                              comment);
   uint retcode = g_trade_api.ResultRetcode();

   if(!ok || !IsTradeRetcodeSuccess(retcode))
     {
      g_setup.rec.broker_rejection_reason = "ENTRY_ORDER_REJECTED: " + TradeResultDetails();
      g_setup.rec.exit_reason = "BROKER_REJECTED";
      WriteSetupLog(g_setup.rec);
      g_setup.active = false;
      g_state = SETUP_FINISHED;
      SetLastErrorText(g_setup.rec.broker_rejection_reason);
      return;
     }

   double result_price = g_trade_api.ResultPrice();
   if(result_price > 0.0)
     {
      g_setup.rec.actual_entry = result_price;
      g_setup.rec.entry_slippage = result_price - g_setup.rec.target_entry;
     }

   g_state = SETUP_FINISHED;
   g_last_error = "";
   SetLastAction(StringFormat("Q75 downward return detected; market SELL request accepted near target %s",
                              PriceText(g_setup.rec.target_entry)));
  }

void RecoverSubmittedEntryIfNeeded()
  {
   if(g_position.active || !g_setup.active || !g_setup.rec.entry_attempted)
      return;

   ulong identifier = 0;
   ulong ticket = FindOwnPositionTicket(identifier);
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return;

   SetupLogRecord rec;
   CopySetupLogRecord(g_setup.rec, rec);
   rec.entry_filled = true;
   rec.fill_time = (datetime)PositionGetInteger(POSITION_TIME);
   rec.actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
   rec.entry_slippage = rec.actual_entry - rec.target_entry;
   rec.sl = PositionGetDouble(POSITION_SL);
   rec.tp = PositionGetDouble(POSITION_TP);
   rec.lot_size = PositionGetDouble(POSITION_VOLUME);

   ZeroMemory(g_position);
   g_position.active = true;
   g_position.position_ticket = ticket;
   g_position.position_identifier = identifier;
   g_position.break_even_attempted = false;
   CopySetupLogRecord(rec, g_position.rec);

   g_setup.active = false;
   g_state = POSITION_OPEN;
   SetLastAction("Market SELL fill recovered from live position state");
  }

// ============================================================================
// Open-position management and break-even
// ============================================================================
void CheckBreakEven()
  {
   if(!g_position.active || g_position.break_even_attempted)
      return;

   ulong ticket = g_position.position_ticket;
   if(ticket == 0 || !PositionSelectByTicket(ticket))
     {
      ulong identifier = 0;
      ticket = FindOwnPositionTicket(identifier);
      if(ticket == 0)
         return;
      g_position.position_ticket = ticket;
      g_position.position_identifier = identifier;
      PositionSelectByTicket(ticket);
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   // For a short position, Ask is the executable close-side price.
   if(tick.ask > g_position.rec.ref.q50)
      return;

   g_position.rec.q50_reached = true;
   g_position.break_even_attempted = true;

   double current_sl = PositionGetDouble(POSITION_SL);
   double current_tp = PositionGetDouble(POSITION_TP);
   double entry      = g_position.rec.actual_entry;
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tolerance  = MathMax(point * 0.5, 1e-12);

   // Never move the stop backwards. Equal/better stop means BE is already active.
   if(current_sl > 0.0 && current_sl <= entry + tolerance)
     {
      g_position.rec.break_even_activated = true;
      g_position.rec.break_even_time = TimeCurrent();
      g_position.rec.sl = current_sl;
      SetLastAction("Q50 reached; break-even already active/inferred");
      return;
     }

   g_trade_api.SetExpertMagicNumber(MagicNumber);
   ResetLastError();
   bool ok = g_trade_api.PositionModify(ticket, entry, current_tp);
   uint retcode = g_trade_api.ResultRetcode();

   if(!ok || !IsTradeRetcodeSuccess(retcode, true))
     {
      SetLastErrorText("BREAK_EVEN_MODIFICATION_REJECTED: " + TradeResultDetails());
      return;
     }

   g_position.rec.break_even_activated = true;
   g_position.rec.break_even_time = TimeCurrent();
   g_position.rec.sl = entry;
   g_last_error = "";
   SetLastAction("Q50 reached; stop moved once to actual entry price");
  }

void ManageOpenPosition()
  {
   if(!g_position.active)
      return;

   ulong ticket = g_position.position_ticket;
   bool selected = (ticket != 0 && PositionSelectByTicket(ticket));

   if(!selected)
     {
      ulong identifier = 0;
      ticket = FindOwnPositionTicket(identifier);
      if(ticket == 0)
         return;

      g_position.position_ticket = ticket;
      g_position.position_identifier = identifier;
      PositionSelectByTicket(ticket);
     }

   g_state = POSITION_OPEN;

   g_position.rec.sl = PositionGetDouble(POSITION_SL);
   g_position.rec.tp = PositionGetDouble(POSITION_TP);
   g_position.rec.lot_size = PositionGetDouble(POSITION_VOLUME);
   if(g_position.rec.actual_entry <= 0.0)
      g_position.rec.actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
   g_position.rec.entry_slippage = g_position.rec.actual_entry - g_position.rec.target_entry;

   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick) && g_position.rec.actual_entry > 0.0)
     {
      double favorable = g_position.rec.actual_entry - tick.ask;
      double adverse   = tick.ask - g_position.rec.actual_entry;

      if(favorable > g_position.rec.mfe_price)
         g_position.rec.mfe_price = favorable;
      if(adverse > g_position.rec.mae_price)
         g_position.rec.mae_price = adverse;

      double initial_risk_price = g_position.rec.ref.high - g_position.rec.ref.q75;
      if(initial_risk_price > 0.0)
        {
         g_position.rec.mfe_r = g_position.rec.mfe_price / initial_risk_price;
         g_position.rec.mae_r = g_position.rec.mae_price / initial_risk_price;
        }
     }

   CheckBreakEven();
   DrawPositionLevels();
  }

// ============================================================================
// Trade-transaction handling
// ============================================================================
double CalculateNetProfitForPosition(const ulong position_identifier,
                                     const datetime from_time,
                                     const datetime to_time)
  {
   if(position_identifier == 0)
      return(0.0);

   datetime from = from_time > 3600 ? from_time - 3600 : 0;
   datetime to   = to_time + 60;
   if(!HistorySelect(from, to))
      return(0.0);

   double total = 0.0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; ++i)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID) != position_identifier)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;

      total += HistoryDealGetDouble(deal, DEAL_PROFIT);
      total += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      total += HistoryDealGetDouble(deal, DEAL_SWAP);
      total += HistoryDealGetDouble(deal, DEAL_FEE);
     }

   return(total);
  }

string ExitReasonFromDeal(const ulong deal_ticket)
  {
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);

   if(reason == DEAL_REASON_TP)
      return("TAKE_PROFIT");

   if(reason == DEAL_REASON_SL)
     {
      if(g_position.rec.break_even_activated)
         return("BREAK_EVEN");
      return("STOP_LOSS");
     }

   return("OTHER_EXIT");
  }

void PromoteFillFromDeal(const ulong deal_ticket)
  {
   if(!HistoryDealSelect(deal_ticket))
      return;

   ulong deal_magic = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
   string symbol    = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
   if(symbol != _Symbol || deal_magic != MagicNumber)
      return;

   ENUM_DEAL_TYPE deal_type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
   ENUM_DEAL_ENTRY entry    = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   if(deal_type != DEAL_TYPE_SELL || entry != DEAL_ENTRY_IN)
      return;

   ulong position_identifier = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);

   if(g_position.active && g_position.position_identifier == position_identifier)
     {
      ulong live_ticket = FindOwnPositionTicketByIdentifier(position_identifier);
      if(live_ticket != 0 && PositionSelectByTicket(live_ticket))
        {
         g_position.position_ticket = live_ticket;
         g_position.rec.actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
         g_position.rec.entry_slippage = g_position.rec.actual_entry - g_position.rec.target_entry;
         g_position.rec.lot_size = PositionGetDouble(POSITION_VOLUME);
         g_position.rec.sl = PositionGetDouble(POSITION_SL);
         g_position.rec.tp = PositionGetDouble(POSITION_TP);
        }
      return;
     }

   SetupLogRecord rec;
   bool have_record = false;

   if(g_setup.active && g_setup.rec.entry_attempted)
     {
      CopySetupLogRecord(g_setup.rec, rec);
      have_record = true;
     }

   if(!have_record)
     {
      datetime ref_time = 0;
      string deal_comment = HistoryDealGetString(deal_ticket, DEAL_COMMENT);
      ReferenceData ref;
      ZeroMemory(ref);

      if(ParseReferenceTimeFromComment(deal_comment, ref_time) && LoadReferenceByTime(ref_time, ref))
         have_record = true;
      else
         have_record = InferReferenceFromEventTime((datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME), ref);

      if(have_record)
         InitialiseLogRecord(ref, rec);
     }

   if(!have_record)
     {
      SetLastErrorText("Fill detected but originating reference candle could not be recovered.");
      return;
     }

   rec.entry_attempted = true;
   rec.entry_filled = true;
   rec.fill_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
   rec.actual_entry = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   rec.target_entry = rec.ref.q75;
   rec.entry_slippage = rec.actual_entry - rec.target_entry;
   rec.sl = rec.ref.high;
   rec.tp = rec.ref.q25;

   if(rec.lot_size <= 0.0)
      rec.lot_size = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);

   if(rec.initial_risk_currency <= 0.0 && rec.lot_size > 0.0)
     {
      double risk_distance = rec.ref.high - rec.ref.q75;
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tick_size > 0.0 && tick_value > 0.0 && risk_distance > 0.0)
         rec.initial_risk_currency = (risk_distance / tick_size) * tick_value * rec.lot_size;
     }

   if(rec.spread_at_entry <= 0.0)
     {
      MqlTick tick;
      if(SymbolInfoTick(_Symbol, tick))
         rec.spread_at_entry = tick.ask - tick.bid;
     }

   ulong position_ticket = FindOwnPositionTicketByIdentifier(position_identifier);
   if(position_ticket == 0)
     {
      ulong found_identifier = 0;
      position_ticket = FindOwnPositionTicket(found_identifier);
      if(position_identifier == 0)
         position_identifier = found_identifier;
     }

   if(position_ticket != 0 && PositionSelectByTicket(position_ticket))
     {
      rec.actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
      rec.entry_slippage = rec.actual_entry - rec.target_entry;
      rec.lot_size = PositionGetDouble(POSITION_VOLUME);
      rec.sl = PositionGetDouble(POSITION_SL);
      rec.tp = PositionGetDouble(POSITION_TP);
     }

   ZeroMemory(g_position);
   g_position.active = true;
   g_position.position_ticket = position_ticket;
   g_position.position_identifier = position_identifier;
   g_position.break_even_attempted = false;
   CopySetupLogRecord(rec, g_position.rec);

   g_setup.active = false;
   g_state = POSITION_OPEN;
   g_last_error = "";
   SetLastAction(StringFormat("Overshoot-return SELL filled; actual entry=%s, slippage=%s",
                              PriceText(g_position.rec.actual_entry),
                              PriceText(g_position.rec.entry_slippage)));
  }

void FinaliseExitFromDeal(const ulong deal_ticket)
  {
   if(!g_position.active || !HistoryDealSelect(deal_ticket))
      return;

   ulong position_identifier = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
   if(position_identifier == 0 || position_identifier != g_position.position_identifier)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
      return;

   ulong live_ticket = FindOwnPositionTicketByIdentifier(position_identifier);
   if(live_ticket != 0)
     {
      g_position.position_ticket = live_ticket;
      return;
     }

   g_position.rec.exit_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
   g_position.rec.exit_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
   g_position.rec.exit_reason = ExitReasonFromDeal(deal_ticket);

   if(g_position.rec.actual_entry > 0.0)
     {
      double favorable = g_position.rec.actual_entry - g_position.rec.exit_price;
      double adverse   = g_position.rec.exit_price - g_position.rec.actual_entry;
      if(favorable > g_position.rec.mfe_price)
         g_position.rec.mfe_price = favorable;
      if(adverse > g_position.rec.mae_price)
         g_position.rec.mae_price = adverse;

      double initial_risk_price = g_position.rec.ref.high - g_position.rec.ref.q75;
      if(initial_risk_price > 0.0)
        {
         g_position.rec.mfe_r = g_position.rec.mfe_price / initial_risk_price;
         g_position.rec.mae_r = g_position.rec.mae_price / initial_risk_price;
        }
     }

   g_position.rec.profit_currency = CalculateNetProfitForPosition(position_identifier,
                                                                  g_position.rec.fill_time,
                                                                  g_position.rec.exit_time);

   if(g_position.rec.initial_risk_currency > 0.0)
      g_position.rec.result_r = g_position.rec.profit_currency / g_position.rec.initial_risk_currency;

   WriteTradeLog(g_position.rec);

   SetLastAction(StringFormat("Position closed: %s, net P/L=%s, result R=%s",
                              g_position.rec.exit_reason,
                              MoneyText(g_position.rec.profit_currency),
                              NumberText(g_position.rec.result_r, 4)));

   ZeroMemory(g_position);
   g_state = SETUP_FINISHED;
   DrawPositionLevels();
  }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
      return;

   string symbol = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   if(symbol != _Symbol)
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
      PromoteFillFromDeal(trans.deal);
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
      FinaliseExitFromDeal(trans.deal);
  }

// ============================================================================
// Restart recovery
// ============================================================================
void RemoveLegacyPendingOrders()
  {
   int total = OrdersTotal();
   for(int i = total - 1; i >= 0; --i)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_SELL_LIMIT && type != ORDER_TYPE_SELL_STOP &&
         type != ORDER_TYPE_SELL_STOP_LIMIT)
         continue;

      g_trade_api.SetExpertMagicNumber(MagicNumber);
      ResetLastError();
      bool ok = g_trade_api.OrderDelete(ticket);
      uint retcode = g_trade_api.ResultRetcode();

      if(!ok || !IsTradeRetcodeSuccess(retcode))
        {
         SetLastErrorText("Legacy PHQR pending-order removal failed: " + TradeResultDetails());
         continue;
        }

      SetLastAction(StringFormat("Removed legacy PHQR pending order ticket %s; overshoot version uses return-cross execution",
                                 TicketText(ticket)));
     }
  }

void RecoverExistingState()
  {
   ZeroMemory(g_position);

   int positions = PositionsTotal();
   for(int i = 0; i < positions; ++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      string comment = PositionGetString(POSITION_COMMENT);
      datetime position_time = (datetime)PositionGetInteger(POSITION_TIME);
      datetime ref_time = 0;
      ReferenceData ref;
      ZeroMemory(ref);
      bool have_ref = false;

      if(ParseReferenceTimeFromComment(comment, ref_time))
         have_ref = LoadReferenceByTime(ref_time, ref);
      if(!have_ref)
         have_ref = InferReferenceFromEventTime(position_time, ref);

      if(!have_ref)
        {
         SetLastErrorText("Could not recover reference candle for existing PHQR overshoot position.");
         continue;
        }

      SetupLogRecord rec;
      InitialiseLogRecord(ref, rec);
      rec.entry_attempted = true;
      rec.entry_filled = true;
      rec.fill_time = position_time;
      rec.target_entry = ref.q75;
      rec.actual_entry = PositionGetDouble(POSITION_PRICE_OPEN);
      rec.entry_slippage = rec.actual_entry - rec.target_entry;
      rec.sl = PositionGetDouble(POSITION_SL);
      rec.tp = PositionGetDouble(POSITION_TP);
      rec.lot_size = PositionGetDouble(POSITION_VOLUME);
      rec.spread_at_entry = -1.0;

      double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double risk_distance = ref.high - ref.q75;
      if(tick_size > 0.0 && tick_value > 0.0 && risk_distance > 0.0)
         rec.initial_risk_currency = (risk_distance / tick_size) * tick_value * rec.lot_size;

      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double tolerance = MathMax(point * 0.5, 1e-12);
      if(rec.sl > 0.0 && rec.sl <= rec.actual_entry + tolerance)
        {
         rec.q50_reached = true;
         rec.break_even_activated = true;
        }

      ZeroMemory(g_position);
      g_position.active = true;
      g_position.position_ticket = ticket;
      g_position.position_identifier = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      g_position.break_even_attempted = rec.break_even_activated;
      CopySetupLogRecord(rec, g_position.rec);
      g_state = POSITION_OPEN;

      SetLastAction("Recovered existing PHQR V1 overshoot position after restart");
      break;
     }
  }

// ============================================================================
// Chart visualisation
// ============================================================================
void DeleteObjectIfExists(const string name)
  {
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
  }

void CreatePriceLine(const string suffix,
                     const string label,
                     const double price,
                     const color line_color,
                     const ENUM_LINE_STYLE style = STYLE_SOLID)
  {
   string line_name = g_object_prefix + suffix + "_LINE";
   string text_name = g_object_prefix + suffix + "_TEXT";

   DeleteObjectIfExists(line_name);
   DeleteObjectIfExists(text_name);

   if(ObjectCreate(0, line_name, OBJ_HLINE, 0, 0, price))
     {
      ObjectSetInteger(0, line_name, OBJPROP_COLOR, line_color);
      ObjectSetInteger(0, line_name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, line_name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, line_name, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, line_name, OBJPROP_TEXT, label);
     }

   datetime label_time = iTime(_Symbol, PERIOD_H1, 0) + (datetime)(PeriodSeconds(PERIOD_H1) * 3 / 4);
   if(ObjectCreate(0, text_name, OBJ_TEXT, 0, label_time, price))
     {
      ObjectSetString(0, text_name, OBJPROP_TEXT, label);
      ObjectSetInteger(0, text_name, OBJPROP_COLOR, line_color);
      ObjectSetInteger(0, text_name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, text_name, OBJPROP_SELECTABLE, false);
     }
  }

void DrawLevels()
  {
   if(!g_reference.valid)
      return;

   double overshoot_level = g_reference.q75 + OvershootPercent * g_reference.range;

   CreatePriceLine("HIGH",      "PHQR V1 HIGH",       g_reference.high, clrRed,    STYLE_SOLID);
   CreatePriceLine("OVERSHOOT", "PHQR V1 OVERSHOOT", overshoot_level,  clrViolet, STYLE_DASH);
   CreatePriceLine("Q75",       "PHQR V1 ENTRY Q75",  g_reference.q75,  clrOrange, STYLE_SOLID);
   CreatePriceLine("Q50",       "PHQR V1 BE Q50",     g_reference.q50,  clrYellow, STYLE_DOT);
   CreatePriceLine("Q25",       "PHQR V1 TP Q25",     g_reference.q25,  clrGreen,  STYLE_SOLID);
   CreatePriceLine("LOW",       "PHQR V1 LOW",        g_reference.low,  clrBlue,   STYLE_SOLID);
   ChartRedraw(0);
  }

void DrawPositionLevels()
  {
   string entry_line = g_object_prefix + "POS_ENTRY_LINE";
   string entry_text = g_object_prefix + "POS_ENTRY_TEXT";
   string sl_line    = g_object_prefix + "POS_SL_LINE";
   string sl_text    = g_object_prefix + "POS_SL_TEXT";
   string tp_line    = g_object_prefix + "POS_TP_LINE";
   string tp_text    = g_object_prefix + "POS_TP_TEXT";

   if(!g_position.active)
     {
      DeleteObjectIfExists(entry_line);
      DeleteObjectIfExists(entry_text);
      DeleteObjectIfExists(sl_line);
      DeleteObjectIfExists(sl_text);
      DeleteObjectIfExists(tp_line);
      DeleteObjectIfExists(tp_text);
      ChartRedraw(0);
      return;
     }

   CreatePriceLine("POS_ENTRY", "PHQR V1 ACTUAL ENTRY", g_position.rec.actual_entry, clrWhite, STYLE_DASH);
   if(g_position.rec.sl > 0.0)
      CreatePriceLine("POS_SL", "PHQR V1 CURRENT SL", g_position.rec.sl, clrRed, STYLE_DASH);
   if(g_position.rec.tp > 0.0)
      CreatePriceLine("POS_TP", "PHQR V1 CURRENT TP", g_position.rec.tp, clrGreen, STYLE_DASH);
  }

void RemoveChartObjects()
  {
   string suffixes[] =
     {
      "HIGH_LINE","HIGH_TEXT","OVERSHOOT_LINE","OVERSHOOT_TEXT",
      "Q75_LINE","Q75_TEXT","Q50_LINE","Q50_TEXT","Q25_LINE","Q25_TEXT",
      "LOW_LINE","LOW_TEXT","POS_ENTRY_LINE","POS_ENTRY_TEXT",
      "POS_SL_LINE","POS_SL_TEXT","POS_TP_LINE","POS_TP_TEXT"
     };

   int count = ArraySize(suffixes);
   for(int i = 0; i < count; ++i)
      DeleteObjectIfExists(g_object_prefix + suffixes[i]);

   ChartRedraw(0);
  }

// ============================================================================
// Dashboard
// ============================================================================
void UpdateDashboard()
  {
   double floating_pl = 0.0;
   double current_r = 0.0;
   double live_sl = 0.0;
   double live_tp = 0.0;
   double live_entry = 0.0;
   bool position_live = false;

   if(g_position.active)
     {
      ulong ticket = g_position.position_ticket;
      if(ticket != 0 && PositionSelectByTicket(ticket))
        {
         position_live = true;
         floating_pl = PositionGetDouble(POSITION_PROFIT);
         live_sl = PositionGetDouble(POSITION_SL);
         live_tp = PositionGetDouble(POSITION_TP);
         live_entry = PositionGetDouble(POSITION_PRICE_OPEN);

         MqlTick tick;
         double initial_risk_price = g_position.rec.ref.high - g_position.rec.ref.q75;
         if(SymbolInfoTick(_Symbol, tick) && initial_risk_price > 0.0)
            current_r = (live_entry - tick.ask) / initial_risk_price;
        }
     }

   SetupLogRecord display_rec;
   ZeroMemory(display_rec);
   bool have_display_rec = false;
   if(g_position.active)
     {
      CopySetupLogRecord(g_position.rec, display_rec);
      have_display_rec = true;
     }
   else if(g_setup.rec.valid)
     {
      CopySetupLogRecord(g_setup.rec, display_rec);
      have_display_rec = true;
     }

   double overshoot_level = (g_reference.valid ? g_reference.q75 + OvershootPercent * g_reference.range : 0.0);

   string panel = "PHQR V1 — Original Overshoot & Return\n";
   panel += "Symbol: " + _Symbol + "\n";
   panel += "Reference H1 timestamp: " + (g_reference.valid ? TimeText(g_reference.time) : "n/a") + "\n";
   panel += "H: " + (g_reference.valid ? PriceText(g_reference.high) : "n/a") + "\n";
   panel += "OvershootLevel: " + (g_reference.valid ? PriceText(overshoot_level) : "n/a") + "\n";
   panel += "Q75: " + (g_reference.valid ? PriceText(g_reference.q75) : "n/a") + "\n";
   panel += "Q50: " + (g_reference.valid ? PriceText(g_reference.q50) : "n/a") + "\n";
   panel += "Q25: " + (g_reference.valid ? PriceText(g_reference.q25) : "n/a") + "\n";
   panel += "L: " + (g_reference.valid ? PriceText(g_reference.low) : "n/a") + "\n";
   panel += "Reference Range: " + (g_reference.valid ? PriceText(g_reference.range) : "n/a") + "\n";
   panel += "OvershootPercent: " + NumberText(OvershootPercent, 4) + "\n";
   panel += "RiskPercent: " + NumberText(RiskPercent, 4) + "%\n";
   panel += "Maximum Open Trades: " + IntegerToString(MAX_OPEN_TRADES) + "\n";
   panel += "Current setup state: " + StateText(g_state) + "\n";
   panel += "Overshoot detected: " + YesNo(have_display_rec && display_rec.overshoot_detected) + "\n";
   panel += "Previous High invalidated: " + YesNo(have_display_rec && display_rec.previous_high_reached_before_entry) + "\n";
   panel += "Waiting for Q75 return: " + YesNo(g_setup.active && g_setup.rec.overshoot_detected && !g_setup.rec.q75_return_detected) + "\n";
   panel += "Position status: " + (position_live ? "OPEN" : "NONE") + "\n";
   panel += "Target entry: " + (have_display_rec ? PriceText(display_rec.target_entry) : "n/a") + "\n";
   panel += "Actual entry: " + (position_live ? PriceText(live_entry) : (have_display_rec && display_rec.actual_entry > 0.0 ? PriceText(display_rec.actual_entry) : "n/a")) + "\n";
   panel += "Entry slippage: " + (have_display_rec ? PriceText(display_rec.entry_slippage) : "n/a") + "\n";
   panel += "SL: " + (position_live ? PriceText(live_sl) : (have_display_rec ? PriceText(display_rec.sl) : "n/a")) + "\n";
   panel += "TP: " + (position_live ? PriceText(live_tp) : (have_display_rec ? PriceText(display_rec.tp) : "n/a")) + "\n";
   panel += "Break-even activated: " + YesNo(g_position.active && g_position.rec.break_even_activated) + "\n";
   panel += "Current floating P/L: " + MoneyText(floating_pl) + "\n";
   panel += "Current R multiple: " + NumberText(current_r, 4) + "\n";
   panel += "Last action: " + g_last_action + "\n";
   panel += "Last skip/invalidation reason: " + (g_last_error == "" ? "none" : g_last_error);

   Comment(panel);
  }

// ============================================================================
// CSV logging
// ============================================================================
void WriteSetupLog(SetupLogRecord &rec)
  {
   WriteCSVRecord(rec);
   if(rec.valid && rec.ref.valid)
      MarkReferenceFinalized(rec.ref.time);
  }

void WriteTradeLog(SetupLogRecord &rec)
  {
   WriteCSVRecord(rec);
   if(rec.valid && rec.ref.valid)
      MarkReferenceFinalized(rec.ref.time);
  }

void WriteCSVRecord(SetupLogRecord &rec)
  {
   if(!EnableCSVLogging || !rec.valid || !rec.ref.valid)
      return;

   int handle = FileOpen(g_csv_filename,
                         FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE,
                         ',');
   if(handle == INVALID_HANDLE)
     {
      SetLastErrorText(StringFormat("CSV FileOpen failed for %s, error=%d", g_csv_filename, GetLastError()));
      return;
     }

   if(FileSize(handle) == 0)
     {
      FileWrite(handle,
                "reference_timestamp",
                "symbol",
                "reference_open",
                "reference_high",
                "reference_low",
                "reference_close",
                "range",
                "Q75",
                "Q50",
                "Q25",
                "overshoot_percent",
                "overshoot_level",
                "overshoot_detected",
                "overshoot_time",
                "previous_high_reached_before_entry",
                "Q75_return_detected",
                "Q75_return_time",
                "entry_attempted",
                "entry_filled",
                "target_entry",
                "actual_entry",
                "entry_slippage",
                "spread_at_entry",
                "SL",
                "TP",
                "lot_size",
                "risk_percent",
                "initial_risk_currency",
                "theoretical_RR",
                "Q50_reached",
                "break_even_activated",
                "break_even_time",
                "maximum_favorable_excursion_price",
                "maximum_favorable_excursion_R",
                "maximum_adverse_excursion_price",
                "maximum_adverse_excursion_R",
                "exit_time",
                "exit_price",
                "exit_reason",
                "profit_currency",
                "result_R",
                "signal_expired",
                "existing_position_blocked",
                "broker_rejection_reason");
     }

   FileSeek(handle, 0, SEEK_END);

   FileWrite(handle,
             TimeText(rec.ref.time),
             _Symbol,
             PriceText(rec.ref.open),
             PriceText(rec.ref.high),
             PriceText(rec.ref.low),
             PriceText(rec.ref.close),
             PriceText(rec.ref.range),
             PriceText(rec.ref.q75),
             PriceText(rec.ref.q50),
             PriceText(rec.ref.q25),
             NumberText(rec.overshoot_percent, 6),
             PriceText(rec.overshoot_level),
             BoolText(rec.overshoot_detected),
             TimeText(rec.overshoot_time),
             BoolText(rec.previous_high_reached_before_entry),
             BoolText(rec.q75_return_detected),
             TimeText(rec.q75_return_time),
             BoolText(rec.entry_attempted),
             BoolText(rec.entry_filled),
             PriceText(rec.target_entry),
             PriceText(rec.actual_entry),
             PriceText(rec.entry_slippage),
             NumberText(rec.spread_at_entry, 8),
             PriceText(rec.sl),
             PriceText(rec.tp),
             VolumeText(rec.lot_size),
             NumberText(rec.risk_percent, 4),
             MoneyText(rec.initial_risk_currency),
             NumberText(rec.theoretical_rr, 4),
             BoolText(rec.q50_reached),
             BoolText(rec.break_even_activated),
             TimeText(rec.break_even_time),
             NumberText(rec.mfe_price, 8),
             NumberText(rec.mfe_r, 6),
             NumberText(rec.mae_price, 8),
             NumberText(rec.mae_r, 6),
             TimeText(rec.exit_time),
             PriceText(rec.exit_price),
             rec.exit_reason,
             MoneyText(rec.profit_currency),
             NumberText(rec.result_r, 6),
             BoolText(rec.signal_expired),
             BoolText(rec.existing_position_blocked),
             rec.broker_rejection_reason);

   FileFlush(handle);
   FileClose(handle);
  }

// ============================================================================
// Expert lifecycle
// ============================================================================
int OnInit()
  {
   if(RiskPercent <= 0.0)
     {
      Print("PHQR V1: RiskPercent must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(OvershootPercent <= 0.0)
     {
      Print("PHQR V1: OvershootPercent must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   ZeroMemory(g_reference);
   ZeroMemory(g_setup);
   ZeroMemory(g_position);

   g_trade_api.SetExpertMagicNumber(MagicNumber);
   g_trade_api.SetMarginMode();

   g_csv_filename = StringFormat("PHQR_V1_OriginalOvershoot_%s_%I64u.csv", SafeFilenameSymbol(), MagicNumber);
   g_object_prefix = StringFormat("PHQRV1O_%I64u_", MagicNumber);
   g_last_h1_open = iTime(_Symbol, PERIOD_H1, 0);

   RemoveLegacyPendingOrders();
   RecoverExistingState();

   if(CalculateReferenceLevels(g_reference))
      DrawLevels();

   if(g_position.active)
     {
      g_state = POSITION_OPEN;
      DrawPositionLevels();
     }