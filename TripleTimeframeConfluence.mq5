//+------------------------------------------------------------------+
//|                                     TripleTimeframeConfluence.mq5|
//|                      V5.0: ATR Dynamic SL/TP, Pullback & Breakeven|
//+------------------------------------------------------------------+
#property copyright "Converted from Python"
#property version   "5.00"

#include <Trade\Trade.mqh>

input group "General"
input string InpSymbols                 = "BTCUSD.vx";   
input int    InpCheckIntervalSeconds    = 15;
input int    InpEntryScoreThreshold     = 40;      // Naikkan sedikit agar filter lebih ketat (Max score 100)
input double InpMaxDailyLoss            = 500.0;   
input long   InpMagic                   = 20260809;
input int    InpCooldownSeconds         = 900;           
input bool   InpPrintLogs               = true;

input group "Trade Settings"
input double InpDefaultLot              = 0.01;    
input double InpRiskPercent             = 2.0;     // TURUNKAN: 2% per trade adalah standar profesional
input int    InpDefaultMaxSpreadPoints  = 20;
input int    InpBTCMaxSpreadPoints      = 10000;   
input double InpMarginBuffer            = 15.0;
input int    InpSlippagePoints          = 20;

input group "Data Settings (Triple Timeframe)"
input ENUM_TIMEFRAMES InpTFMacro        = PERIOD_H1;   
input ENUM_TIMEFRAMES InpTFMid          = PERIOD_M15;  
input ENUM_TIMEFRAMES InpTFEntry        = PERIOD_M5;   
input int    InpBars                    = 500;

CTrade trade;
string   g_symbols[];
datetime g_last_entry[];

void Log(const string message) { if(InpPrintLogs) Print(message); }

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

bool DiagnoseAccount()
{
   Print("========== DIAGNOSA AKUN MT5 ==========");
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) { Print("Terminal tidak terhubung."); return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) { Print("Algo Trading mati."); return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) { Print("Account trade allowed = false."); return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) { Print("Expert trading tidak diizinkan."); return false; }
   Print("Balance : ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("Equity  : ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("=======================================");
   return true;
}

// >>> FUNGSI BARU: Menghitung ATR (Average True Range) untuk SL/TP Dinamis <<<
double SimpleATR(const MqlRates &rates[], int period, int shift)
{
   int total = ArraySize(rates);
   if(period <= 0 || shift < 0 || shift + period + 1 > total) return 0.0;
   double sum = 0.0;
   for(int i = shift; i < shift + period; i++)
   {
      double tr1 = rates[i].high - rates[i].low;
      double tr2 = MathAbs(rates[i].high - rates[i+1].close);
      double tr3 = MathAbs(rates[i].low - rates[i+1].close);
      sum += MathMax(tr1, MathMax(tr2, tr3));
   }
   return sum / period;
}

double GetSmartLot(const string symbol, double sl_distance_price)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = balance * (InpRiskPercent / 100.0); 
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tick_value <= 0 || tick_size <= 0 || sl_distance_price <= 0 || point <= 0) return InpDefaultLot; 
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
       if(margin_req > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.8) calculated_lot = min_lot;
   }
   return NormalizeDouble(calculated_lot, 2);
}

int GetMaxSpreadPoints(const string symbol) { return (StringFind(symbol, "BTCUSD") >= 0) ? InpBTCMaxSpreadPoints : InpDefaultMaxSpreadPoints; }

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
   if(!HistorySelect(StructToTime(dt), TimeCurrent() + 60)) return 0.0;
   double loss = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
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
   return (CopyRates(symbol, timeframe, 0, count, rates) >= count);
}

bool SMA(const MqlRates &rates[], int period, int shift, double &value)
{
   int total = ArraySize(rates);
   if(period <= 0 || shift < 0 || shift + period > total) return false;
   double sum = 0.0;
   for(int i = shift; i < shift + period; i++) sum += rates[i].close;
   value = sum / period;
   return true;
}

bool StdDevClose(const MqlRates &rates[], int period, int shift, double &value)
{
   int total = ArraySize(rates);
   if(period <= 1 || shift < 0 || shift + period > total) return false;
   double mean = 0.0;
   if(!SMA(rates, period, shift, mean)) return false;
   double sum_sq = 0.0;
   for(int i = shift; i < shift + period; i++) { double d = rates[i].close - mean; sum_sq += d * d; }
   value = MathSqrt(sum_sq / (period - 1));
   return true;
}

bool RSISimple(const MqlRates &rates[], int period, int shift, double &value)
{
   int total = ArraySize(rates);
   if(period <= 0 || shift < 0 || shift + period + 1 > total) return false;
   double gain = 0.0, loss = 0.0;
   for(int i = shift; i < shift + period; i++)
   {
      double change = rates[i].close - rates[i + 1].close;
      if(change > 0.0) gain += change; else if(change < 0.0) loss -= change;
   }
   gain /= period; loss /= period;
   if(loss == 0.0) value = (gain == 0.0) ? 50.0 : 100.0;
   else value = 100.0 - (100.0 / (1.0 + gain / loss));
   return true;
}

bool BuildAD(const MqlRates &rates[], double &ad[])
{
   int total = ArraySize(rates);
   if(total <= 0) return false;
   ArraySetAsSeries(ad, false); ArrayResize(ad, total);
   double cum = 0.0;
   for(int i = total - 1; i >= 0; i--)
   {
      double range = rates[i].high - rates[i].low;
      double clv = ((rates[i].close - rates[i].low) - (rates[i].high - rates[i].close)) / (range + 1e-10);
      cum += clv * (double)rates[i].tick_volume;
      ad[i] = cum;
   }
   return true;
}

bool VolumeAverage(const MqlRates &rates[], int period, int shift, double &value)
{
   int total = ArraySize(rates);
   if(period <= 0 || shift < 0 || shift + period > total) return false;
   double sum = 0.0;
   for(int i = shift; i < shift + period; i++) sum += (double)rates[i].tick_volume;
   value = sum / period;
   return true;
}

int CheckH1Trend(const MqlRates &h1[])
{
   double ma20, ma50;
   if(!SMA(h1, 20, 0, ma20) || !SMA(h1, 50, 0, ma50)) return 0;
   if(h1[0].close > ma20 && ma20 > ma50) return 1;  
   if(h1[0].close < ma20 && ma20 < ma50) return -1; 
   return 0; 
}

// >>> DIPERBAIKI: Mengganti "Touch BB" dengan "Pullback & Bounce" (Trend Following Murni) <<<
int CalculateEntryScore(const MqlRates &m5[], const MqlRates &m15[], const MqlRates &h1[], const int dir)
{
   if(ArraySize(m5) < 60 || ArraySize(h1) < 210) return 0;
   int score = 0;
   double close0 = m5[0].close;

   double ma20_0, ma50_0;
   if(!SMA(m5, 20, 0, ma20_0) || !SMA(m5, 50, 0, ma50_0)) return 0;

   // 1. PULLBACK & BOUNCE (Max 30) - Mencegah entry di pucuk/dasar
   // BUY: Candle sebelumnya koreksi menyentuh area MA, candle saat ini memantul (Bullish)
   bool pullback_buy = (m5[1].low <= ma20_0 || m5[1].low <= ma50_0); 
   bool bounce_buy = (m5[0].close > ma20_0 && m5[0].close > m5[0].open); 

   // SELL: Candle sebelumnya koreksi naik ke area MA, candle saat ini memantul turun (Bearish)
   bool pullback_sell = (m5[1].high >= ma20_0 || m5[1].high >= ma50_0);
   bool bounce_sell = (m5[0].close < ma20_0 && m5[0].close < m5[0].open);

   if((dir > 0 && pullback_buy && bounce_buy) || (dir < 0 && pullback_sell && bounce_sell)) score += 30;

   // 2. MOMENTUM RSI (Max 25)
   double rsi0;
   if(!RSISimple(m5, 14, 0, rsi0)) return 0;
   // RSI tidak boleh overbought/oversold ekstrem saat entry trend
   bool rsi_ok = (dir > 0) ? (rsi0 >= 40.0 && rsi0 <= 70.0) : (rsi0 >= 30.0 && rsi0 <= 60.0);
   if(rsi_ok) score += 25;

   // 3. VALIDASI VOLUME & A/D (Max 25)
   double ad_h1[];
   if(!BuildAD(h1, ad_h1)) return 0;
   double ad_slope_h1 = 0.0;
   if(ArraySize(ad_h1) >= 6) {
      double sum_diff = 0.0;
      for(int i = 0; i < 5; i++) sum_diff += (ad_h1[i] - ad_h1[i + 1]);
      ad_slope_h1 = sum_diff / 5.0;
   }

   double vol_avg = 0.0;
   bool vol_confirmed = false;
   if(VolumeAverage(m5, 20, 0, vol_avg)) vol_confirmed = ((double)m5[0].tick_volume > vol_avg);

   if((dir > 0 && ad_slope_h1 >= 0.0 && vol_confirmed) || (dir < 0 && ad_slope_h1 <= 0.0 && vol_confirmed)) score += 25;

   // 4. CANDLE MOMENTUM M5 (Max 20)
   double range = m5[0].high - m5[0].low + 1e-10;
   double body_ratio = MathAbs(m5[0].close - m5[0].open) / range;
   bool bullish_candle = (m5[0].close > m5[0].open);
   
   double m5_ma10;
   SMA(m5, 10, 0, m5_ma10);
   bool m5_momentum_up = (m5[0].close > m5_ma10);
   bool m5_momentum_down = (m5[0].close < m5_ma10);

   if((dir > 0 && bullish_candle && body_ratio > 0.4 && m5_momentum_up) || 
      (dir < 0 && !bullish_candle && body_ratio > 0.4 && m5_momentum_down)) 
   {
      score += 20;
   }

   return score;
}

bool ExecuteTrade(const string symbol, const int dir, double entry, double sl, double tp)
{
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return false;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(point <= 0.0) return false;

   if((tick.ask - tick.bid) > GetMaxSpreadPoints(symbol) * point)
      Log(StringFormat("[WARNING] %s: spread sangat lebar.", symbol));

   double lot = GetSmartLot(symbol, MathAbs(entry - sl));
   Log(StringFormat("[LOT INFO] %s | Risiko: %.2f%% | Lot: %.2f", symbol, InpRiskPercent, lot));

   ENUM_ORDER_TYPE order_type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin_required = 0.0;
   if(!OrderCalcMargin(order_type, symbol, lot, entry, margin_required)) return false;
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required + InpMarginBuffer) return false;

   entry = NormalizeDouble(entry, digits); sl = NormalizeDouble(sl, digits); tp = NormalizeDouble(tp, digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(symbol);

   bool ok = (dir > 0) ? trade.Buy(lot, symbol, entry, sl, tp, "TrendPullback_BUY") : trade.Sell(lot, symbol, entry, sl, tp, "TrendPullback_SELL");
   uint retcode = trade.ResultRetcode();

   if(ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
   {
      Log(StringFormat("[SUCCESS] %s %s @ %s | SL:%s TP:%s", symbol, (dir > 0 ? "BUY" : "SELL"), DoubleToString(entry, digits), DoubleToString(sl, digits), DoubleToString(tp, digits)));
      return true;
   }
   Log(StringFormat("[ERROR] %s: retcode=%d, comment=%s", symbol, retcode, trade.ResultComment()));
   return false;
}

void ProcessSymbol(const string symbol, const int idx)
{
   Log(StringFormat("=== %s | Cek %s ===", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), symbol));
   if(HasOpenPosition(symbol)) return;
   if(idx >= 0 && TimeCurrent() - g_last_entry[idx] < InpCooldownSeconds) return;

   MqlRates h1[], m15[], m5[];
   if(!GetRates(symbol, InpTFMacro, InpBars, h1)) return;
   if(!GetRates(symbol, InpTFMid, InpBars, m15)) return;
   if(!GetRates(symbol, InpTFEntry, InpBars, m5)) return;

   int trend = CheckH1Trend(h1);
   if(trend == 0) { Log(StringFormat("[SKIP] %s: H1 Ranging.", symbol)); return; }

   double m15_ma20, m15_ma50;
   if(!SMA(m15, 20, 0, m15_ma20) || !SMA(m15, 50, 0, m15_ma50)) return;
   int m15_bias = 0;
   if(m15[0].close > m15_ma20 && m15_ma20 > m15_ma50) m15_bias = 1;
   if(m15[0].close < m15_ma20 && m15_ma20 < m15_ma50) m15_bias = -1;
   
   if(trend != m15_bias) { 
      Log(StringFormat("[SKIP] %s: H1 (%d) dan M15 (%d) tidak sinkron.", symbol, trend, m15_bias)); 
      return; 
   }

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return;

   int signal = 0; int score = 0; double entry = 0.0;
   if(trend > 0) {
      score = CalculateEntryScore(m5, m15, h1, 1);
      Log(StringFormat("Score BUY %s: %d (Threshold: %d)", symbol, score, InpEntryScoreThreshold));
      if(score >= InpEntryScoreThreshold) { signal = 1; entry = tick.ask; }
   } else {
      score = CalculateEntryScore(m5, m15, h1, -1);
      Log(StringFormat("Score SELL %s: %d (Threshold: %d)", symbol, score, InpEntryScoreThreshold));
      if(score >= InpEntryScoreThreshold) { signal = -1; entry = tick.bid; }
   }

   if(signal == 0 || entry <= 0.0) return;

   // >>> PERBAIKAN RASIO RISK:REWARD MENGGUNAKAN ATR (1:2) <<<
   double atr_m15 = SimpleATR(m15, 14, 0);
   double sl_distance = 0.0, tp_distance = 0.0;
   
   if(atr_m15 > 0) {
      sl_distance = atr_m15 * 11; // SL aman dari noise, 1.5x ATR
      tp_distance = atr_m15 * 3.0; // TP 2x lebih besar dari SL (Risk:Reward 1:2)
   } else {
      sl_distance = 50.0 * SymbolInfoDouble(symbol, SYMBOL_POINT); // Fallback
      tp_distance = sl_distance * 5.0;
   }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS); 
   double min_stop = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   if(min_stop <= 0) min_stop = 10 * point;

   sl_distance = MathMax(sl_distance, min_stop);
   tp_distance = MathMax(tp_distance, min_stop);

   double sl = 0.0, tp = 0.0;
   if(signal > 0) { sl = entry - sl_distance; tp = entry + tp_distance; }
   else           { sl = entry + sl_distance; tp = entry - tp_distance; }

   Log(StringFormat("[FINAL SL/TP] %s | %s | Entry: %s | SL: %s | TP: %s (RR 1:2)", symbol, (signal > 0 ? "BUY" : "SELL"), DoubleToString(entry, digits), DoubleToString(sl, digits), DoubleToString(tp, digits)));

   if(ExecuteTrade(symbol, signal, entry, sl, tp) && idx >= 0) g_last_entry[idx] = TimeCurrent();
}

// >>> DIPERBAIKI: Menambahkan Auto-Breakeven (Amankan Profit) + Smart Exit <<<
void ManageSmartExit()
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
      
      // >>> PERBAIKAN ERROR: Ganti POSITION_PRICE menjadi POSITION_PRICE_OPEN <<<
      double entry_price = PositionGetDouble(POSITION_PRICE_OPEN); 
      // --------------------------------------------------------------
      
      double current_sl = PositionGetDouble(POSITION_SL);
      double current_tp = PositionGetDouble(POSITION_TP);
      double profit = PositionGetDouble(POSITION_PROFIT);
      
      MqlTick tick;
      if(!SymbolInfoTick(symbol, tick)) continue;

      MqlRates m15_rates[];
      if(!GetRates(symbol, InpTFMid, 20, m15_rates)) continue;
      double atr_m15 = SimpleATR(m15_rates, 14, 0);
      if(atr_m15 <= 0) continue;

      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double spread = (double)SymbolInfoInteger(symbol, SYMBOL_SPREAD) * point;
      double be_trigger = atr_m15 * 1.2; // Trigger BE saat profit mencapai 1.2 ATR

      // --- 1. BREAKEVEN LOGIC (Amankan Modal) ---
      bool modified = false;
      if(pos_type == POSITION_TYPE_BUY) {
         if(tick.bid - entry_price >= be_trigger && current_sl < entry_price) {
            double new_sl = NormalizeDouble(entry_price + spread + 5*point, digits);
            if(trade.PositionModify(ticket, new_sl, current_tp)) modified = true;
         }
      } else if(pos_type == POSITION_TYPE_SELL) {
         if(entry_price - tick.ask >= be_trigger && (current_sl > entry_price || current_sl == 0)) {
            double new_sl = NormalizeDouble(entry_price - spread - 5*point, digits);
            if(trade.PositionModify(ticket, new_sl, current_tp)) modified = true;
         }
      }
      if(modified) Log(StringFormat("[BREAKEVEN] %s | SL diamankan ke titik Entry. Profit terkunci.", symbol));

      // --- 2. SMART EXIT LOGIC (Tutup jika trend M5 patah) ---
      MqlRates m5[];
      if(!GetRates(symbol, InpTFEntry, 60, m5)) continue;
      double ma20, ma50;
      if(!SMA(m5, 20, 0, ma20) || !SMA(m5, 50, 0, ma50)) continue;
      
      double close0 = m5[0].close;
      bool m5_bullish = (close0 > ma20 && ma20 > ma50);
      bool m5_bearish = (close0 < ma20 && ma20 < ma50);
      
      bool should_close = false;
      string reason = "";
      
      if(pos_type == POSITION_TYPE_BUY && m5_bearish) { should_close = true; reason = "M5 Trend Berubah jadi BEARISH"; }
      else if(pos_type == POSITION_TYPE_SELL && m5_bullish) { should_close = true; reason = "M5 Trend Berubah jadi BULLISH"; }
      
      if(should_close)
      {
         if(trade.PositionClose(ticket)) Log(StringFormat("[SMART EXIT] %s | Posisi ditutup karena %s. Profit: %.2f", symbol, reason, profit));
         else Log(StringFormat("[SMART EXIT ERROR] %s | Gagal menutup posisi. Retcode: %d", symbol, trade.ResultRetcode()));
      }
   }
}

void RunChecks()
{
   static datetime last_check = 0;
   if(TimeCurrent() - last_check < InpCheckIntervalSeconds) return;
   last_check = TimeCurrent();
   ManageSmartExit();
   if(GetDailyLoss() >= InpMaxDailyLoss) return;
   for(int i = 0; i < ArraySize(g_symbols); i++) ProcessSymbol(g_symbols[i], i);
}

int OnInit()
{
   if(InpCheckIntervalSeconds <= 0 || ParseSymbols(InpSymbols) <= 0) return INIT_PARAMETERS_INCORRECT;
   ArrayResize(g_last_entry, ArraySize(g_symbols)); ArrayInitialize(g_last_entry, 0);
   for(int i = 0; i < ArraySize(g_symbols); i++) SymbolSelect(g_symbols[i], true);
   trade.SetExpertMagicNumber(InpMagic); trade.SetDeviationInPoints(InpSlippagePoints);
   if(!DiagnoseAccount()) return INIT_FAILED;
   EventSetTimer(1);
   Print("Triple Timeframe Bot V5.0 running... (ATR Dynamic SL/TP, Pullback & Breakeven)");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { EventKillTimer(); }
void OnTick() { RunChecks(); }
void OnTimer() { RunChecks(); }