//+------------------------------------------------------------------+
//|       ConfluenceBot_M15_New_Bar_Entry_&_Candlestick_Patterns.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Converted from Python"
#property version   "2.10"

#include <Trade\Trade.mqh>

input group "General"
input string InpSymbols                 = "BTCUSD.vx";   
input int    InpCheckIntervalSeconds    = 15;
input int    InpEntryScoreThreshold     = 25;
input double InpMaxDailyLoss            = 500.0;    // UBAH: Dari 500 ke 15.0
input long   InpMagic                   = 20260809;
input int    InpCooldownSeconds         = 900;           
input bool   InpPrintLogs               = true;

input group "Trade Settings"
input double InpDefaultLot              = 0.01;
input double InpRiskPercent             = 15.0; //15.0;
input int    InpDefaultMaxSpreadPoints  = 20;
input double InpDefaultSLDistance       = 5.0;     
input double InpBTCSLDistance           = 150.0;   
input int    InpBTCMaxSpreadPoints      = 10000;
input double InpMarginBuffer            = 15; //15.0;
input int    InpSlippagePoints          = 20;

input group "SL/TP Multipliers"
input double InpSLMultiplier            = 13; //12.0;   // Jarak SL = actual_sl_distance * multiplier
input double InpTPMultiplier            = 20; //20.0;   // Jarak TP = actual_sl_distance * multiplier

input group "Data Settings"
input ENUM_TIMEFRAMES InpTFEntry        = PERIOD_M15;
input ENUM_TIMEFRAMES InpTFTrend        = PERIOD_H1;
input int    InpBars                    = 500;

input group "Candlestick Patterns (M15)"
input bool   InpUseMarubozu           = true;
input bool   InpUseEngulfing          = true;
input bool   InpUseMorningEveningStar = true;
input bool   InpUseDoji               = false;
input bool   InpRequirePattern        = false;

CTrade trade;

string   g_symbols[];
datetime g_last_entry[];
datetime g_last_m15_bar_time[];

void Log(const string message)
{
   if(InpPrintLogs)
      Print(message);
}

int ParseSymbols(const string text)
{
   ArrayResize(g_symbols, 0);
   string parts[];
   int n = StringSplit(text, ',', parts);
   for(int i = 0; i < n; i++)
   {
      StringTrimLeft(parts[i]);
      StringTrimRight(parts[i]);
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
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) { Print("Expert/EA trading tidak diizinkan."); return false; }

   Print("Login   : ", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("Server  : ", AccountInfoString(ACCOUNT_SERVER));
   Print("Name    : ", AccountInfoString(ACCOUNT_NAME));
   Print("Balance : ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("Equity  : ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("Semua izin trading terpenuhi. Bot siap berjalan.");
   Print("=======================================");
   return true;
}

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

int GetMaxSpreadPoints(const string symbol) 
{ 
   return (StringFind(symbol, "BTCUSD") >= 0) ? InpBTCMaxSpreadPoints : InpDefaultMaxSpreadPoints; 
}

double GetSLDistance(const string symbol) 
{ 
   return (StringFind(symbol, "BTCUSD") >= 0) ? InpBTCSLDistance : InpDefaultSLDistance; 
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
   double mean = 0.0; if(!SMA(rates, period, shift, mean)) return false;
   double sum_sq = 0.0;
   for(int i = shift; i < shift + period; i++) { double d = rates[i].close - mean; sum_sq += d * d; }
   value = MathSqrt(sum_sq / (period - 1));
   return true;
}

bool Bollinger(const MqlRates &rates[], int period, double mult, int shift, double &upper, double &middle, double &lower)
{
   double std = 0.0;
   if(!SMA(rates, period, shift, middle)) return false;
   if(!StdDevClose(rates, period, shift, std)) return false;
   upper = middle + mult * std; lower = middle - mult * std;
   return true;
}

bool RSISimple(const MqlRates &rates[], int period, int shift, double &value)
{
   int total = ArraySize(rates);
   if(period <= 0 || shift < 0 || shift + period + 1 > total) return false;
   double gain = 0.0, loss = 0.0;
   for(int i = shift; i < shift + period; i++) {
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
   int total = ArraySize(rates); if(total <= 0) return false;
   ArraySetAsSeries(ad, false); ArrayResize(ad, total);
   double cum = 0.0;
   for(int i = total - 1; i >= 0; i--) {
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

bool MinClose(const MqlRates &rates[], int count, int start_shift, double &value) {
   int total = ArraySize(rates); if(count <= 0 || start_shift < 0 || start_shift + count > total) return false;
   value = rates[start_shift].close;
   for(int i = start_shift + 1; i < start_shift + count; i++) value = MathMin(value, rates[i].close);
   return true;
}

bool MaxClose(const MqlRates &rates[], int count, int start_shift, double &value) {
   int total = ArraySize(rates); if(count <= 0 || start_shift < 0 || start_shift + count > total) return false;
   value = rates[start_shift].close;
   for(int i = start_shift + 1; i < start_shift + count; i++) value = MathMax(value, rates[i].close);
   return true;
}

bool MinDouble(const double &arr[], int count, int start_shift, double &value) {
   int total = ArraySize(arr); if(count <= 0 || start_shift < 0 || start_shift + count > total) return false;
   value = arr[start_shift];
   for(int i = start_shift + 1; i < start_shift + count; i++) value = MathMin(value, arr[i]);
   return true;
}

bool MaxDouble(const double &arr[], int count, int start_shift, double &value) {
   int total = ArraySize(arr); if(count <= 0 || start_shift < 0 || start_shift + count > total) return false;
   value = arr[start_shift];
   for(int i = start_shift + 1; i < start_shift + count; i++) value = MathMax(value, arr[i]);
   return true;
}

int CheckH1Trend(const MqlRates &h1[])
{
   double ma50, ma200;
   if(!SMA(h1, 50, 1, ma50)) return 0;
   if(!SMA(h1, 200, 1, ma200)) return 0;
   double close1 = h1[1].close;
   if(close1 > ma50 && ma50 > ma200) return 1;
   if(close1 < ma50 && ma50 < ma200) return -1;
   return 0;
}

double GetBody(const MqlRates &rates[], int shift) { return MathAbs(rates[shift].close - rates[shift].open); }
double GetRange(const MqlRates &rates[], int shift) { return rates[shift].high - rates[shift].low + 1e-10; }
double GetUpperShadow(const MqlRates &rates[], int shift) { return (rates[shift].close > rates[shift].open) ? rates[shift].high - rates[shift].close : rates[shift].high - rates[shift].open; }
double GetLowerShadow(const MqlRates &rates[], int shift) { return (rates[shift].close > rates[shift].open) ? rates[shift].open - rates[shift].low : rates[shift].close - rates[shift].low; }

bool IsBullishMarubozu(const MqlRates &rates[], int shift) {
   if(rates[shift].close <= rates[shift].open) return false;
   double range = GetRange(rates, shift); if(range == 0) return false;
   return (GetBody(rates, shift) / range > 0.90) && (GetUpperShadow(rates, shift) / range < 0.05) && (GetLowerShadow(rates, shift) / range < 0.05);
}

bool IsBearishMarubozu(const MqlRates &rates[], int shift) {
   if(rates[shift].close >= rates[shift].open) return false;
   double range = GetRange(rates, shift); if(range == 0) return false;
   return (GetBody(rates, shift) / range > 0.90) && (GetUpperShadow(rates, shift) / range < 0.05) && (GetLowerShadow(rates, shift) / range < 0.05);
}

bool IsBullishEngulfing(const MqlRates &rates[], int shift) {
   if(rates[shift].close <= rates[shift].open) return false;
   if(rates[shift+1].close >= rates[shift+1].open) return false;
   return (rates[shift].close > rates[shift+1].open) && (rates[shift].open < rates[shift+1].close) && (GetBody(rates, shift) > GetBody(rates, shift+1));
}

bool IsBearishEngulfing(const MqlRates &rates[], int shift) {
   if(rates[shift].close >= rates[shift].open) return false;
   if(rates[shift+1].close <= rates[shift+1].open) return false;
   return (rates[shift].close < rates[shift+1].open) && (rates[shift].open > rates[shift+1].close) && (GetBody(rates, shift) > GetBody(rates, shift+1));
}

bool IsDoji(const MqlRates &rates[], int shift) {
   double range = GetRange(rates, shift); if(range == 0) return false;
   return (GetBody(rates, shift) / range) < 0.15;
}

bool IsMorningStar(const MqlRates &rates[], int shift) {
   if(shift + 2 >= ArraySize(rates)) return false;
   bool first_bearish = (rates[shift+2].close < rates[shift+2].open);
   if(!first_bearish || GetBody(rates, shift+2)/GetRange(rates, shift+2) < 0.5) return false;
   bool second_small = IsDoji(rates, shift+1) || (GetBody(rates, shift+1)/GetRange(rates, shift+1) < 0.3);
   if(!second_small) return false;
   bool third_bullish = (rates[shift].close > rates[shift].open);
   if(!third_bullish || GetBody(rates, shift)/GetRange(rates, shift) < 0.5) return false;
   double midpoint1 = (rates[shift+2].open + rates[shift+2].close) / 2.0;
   return (rates[shift].close > midpoint1);
}

bool IsEveningStar(const MqlRates &rates[], int shift) {
   if(shift + 2 >= ArraySize(rates)) return false;
   bool first_bullish = (rates[shift+2].close > rates[shift+2].open);
   if(!first_bullish || GetBody(rates, shift+2)/GetRange(rates, shift+2) < 0.5) return false;
   bool second_small = IsDoji(rates, shift+1) || (GetBody(rates, shift+1)/GetRange(rates, shift+1) < 0.3);
   if(!second_small) return false;
   bool third_bearish = (rates[shift].close < rates[shift].open);
   if(!third_bearish || GetBody(rates, shift)/GetRange(rates, shift) < 0.5) return false;
   double midpoint1 = (rates[shift+2].open + rates[shift+2].close) / 2.0;
   return (rates[shift].close < midpoint1);
}

int CalculateEntryScore(const MqlRates &m15[], const MqlRates &h1[], const int dir)
{
   if(ArraySize(m15) < 60 || ArraySize(h1) < 210) return 0;

   int score = 0;
   double close1 = m15[1].close;

   double ma20_1, ma50_1;
   if(!SMA(m15, 20, 1, ma20_1)) return 0;
   if(!SMA(m15, 50, 1, ma50_1)) return 0;

   double bb_upper_1, bb_middle_1, bb_lower_1;
   if(!Bollinger(m15, 20, 2.0, 1, bb_upper_1, bb_middle_1, bb_lower_1)) return 0;

   bool in_ma_zone = false, touch_bb = false;
   if(dir > 0) {
      in_ma_zone = (ma50_1 <= close1 && close1 <= ma20_1);
      touch_bb   = (m15[1].low <= bb_lower_1);
   } else {
      in_ma_zone = (ma20_1 <= close1 && close1 <= ma50_1);
      touch_bb   = (m15[1].high >= bb_upper_1);
   }
   if(in_ma_zone || touch_bb) score += 30;

   double rsi1; if(!RSISimple(m15, 14, 1, rsi1)) return 0;
   bool rsi_ok = (dir > 0) ? (rsi1 >= 30.0 && rsi1 <= 65.0) : (rsi1 >= 35.0 && rsi1 <= 70.0);
   
   double ad_m15[]; if(!BuildAD(m15, ad_m15)) return 0;
   bool divergence = false;
   if(dir > 0) {
      double min_close_prev, min_ad_prev;
      if(MinClose(m15, 9, 2, min_close_prev) && MinDouble(ad_m15, 9, 2, min_ad_prev))
         divergence = (close1 < min_close_prev && ad_m15[1] > min_ad_prev);
   } else {
      double max_close_prev, max_ad_prev;
      if(MaxClose(m15, 9, 2, max_close_prev) && MaxDouble(ad_m15, 9, 2, max_ad_prev))
         divergence = (close1 > max_close_prev && ad_m15[1] < max_ad_prev);
   }
   if((dir > 0 && (rsi_ok || divergence)) || (dir < 0 && (rsi_ok || divergence))) score += 25;

   double ad_h1[]; if(!BuildAD(h1, ad_h1)) return 0;
   double ad_slope_h1 = 0.0;
   if(ArraySize(ad_h1) >= 6) {
      double sum_diff = 0.0;
      for(int i = 1; i < 6; i++) sum_diff += (ad_h1[i] - ad_h1[i + 1]);
      ad_slope_h1 = sum_diff / 5.0;
   }
   double vol_avg = 0.0; bool vol_confirmed = false;
   if(VolumeAverage(m15, 20, 1, vol_avg)) vol_confirmed = ((double)m15[1].tick_volume > vol_avg);
   if((dir > 0 && ad_slope_h1 >= 0.0 && vol_confirmed) || (dir < 0 && ad_slope_h1 <= 0.0 && vol_confirmed)) score += 25;

   bool pattern_triggered = false;
   string pattern_name = "";
   
   if(dir > 0) {
      if(InpUseMarubozu && IsBullishMarubozu(m15, 1)) { pattern_triggered = true; pattern_name = "Bullish Marubozu"; }
      else if(InpUseEngulfing && IsBullishEngulfing(m15, 1)) { pattern_triggered = true; pattern_name = "Bullish Engulfing"; }
      else if(InpUseMorningEveningStar && IsMorningStar(m15, 1)) { pattern_triggered = true; pattern_name = "Morning Star"; }
      else if(InpUseDoji && IsDoji(m15, 1)) { pattern_triggered = true; pattern_name = "Doji"; }
   } else {
      if(InpUseMarubozu && IsBearishMarubozu(m15, 1)) { pattern_triggered = true; pattern_name = "Bearish Marubozu"; }
      else if(InpUseEngulfing && IsBearishEngulfing(m15, 1)) { pattern_triggered = true; pattern_name = "Bearish Engulfing"; }
      else if(InpUseMorningEveningStar && IsEveningStar(m15, 1)) { pattern_triggered = true; pattern_name = "Evening Star"; }
      else if(InpUseDoji && IsDoji(m15, 1)) { pattern_triggered = true; pattern_name = "Doji"; }
   }

   if(InpRequirePattern && !pattern_triggered) return 0; 

   if(pattern_triggered) {
      score += 30;
      Print(StringFormat("[CANDLE PATTERN] %s terdeteksi pada %s (Shift 1)", pattern_name, EnumToString(InpTFEntry)));
   } else {
      double range = GetRange(m15, 1);
      double body_ratio = GetBody(m15, 1) / range;
      bool bullish_candle = (m15[1].close > m15[1].open);
      if((dir > 0 && bullish_candle && body_ratio > 0.3) || (dir < 0 && !bullish_candle && body_ratio > 0.3)) score += 20;
   }

   return score;
}

//+------------------------------------------------------------------+
//| >>> PERBAIKAN UTAMA <<<                                          |
//| AdjustStops sekarang menggunakan acuan harga entry yang segar    |
//| dan memperhitungkan stop level broker dengan benar.              |
//+------------------------------------------------------------------+
void AdjustStops(const string symbol, const int dir, const double entry, double &sl, double &tp)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop_distance = (double)stops_level * point;
   
   // Jika broker tidak memberikan stop level, gunakan buffer aman 10 point
   if(min_stop_distance <= 0.0)
      min_stop_distance = 10.0 * point;

   if(dir > 0) // BUY
   {
      if(entry - sl < min_stop_distance)
         sl = entry - min_stop_distance;
      if(tp - entry < min_stop_distance)
         tp = entry + min_stop_distance;
   }
   else // SELL
   {
      if(sl - entry < min_stop_distance)
         sl = entry + min_stop_distance;
      if(entry - tp < min_stop_distance)
         tp = entry - min_stop_distance;
   }
}

//+------------------------------------------------------------------+
//| >>> PERBAIKAN UTAMA <<<                                          |
//| ExecuteTrade sekarang menerima hanya symbol & dir.               |
//| Semua perhitungan entry, SL, TP, lot dilakukan di sini           |
//| menggunakan tick yang SAMA dan TERBARU.                          |
//+------------------------------------------------------------------+
bool ExecuteTrade(const string symbol, const int dir)
{
   // 1. Ambil tick TERBARU tepat sebelum eksekusi
   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
   {
      Log(StringFormat("[ERROR] %s: gagal ambil tick terbaru.", symbol));
      return false;
   }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   
   if(point <= 0.0)
   {
      Log(StringFormat("[ERROR] %s: point tidak valid.", symbol));
      return false;
   }

   // 2. Tentukan harga entry berdasarkan arah order dari tick segar
   double entry = (dir > 0) ? tick.ask : tick.bid;
   
   if(entry <= 0.0)
   {
      Log(StringFormat("[ERROR] %s: harga entry tidak valid (ask/bid = 0).", symbol));
      return false;
   }

   // 3. Hitung spread dan jarak SL/TP yang aman
   double spread = tick.ask - tick.bid;
   double sl_distance = GetSLDistance(symbol);
   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop = (stops_level > 0 ? (double)stops_level * point : 10.0 * point);
   
   // Jarak minimal harus lebih besar dari spread + stop level + buffer
   double actual_sl_distance = MathMax(sl_distance, spread + min_stop + 10.0 * point);

   double sl = 0.0;
   double tp = 0.0;

   if(dir > 0) // BUY
   {
      sl = entry - (actual_sl_distance * InpSLMultiplier);
      tp = entry + (actual_sl_distance * InpTPMultiplier);
   }
   else // SELL
   {
      sl = entry + (actual_sl_distance * InpSLMultiplier);
      tp = entry - (actual_sl_distance * InpTPMultiplier);
   }

   // 4. Validasi awal sebelum normalisasi
   if(sl <= 0.0 || tp <= 0.0)
   {
      Log(StringFormat("[ERROR] %s: SL atau TP <= 0 sebelum adjust. SL=%.5f TP=%.5f", symbol, sl, tp));
      return false;
   }

   // 5. Sesuaikan dengan stop level broker
   AdjustStops(symbol, dir, entry, sl, tp);

   // 6. Normalisasi harga
   entry = NormalizeDouble(entry, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   // 7. Hitung lot berdasarkan jarak SL final
   double sl_distance_price = MathAbs(entry - sl);
   double lot = GetSmartLot(symbol, sl_distance_price);
   
   Log(StringFormat("[EXECUTION DEBUG] %s | Arah: %s | Entry: %s | SL: %s | TP: %s | Lot: %.2f | Spread: %.1f pts | SL Dist: %.5f",
                    symbol,
                    (dir > 0 ? "BUY" : "SELL"),
                    DoubleToString(entry, digits),
                    DoubleToString(sl, digits),
                    DoubleToString(tp, digits),
                    lot,
                    spread / point,
                    sl_distance_price));

   // 8. Cek margin
   ENUM_ORDER_TYPE order_type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double margin_required = 0.0;
   if(!OrderCalcMargin(order_type, symbol, lot, entry, margin_required))
   {
      Log(StringFormat("[ERROR] %s: OrderCalcMargin gagal.", symbol));
      return false;
   }

   double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free_margin < margin_required + InpMarginBuffer)
   {
      Log(StringFormat("[SKIP] %s: free margin kurang. Free=%.2f, Required=%.2f", symbol, free_margin, margin_required));
      return false;
   }

   // 9. Setting trade object
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(symbol);

   // 10. Kirim order dengan harga eksplisit yang sudah segar & ternormalisasi
   bool ok = false;
   if(dir > 0)
      ok = trade.Buy(lot, symbol, entry, sl, tp, "Confluence_BUY");
   else
      ok = trade.Sell(lot, symbol, entry, sl, tp, "Confluence_SELL");

   uint retcode = trade.ResultRetcode();

   if(ok && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_DONE_PARTIAL || retcode == TRADE_RETCODE_PLACED))
   {
      Log(StringFormat("[SUCCESS] %s %s @ %s | SL:%s TP:%s | Retcode:%d",
                       symbol,
                       (dir > 0 ? "BUY" : "SELL"),
                       DoubleToString(entry, digits),
                       DoubleToString(sl, digits),
                       DoubleToString(tp, digits),
                       retcode));
      return true;
   }

   Log(StringFormat("[ERROR] %s: retcode=%d, comment=%s", symbol, retcode, trade.ResultComment()));
   return false;
}

//+------------------------------------------------------------------+
//| >>> PERBAIKAN <<<                                                |
//| ProcessSymbol sekarang hanya mengirim signal ke ExecuteTrade.    |
//| Tidak ada lagi perhitungan SL/TP di sini.                        |
//+------------------------------------------------------------------+
void ProcessSymbol(const string symbol, const int idx)
{
   Log(StringFormat("=== %s | Cek %s ===", TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), symbol));

   if(HasOpenPosition(symbol))
   {
      Log(StringFormat("[SKIP] %s: masih ada posisi terbuka.", symbol));
      return;
   }

   if(idx >= 0 && TimeCurrent() - g_last_entry[idx] < InpCooldownSeconds)
   {
      Log(StringFormat("[SKIP] %s: cooldown aktif.", symbol));
      return;
   }

   MqlRates m15[], h1[];
   if(!GetRates(symbol, InpTFEntry, InpBars, m15))
   {
      Log(StringFormat("[SKIP] %s: data M15 tidak cukup.", symbol));
      return;
   }

   if(!GetRates(symbol, InpTFTrend, InpBars, h1))
   {
      Log(StringFormat("[SKIP] %s: data H1 tidak cukup.", symbol));
      return;
   }

   // LOGIKA ENTRY PER CANDLE M15 (NEW BAR)
   if(m15[0].time == g_last_m15_bar_time[idx])
      return;
      
   g_last_m15_bar_time[idx] = m15[0].time;

   int trend = CheckH1Trend(h1);
   if(trend == 1) Log(StringFormat("Trend H1 %s: BULLISH", symbol));
   else if(trend == -1) Log(StringFormat("Trend H1 %s: BEARISH", symbol));
   else Log(StringFormat("Trend H1 %s: RANGING", symbol));

   if(trend == 0)
   {
      Log(StringFormat("[SKIP] %s: market ranging.", symbol));
      return;
   }
   
   double m15_ma20, m15_ma50;
   if(!SMA(m15, 20, 1, m15_ma20) || !SMA(m15, 50, 1, m15_ma50))
   {
      Log(StringFormat("[SKIP] %s: Gagal hitung MA M15.", symbol));
      return;
   }
   
   bool m15_trend_ok = false;
   if(trend > 0 && m15[1].close > m15_ma20 && m15_ma20 > m15_ma50) m15_trend_ok = true;
   if(trend < 0 && m15[1].close < m15_ma20 && m15_ma20 < m15_ma50) m15_trend_ok = true;
   
   if(!m15_trend_ok)
   {
      Log(StringFormat("[SKIP] %s: Trend M15 belum searah dengan H1.", symbol));
      return;
   }

   int signal = 0;
   int score = 0;

   if(trend > 0)
   {
      score = CalculateEntryScore(m15, h1, 1);
      Log(StringFormat("Score BUY %s: %d (Threshold: %d)", symbol, score, InpEntryScoreThreshold));
      if(score >= InpEntryScoreThreshold)
         signal = 1;
   }
   else
   {
      score = CalculateEntryScore(m15, h1, -1);
      Log(StringFormat("Score SELL %s: %d (Threshold: %d)", symbol, score, InpEntryScoreThreshold));
      if(score >= InpEntryScoreThreshold)
         signal = -1;
   }

   if(signal == 0)
   {
      Log(StringFormat("No signal untuk %s (Score %d < Threshold %d)", symbol, score, InpEntryScoreThreshold));
      return;
   }

   // Eksekusi order sepenuhnya ditangani oleh ExecuteTrade
   bool success = ExecuteTrade(symbol, signal);

   if(success && idx >= 0)
      g_last_entry[idx] = TimeCurrent();
}

void ManageSmartExit()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagic) continue;
      
      bool is_our_symbol = false;
      for(int s = 0; s < ArraySize(g_symbols); s++)
         if(g_symbols[s] == symbol) { is_our_symbol = true; break; }
      if(!is_our_symbol) continue;

      long pos_type = PositionGetInteger(POSITION_TYPE);
      double profit = PositionGetDouble(POSITION_PROFIT);
      
      MqlRates m15[];
      if(!GetRates(symbol, InpTFEntry, 60, m15)) continue;
      
      double ma20, ma50;
      if(!SMA(m15, 20, 0, ma20) || !SMA(m15, 50, 0, ma50)) continue;
      
      double close0 = m15[0].close;
      bool m15_bullish = (close0 > ma20 && ma20 > ma50);
      bool m15_bearish = (close0 < ma20 && ma20 < ma50);
      
      bool should_close = false;
      string reason = "";
      
      if(pos_type == POSITION_TYPE_BUY && m15_bearish) 
      {
         should_close = true;
         reason = "M15 Trend Berubah jadi BEARISH";
      }
      else if(pos_type == POSITION_TYPE_SELL && m15_bullish) 
      {
         should_close = true;
         reason = "M15 Trend Berubah jadi BULLISH";
      }
      
      if(should_close)
      {
         if(trade.PositionClose(ticket))
            Log(StringFormat("[SMART EXIT] %s | Posisi ditutup karena %s. Profit: %.2f", symbol, reason, profit));
         else
            Log(StringFormat("[SMART EXIT ERROR] %s | Gagal menutup posisi. Retcode: %d", symbol, trade.ResultRetcode()));
      }
   }
}

void RunChecks()
{
   static datetime last_check = 0;
   if(TimeCurrent() - last_check < InpCheckIntervalSeconds) return;
   last_check = TimeCurrent();
   
   ManageSmartExit();

   double daily_loss = GetDailyLoss();
   if(daily_loss >= InpMaxDailyLoss)
   {
      Log(StringFormat("DAILY LOSS LIMIT: %.2f. Bot istirahat.", daily_loss));
      return;
   }

   for(int i = 0; i < ArraySize(g_symbols); i++)
      ProcessSymbol(g_symbols[i], i);
}

int OnInit()
{
   if(InpCheckIntervalSeconds <= 0)
   {
      Print("InpCheckIntervalSeconds harus lebih dari 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ParseSymbols(InpSymbols) <= 0)
   {
      Print("Symbol list kosong.");
      return INIT_PARAMETERS_INCORRECT;
   }

   ArrayResize(g_last_entry, ArraySize(g_symbols));
   ArrayInitialize(g_last_entry, 0);
   
   ArrayResize(g_last_m15_bar_time, ArraySize(g_symbols));
   ArrayInitialize(g_last_m15_bar_time, 0);

   for(int i = 0; i < ArraySize(g_symbols); i++)
      if(!SymbolSelect(g_symbols[i], true))
         Print("Warning: SymbolSelect gagal untuk ", g_symbols[i]);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(!DiagnoseAccount())
      return INIT_FAILED;

   EventSetTimer(1);
   Print("Bot running...");
   Print("Symbols: ", InpSymbols);
   Print("Interval cek: ", InpCheckIntervalSeconds, " detik");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTick()
{
   RunChecks();
}

void OnTimer()
{
   RunChecks();
}