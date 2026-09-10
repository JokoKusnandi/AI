//+------------------------------------------------------------------+
//|                                              StatEdgeBot.mq5     |
//|                      Converted from Python Statistical Edge Bot  |
//+------------------------------------------------------------------+
#property copyright "Converted from Python"
#property version   "2.00"

#include <Trade\Trade.mqh>

input group "General"
input string InpSymbols                 = "BTCUSD.vx";   
input int    InpCheckIntervalSeconds    = 15;
input double InpMaxDailyLoss            = 5.0;   // Circuit breaker harian (USD)
input long   InpMagic                   = 20260806;
input int    InpCooldownSeconds         = 900;           
input bool   InpPrintLogs               = true;

input group "Statistical Edge Settings"
input double InpZScoreThreshold         = 2.0;   // Deviasi statistik untuk entry trigger
input double InpVolZScoreMin            = 1.0;   // Validasi volume fakeout
input double InpAtrTrailMult            = 1.5;   // Multiplier trailing stop
input int    InpStatPeriod              = 20;    // Periode rolling window

input group "Trade Settings"
input double InpDefaultLot              = 0.01;    
input double InpRiskPercent             = 10.0;    // Risiko per trade % (10% dari $30 = $3)
input int    InpDefaultMaxSpreadPoints  = 3000;    // Max spread points (Sesuai Python)
input double InpDefaultSLDistance       = 5.0;     // Fallback SL jika ATR error
input double InpBTCSLDistance           = 150.0;   // Fallback SL khusus BTC
input double InpMarginBuffer            = 15.0;
input int    InpSlippagePoints          = 20;

input group "Data Settings"
input ENUM_TIMEFRAMES InpTFEntry        = PERIOD_M15;
input ENUM_TIMEFRAMES InpTFTrendH4      = PERIOD_H4;
input int    InpBars                    = 100; 

CTrade trade;
string   g_symbols[];
datetime g_last_entry[];

//+------------------------------------------------------------------+
//| Logging helper                                                   |
//+------------------------------------------------------------------+
void Log(const string message)
{
   if(InpPrintLogs) Print(message);
}

//+------------------------------------------------------------------+
//| Parse comma-separated symbols                                    |
//+------------------------------------------------------------------+
int ParseSymbols(const string text)
{
   ArrayResize(g_symbols, 0);
   string parts[];
   int n = StringSplit(text, ',', parts);
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(parts[i]); StringTrimRight(parts[i]);
      if(StringLen(parts[i]) > 0)
      {
         int size = ArraySize(g_symbols);
         ArrayResize(g_symbols, size + 1);
         g_symbols[size] = parts[i];
      }
   }
   return ArraySize(g_symbols);
}

//+------------------------------------------------------------------+
//| Diagnose account and terminal                                    |
//+------------------------------------------------------------------+
bool DiagnoseAccount()
{
   Print("========== DIAGNOSA AKUN MT5 ==========");
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) { Print("Terminal tidak terhubung."); return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { Print("Algo Trading mati."); return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) { Print("Account trade allowed = false."); return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) { Print("Expert trading tidak diizinkan."); return false; }

   Print("Login   : ", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("Balance : ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("Equity  : ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("=======================================");
   return true;
}

//+------------------------------------------------------------------+
//| Smart Lot Calculator                                             |
//+------------------------------------------------------------------+
double GetSmartLot(const string symbol, double sl_distance_price)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = balance * (InpRiskPercent / 100.0); 
   
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   if(tick_value <= 0 || tick_size <= 0 || sl_distance_price <= 0 || point <= 0) 
      return InpDefaultLot; 
      
   double value_per_point = (tick_value / tick_size) * point;
   double sl_points = sl_distance_price / point;
   double calculated_lot = risk_amount / (sl_points * value_per_point);
   
   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   calculated_lot = MathFloor(calculated_lot / step_lot) * step_lot;
   if(calculated_lot < min_lot) calculated_lot = min_lot;
   if(calculated_lot > max_lot) calculated_lot = max_lot;
   
   double margin_req = 0;
   double current_price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(OrderCalcMargin(ORDER_TYPE_BUY, symbol, calculated_lot, current_price, margin_req))
   {
       double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
       if(margin_req > free_margin * 0.8) calculated_lot = min_lot;
   }
   return NormalizeDouble(calculated_lot, 2);
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int GetMaxSpreadPoints(const string symbol) { return InpDefaultMaxSpreadPoints; }

double GetSLDistance(const string symbol)
{
   if(StringFind(symbol, "BTCUSD") >= 0) return InpBTCSLDistance;
   return InpDefaultSLDistance; 
}

bool HasOpenPosition(const string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol) return true;
   }
   return false;
}

double GetDailyLoss()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime start_today = StructToTime(dt);
   if(!HistorySelect(start_today, TimeCurrent() + 60)) return 0.0;

   double loss = 0.0;
   int total_deals = HistoryDealsTotal();
   for(int i = 0; i < total_deals; i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0) continue;
      double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
      if(profit < 0.0) loss += MathAbs(profit);
   }
   return loss;
}

bool GetRates(const string symbol, ENUM_TIMEFRAMES timeframe, int count, MqlRates &rates[])
{
   if(!SymbolSelect(symbol, true)) return false;
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, timeframe, 0, count, rates);
   return (copied >= count);
}

//+------------------------------------------------------------------+
//| STATISTICAL MATH FUNCTIONS (PYTHON CONVERTED)                    |
//+------------------------------------------------------------------+
double CalcBBZScore(const MqlRates &rates[], int period, int shift)
{
   int total = ArraySize(rates);
   if(period <= 1 || shift < 0 || shift + period > total) return 0.0;
   double sum = 0.0, sum_sq = 0.0;
   for(int i = shift; i < shift + period; i++) { sum += rates[i].close; sum_sq += rates[i].close * rates[i].close; }
   double mean = sum / period;
   double variance = (sum_sq - (sum * sum) / period) / (period - 1);
   if(variance < 0) variance = 0;
   double std = MathSqrt(variance);
   if(std < 1e-10) return 0.0;
   return (rates[shift].close - mean) / std;
}

double CalcLRSlope(const MqlRates &rates[], int period, int shift)
{
   int total = ArraySize(rates);
   if(period <= 1 || shift < 0 || shift + period > total) return 0.0;
   double sum_x = 0, sum_y = 0, sum_xy = 0, sum_x2 = 0;
   for(int i = 0; i < period; i++)
   {
      double x = (double)i;
      int idx = shift + period - 1 - i; // Map oldest to newest
      double y = rates[idx].close;
      sum_x += x; sum_y += y; sum_xy += x * y; sum_x2 += x * x;
   }
   double denom = (period * sum_x2 - sum_x * sum_x);
   if(MathAbs(denom) < 1e-10) return 0.0;
   return (period * sum_xy - sum_x * sum_y) / denom;
}

double CalcVolZScore(const MqlRates &rates[], int period, int shift)
{
   int total = ArraySize(rates);
   if(period <= 1 || shift < 0 || shift + period > total) return 0.0;
   double sum = 0.0, sum_sq = 0.0;
   for(int i = shift; i < shift + period; i++) { double v = (double)rates[i].tick_volume; sum += v; sum_sq += v * v; }
   double mean = sum / period;
   double variance = (sum_sq - (sum * sum) / period) / (period - 1);
   if(variance < 0) variance = 0;
   double std = MathSqrt(variance);
   if(std < 1e-10) return 0.0;
   return ((double)rates[shift].tick_volume - mean) / std;
}

double CalcATR(const MqlRates &rates[], int period, int shift)
{
   int total = ArraySize(rates);
   if(period <= 0 || shift < 0 || shift + period + 1 > total) return 0.0;
   double sum_tr = 0.0;
   for(int i = shift; i < shift + period; i++)
   {
      double tr1 = rates[i].high - rates[i].low;
      double tr2 = MathAbs(rates[i].high - rates[i+1].close);
      double tr3 = MathAbs(rates[i].low - rates[i+1].close);
      sum_tr += MathMax(tr1, MathMax(tr2, tr3));
   }
   return sum_tr / period;
}

//+------------------------------------------------------------------+
//| Eksekusi Order                                                   |
//+------------------------------------------------------------------+
bool ExecuteTrade(const string symbol, const int dir, double entry, double sl, double tp)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return false;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(point <= 0.0) return false;

   int max_spread_points = GetMaxSpreadPoints(symbol);
   double spread = tick.ask - tick.bid;
   if(spread > max_spread_points * point)
   {
      Log(StringFormat("[SKIP] %s: spread terlalu lebar %.1f points", symbol, spread / point));
      return false;
   }

   double sl_distance_price = MathAbs(entry - sl);
   double lot = GetSmartLot(symbol, sl_distance_price);
   Log(StringFormat("[LOT INFO] %s | Risiko: %.2f%% | Lot: %.2f", symbol, InpRiskPercent, lot));

   ENUM_ORDER_TYPE order_type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin_required = 0.0;
   if(!OrderCalcMargin(order_type, symbol, lot, entry, margin_required)) return false;

   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required + InpMarginBuffer)
   {
      Log(StringFormat("[SKIP] %s: free margin kurang.", symbol));
      return false;
   }

   entry = NormalizeDouble(entry, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(symbol);

   bool ok = (dir > 0) ? trade.Buy(lot, symbol, entry, sl, tp, "StatEdge_BUY") : 
                         trade.Sell(lot, symbol, entry, sl, tp, "StatEdge_SELL");

   uint retcode = trade.ResultRetcode();
   if(ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
   {
      Log(StringFormat("[SUCCESS] %s %s @ %s | SL:%s TP:%s", symbol, (dir > 0 ? "BUY" : "SELL"), DoubleToString(entry, digits), DoubleToString(sl, digits), DoubleToString(tp, digits)));
      return true;
   }
   Log(StringFormat("[ERROR] %s: retcode=%d, comment=%s", symbol, retcode, trade.ResultComment()));
   return false;
}

//+------------------------------------------------------------------+
//| ATR Trailing Stop Management                                     |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      string symbol = PositionGetString(POSITION_SYMBOL);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      
      bool is_our_symbol = false;
      for(int s = 0; s < ArraySize(g_symbols); s++) if(g_symbols[s] == symbol) { is_our_symbol = true; break; }
      if(!is_our_symbol) continue;

      long pos_type = PositionGetInteger(POSITION_TYPE);
      double current_sl = PositionGetDouble(POSITION_SL);
      double current_tp = PositionGetDouble(POSITION_TP);
      
      MqlRates m15[];
      if(!GetRates(symbol, InpTFEntry, InpStatPeriod + 5, m15)) continue;
      
      double atr = CalcATR(m15, InpStatPeriod, 0);
      if(atr <= 0) continue;
      
      double trail_distance = atr * InpAtrTrailMult;
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) continue;
      
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double new_sl = 0;
      
      if(pos_type == POSITION_TYPE_BUY)
      {
         new_sl = NormalizeDouble(tick.bid - trail_distance, digits);
         if(new_sl > current_sl && new_sl < tick.bid)
         {
            if(trade.PositionModify(ticket, new_sl, current_tp))
               Log(StringFormat("[TRAIL] %s Buy SL digeser ke %s", symbol, DoubleToString(new_sl, digits)));
         }
      }
      else if(pos_type == POSITION_TYPE_SELL)
      {
         new_sl = NormalizeDouble(tick.ask + trail_distance, digits);
         if((new_sl < current_sl || current_sl == 0) && new_sl > tick.ask)
         {
            if(trade.PositionModify(ticket, new_sl, current_tp))
               Log(StringFormat("[TRAIL] %s Sell SL digeser ke %s", symbol, DoubleToString(new_sl, digits)));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Proses Entry Logika Statistik                                    |
//+------------------------------------------------------------------+
void ProcessSymbol(const string symbol, const int idx)
{
   Log(StringFormat("=== %s | Cek %s ===", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), symbol));

   if(HasOpenPosition(symbol)) return;
   if(idx >= 0 && TimeCurrent() - g_last_entry[idx] < InpCooldownSeconds) return;

   MqlRates h4[], m15[];
   if(!GetRates(symbol, InpTFTrendH4, InpStatPeriod + 5, h4)) return;
   if(!GetRates(symbol, InpTFEntry, InpStatPeriod + 5, m15)) return;

   double lr_slope   = CalcLRSlope(h4, InpStatPeriod, 0);
   double bb_zscore  = CalcBBZScore(m15, InpStatPeriod, 0);
   double vol_zscore = CalcVolZScore(m15, InpStatPeriod, 0);
   double atr_val    = CalcATR(m15, InpStatPeriod, 0);
   
   Log(StringFormat("[STATS] %s | H4 LR: %.4f | M15 BB_Z: %.2f | Vol_Z: %.2f | ATR: %.2f",
                    symbol, lr_slope, bb_zscore, vol_zscore, atr_val));

   int signal = 0;
   double entry = 0.0;
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return;

   bool trend_bullish = (lr_slope > 0);
   bool trend_bearish = (lr_slope < 0);

   if(trend_bullish && bb_zscore <= -InpZScoreThreshold && vol_zscore >= InpVolZScoreMin)
   { signal = 1; entry = tick.ask; }
   else if(trend_bearish && bb_zscore >= InpZScoreThreshold && vol_zscore >= InpVolZScoreMin)
   { signal = -1; entry = tick.bid; }

   if(signal == 0 || entry <= 0.0) { Log(StringFormat("No signal untuk %s", symbol)); return; }

   double sl_distance = atr_val * 2.0; 
   if(sl_distance <= 0) sl_distance = GetSLDistance(symbol); 
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS); 
   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop = (stops_level > 0 ? (double)stops_level * point : 10 * point);
   double spread = tick.ask - tick.bid;
   double actual_sl_distance = MathMax(sl_distance, spread + min_stop + 10 * point);
   
   double sl = 0.0, tp = 0.0;
   if(signal > 0) { sl = entry - actual_sl_distance; tp = entry + actual_sl_distance * 2.0; }
   else           { sl = entry + actual_sl_distance; tp = entry - actual_sl_distance * 2.0; }

   Log(StringFormat("[FINAL] %s | %s | Entry: %s | SL: %s | TP: %s", symbol, (signal > 0 ? "BUY" : "SELL"), DoubleToString(entry, digits), DoubleToString(sl, digits), DoubleToString(tp, digits)));

   if(ExecuteTrade(symbol, signal, entry, sl, tp) && idx >= 0)
      g_last_entry[idx] = TimeCurrent();
}

//+------------------------------------------------------------------+
//| Main Loop Engine                                                 |
//+------------------------------------------------------------------+
void RunChecks()
{
   static datetime last_check = 0;
   if(TimeCurrent() - last_check < InpCheckIntervalSeconds) return;
   last_check = TimeCurrent();
   
   ManageTrailingStop(); // ATR Trailing Stop berjalan setiap siklus

   if(GetDailyLoss() >= InpMaxDailyLoss)
   {
      Log(StringFormat("DAILY LOSS LIMIT: %.2f. Bot istirahat.", GetDailyLoss()));
      return;
   }

   for(int i = 0; i < ArraySize(g_symbols); i++) ProcessSymbol(g_symbols[i], i);
}

int OnInit()
{
   if(InpCheckIntervalSeconds <= 0) return INIT_PARAMETERS_INCORRECT;
   if(ParseSymbols(InpSymbols) <= 0) return INIT_PARAMETERS_INCORRECT;

   ArrayResize(g_last_entry, ArraySize(g_symbols));
   ArrayInitialize(g_last_entry, 0);

   for(int i = 0; i < ArraySize(g_symbols); i++) SymbolSelect(g_symbols[i], true);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(!DiagnoseAccount()) return INIT_FAILED;

   EventSetTimer(1);
   Print("Statistical Edge Bot running...");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }
void OnTick() { RunChecks(); }
void OnTimer() { RunChecks(); }