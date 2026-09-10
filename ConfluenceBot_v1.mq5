//+------------------------------------------------------------------+
//|                                              ConfluenceBot.mq5   |
//|                      M15 H1 confluence bot btcusd   |
//+------------------------------------------------------------------+
#property copyright "Converted from Python"
#property version   "1.00"

#include <Trade\Trade.mqh>

input group "General"
input string InpSymbols                 = "BTCUSD.vx";   
input int    InpCheckIntervalSeconds    = 15;
input int    InpEntryScoreThreshold     = 25;      // UBAH: Turunkan dari 70 ke 50 agar lebih sering entry
input double InpMaxDailyLoss            = 500.0;   // UBAH: Naikkan ke 500 (atau lebih) agar tidak stop saat testing
input long   InpMagic                   = 20260809;
input int    InpCooldownSeconds         = 900;           
input bool   InpPrintLogs               = true;

input group "Trade Settings"
input double InpDefaultLot              = 0.01;    // Lot fallback jika perhitungan error
input double InpRiskPercent             = 15.0;     // PENTING: Risiko per trade % (5% dari $100 = max loss $5)
input int    InpDefaultMaxSpreadPoints  = 20;
input double InpDefaultSLDistance       = 5.0;     
input double InpBTCSLDistance           = 150.0;   
input int    InpBTCMaxSpreadPoints      = 10000;   // UBAH: Naikkan ke 10000 (Spread BTC di log Anda 4590 points!)
input double InpMarginBuffer            = 15.0;
input int    InpSlippagePoints          = 20;

input group "Data Settings"
input ENUM_TIMEFRAMES InpTFEntry        = PERIOD_M15;
input ENUM_TIMEFRAMES InpTFTrend        = PERIOD_H1;
input int    InpBars                    = 500;

CTrade trade;

string   g_symbols[];
datetime g_last_entry[];

//+------------------------------------------------------------------+
//| Logging helper                                                   |
//+------------------------------------------------------------------+
void Log(const string message)
{
   if(InpPrintLogs)
      Print(message);
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

//+------------------------------------------------------------------+
//| Diagnose account and terminal                                    |
//+------------------------------------------------------------------+
bool DiagnoseAccount()
{
   Print("========== DIAGNOSA AKUN MT5 ==========");

   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      Print("Terminal tidak terhubung.");
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("Algo Trading mati. Aktifkan tombol Algo Trading di toolbar MT5.");
      return false;
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      Print("Account trade allowed = false. Kemungkinan login menggunakan Investor Password.");
      return false;
   }

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      Print("Expert/EA trading tidak diizinkan untuk akun ini.");
      return false;
   }

   Print("Login   : ", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("Server  : ", AccountInfoString(ACCOUNT_SERVER));
   Print("Name    : ", AccountInfoString(ACCOUNT_NAME));
   Print("Balance : ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("Equity  : ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("Base Balance ditetapkan: ", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));

   Print("Semua izin trading terpenuhi. Bot siap berjalan.");
   Print("=======================================");

   return true;
}

//+------------------------------------------------------------------+
//| Symbol settings                                                  |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Smart Lot Calculator (Wajib untuk modal kecil seperti $100)      |
//+------------------------------------------------------------------+
double GetSmartLot(const string symbol, double sl_distance_price)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = balance * (InpRiskPercent / 100.0); // Misal 5% dari $100 = $5
   
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   if(tick_value <= 0 || tick_size <= 0 || sl_distance_price <= 0 || point <= 0) 
      return InpDefaultLot; // Fallback jika data broker error
      
   // Hitung nilai per point untuk 1 lot
   double value_per_point = (tick_value / tick_size) * point;
   double sl_points = sl_distance_price / point;
   
   // Hitung lot berdasarkan risiko
   double calculated_lot = risk_amount / (sl_points * value_per_point);
   
   double min_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   calculated_lot = MathFloor(calculated_lot / step_lot) * step_lot;
   
   if(calculated_lot < min_lot) calculated_lot = min_lot;
   if(calculated_lot > max_lot) calculated_lot = max_lot;
   
   // Proteksi tambahan: Cek margin. Jika margin tidak cukup, paksa pakai lot minimum
   double margin_req = 0;
   double current_price = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(OrderCalcMargin(ORDER_TYPE_BUY, symbol, calculated_lot, current_price, margin_req))
   {
       double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
       if(margin_req > free_margin * 0.8) // Gunakan max 80% free margin
       {
           calculated_lot = min_lot;
       }
   }
   
   return NormalizeDouble(calculated_lot, 2);
}

int GetMaxSpreadPoints(const string symbol)
{
   if(StringFind(symbol, "BTCUSD") >= 0)
      return InpBTCMaxSpreadPoints;

   return InpDefaultMaxSpreadPoints;
}

double GetSLDistance(const string symbol)
{
   if(StringFind(symbol, "BTCUSD") >= 0)
      return InpBTCSLDistance; // Pakai 150.0 untuk BTC
   return InpDefaultSLDistance; // Pakai 5.0 untuk XAU/Forex
}

//+------------------------------------------------------------------+
//| Cek apakah masih ada posisi terbuka pada symbol                  |
//+------------------------------------------------------------------+
bool HasOpenPosition(const string symbol)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == symbol)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Hitung daily loss                                                |
//+------------------------------------------------------------------+
double GetDailyLoss()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;

   datetime start_today = StructToTime(dt);

   if(!HistorySelect(start_today, TimeCurrent() + 60))
      return 0.0;

   double loss = 0.0;

   int total_deals = HistoryDealsTotal();

   for(int i = 0; i < total_deals; i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0)
         continue;

      double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);

      if(profit < 0.0)
         loss += MathAbs(profit);
   }

   return loss;
}

//+------------------------------------------------------------------+
//| Ambil rates                                                      |
//+------------------------------------------------------------------+
bool GetRates(const string symbol,
              ENUM_TIMEFRAMES timeframe,
              int count,
              MqlRates &rates[])
{
   if(!SymbolSelect(symbol, true))
      return false;

   ArraySetAsSeries(rates, true);

   int copied = CopyRates(symbol, timeframe, 0, count, rates);

   if(copied < count)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Simple Moving Average                                            |
//+------------------------------------------------------------------+
bool SMA(const MqlRates &rates[],
         int period,
         int shift,
         double &value)
{
   int total = ArraySize(rates);

   if(period <= 0 || shift < 0 || shift + period > total)
      return false;

   double sum = 0.0;

   for(int i = shift; i < shift + period; i++)
      sum += rates[i].close;

   value = sum / period;

   return true;
}

//+------------------------------------------------------------------+
//| Standard deviation close, sample std like pandas default ddof=1 |
//+------------------------------------------------------------------+
bool StdDevClose(const MqlRates &rates[],
                 int period,
                 int shift,
                 double &value)
{
   int total = ArraySize(rates);

   if(period <= 1 || shift < 0 || shift + period > total)
      return false;

   double mean = 0.0;
   if(!SMA(rates, period, shift, mean))
      return false;

   double sum_sq = 0.0;

   for(int i = shift; i < shift + period; i++)
   {
      double d = rates[i].close - mean;
      sum_sq += d * d;
   }

   value = MathSqrt(sum_sq / (period - 1));

   return true;
}

//+------------------------------------------------------------------+
//| Bollinger Bands                                                  |
//+------------------------------------------------------------------+
bool Bollinger(const MqlRates &rates[],
               int period,
               double mult,
               int shift,
               double &upper,
               double &middle,
               double &lower)
{
   double std = 0.0;

   if(!SMA(rates, period, shift, middle))
      return false;

   if(!StdDevClose(rates, period, shift, std))
      return false;

   upper = middle + mult * std;
   lower = middle - mult * std;

   return true;
}

//+------------------------------------------------------------------+
//| RSI sederhana berbasis SMA, mendekati rolling mean pandas        |
//+------------------------------------------------------------------+
bool RSISimple(const MqlRates &rates[],
               int period,
               int shift,
               double &value)
{
   int total = ArraySize(rates);

   if(period <= 0 || shift < 0 || shift + period + 1 > total)
      return false;

   double gain = 0.0;
   double loss = 0.0;

   for(int i = shift; i < shift + period; i++)
   {
      double change = rates[i].close - rates[i + 1].close;

      if(change > 0.0)
         gain += change;
      else if(change < 0.0)
         loss -= change;
   }

   gain /= period;
   loss /= period;

   if(loss == 0.0)
   {
      if(gain == 0.0)
         value = 50.0;
      else
         value = 100.0;
   }
   else
   {
      value = 100.0 - (100.0 / (1.0 + gain / loss));
   }

   return true;
}

//+------------------------------------------------------------------+
//| Build Accumulation/Distribution line                             |
//+------------------------------------------------------------------+
bool BuildAD(const MqlRates &rates[], double &ad[])
{
   int total = ArraySize(rates);

   if(total <= 0)
      return false;

   ArraySetAsSeries(ad, false);
   ArrayResize(ad, total);

   double cum = 0.0;

   // rates[] adalah series: index 0 = bar terbaru, index total-1 = bar terlama.
   // Kita hitung cumulative dari bar terlama ke terbaru.
   for(int i = total - 1; i >= 0; i--)
   {
      double range = rates[i].high - rates[i].low;

      double clv = ((rates[i].close - rates[i].low) -
                    (rates[i].high - rates[i].close)) /
                    (range + 1e-10);

      cum += clv * (double)rates[i].tick_volume;

      ad[i] = cum;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Volume average                                                   |
//+------------------------------------------------------------------+
bool VolumeAverage(const MqlRates &rates[],
                   int period,
                   int shift,
                   double &value)
{
   int total = ArraySize(rates);

   if(period <= 0 || shift < 0 || shift + period > total)
      return false;

   double sum = 0.0;

   for(int i = shift; i < shift + period; i++)
      sum += (double)rates[i].tick_volume;

   value = sum / period;

   return true;
}

//+------------------------------------------------------------------+
//| Min close                                                        |
//+------------------------------------------------------------------+
bool MinClose(const MqlRates &rates[],
              int count,
              int start_shift,
              double &value)
{
   int total = ArraySize(rates);

   if(count <= 0 || start_shift < 0 || start_shift + count > total)
      return false;

   value = rates[start_shift].close;

   for(int i = start_shift + 1; i < start_shift + count; i++)
      value = MathMin(value, rates[i].close);

   return true;
}

//+------------------------------------------------------------------+
//| Max close                                                        |
//+------------------------------------------------------------------+
bool MaxClose(const MqlRates &rates[],
              int count,
              int start_shift,
              double &value)
{
   int total = ArraySize(rates);

   if(count <= 0 || start_shift < 0 || start_shift + count > total)
      return false;

   value = rates[start_shift].close;

   for(int i = start_shift + 1; i < start_shift + count; i++)
      value = MathMax(value, rates[i].close);

   return true;
}

//+------------------------------------------------------------------+
//| Min double array                                                 |
//+------------------------------------------------------------------+
bool MinDouble(const double &arr[],
               int count,
               int start_shift,
               double &value)
{
   int total = ArraySize(arr);

   if(count <= 0 || start_shift < 0 || start_shift + count > total)
      return false;

   value = arr[start_shift];

   for(int i = start_shift + 1; i < start_shift + count; i++)
      value = MathMin(value, arr[i]);

   return true;
}

//+------------------------------------------------------------------+
//| Max double array                                                 |
//+------------------------------------------------------------------+
bool MaxDouble(const double &arr[],
               int count,
               int start_shift,
               double &value)
{
   int total = ArraySize(arr);

   if(count <= 0 || start_shift < 0 || start_shift + count > total)
      return false;

   value = arr[start_shift];

   for(int i = start_shift + 1; i < start_shift + count; i++)
      value = MathMax(value, arr[i]);

   return true;
}

//+------------------------------------------------------------------+
//| Cek trend H1                                                     |
//+------------------------------------------------------------------+
int CheckH1Trend(const MqlRates &h1[])
{
   double ma50, ma200;
   if(!SMA(h1, 50, 0, ma50)) return 0;
   if(!SMA(h1, 200, 0, ma200)) return 0;

   double close0 = h1[0].close;

   // Lebih longgar: Harga di atas MA50, dan MA50 di atas MA200
   if(close0 > ma50 && ma50 > ma200) return 1; // BULLISH
   if(close0 < ma50 && ma50 < ma200) return -1; // BEARISH

   return 0; // RANGING
}

//+------------------------------------------------------------------+
//| Hitung score entry                                               |
//+------------------------------------------------------------------+
int CalculateEntryScore(const MqlRates &m15[],
                        const MqlRates &h1[],
                        const int dir)
{
   if(ArraySize(m15) < 60 || ArraySize(h1) < 210)
      return 0;

   int score = 0;

   double close0 = m15[0].close;

   double ma20_0, ma50_0;
   if(!SMA(m15, 20, 0, ma20_0))
      return 0;

   if(!SMA(m15, 50, 0, ma50_0))
      return 0;

   double bb_upper_1, bb_middle_1, bb_lower_1;
   if(!Bollinger(m15, 20, 2.0, 1, bb_upper_1, bb_middle_1, bb_lower_1))
      return 0;

   //---------------------------------------------------------------
   // 1. ZONA VALUE (Max 30)
   //---------------------------------------------------------------
   bool in_ma_zone = false;
   bool touch_bb = false;

   if(dir > 0)
   {
      in_ma_zone = (ma50_0 <= close0 && close0 <= ma20_0);
      touch_bb   = (m15[1].low <= bb_lower_1);
   }
   else
   {
      in_ma_zone = (ma20_0 <= close0 && close0 <= ma50_0);
      touch_bb   = (m15[1].high >= bb_upper_1);
   }

   if(in_ma_zone || touch_bb)
      score += 30;

   //---------------------------------------------------------------
   // 2. MOMENTUM RSI (Max 25)
   //---------------------------------------------------------------
   double rsi0;
   if(!RSISimple(m15, 14, 0, rsi0))
      return 0;

   bool rsi_ok = false;
   if(dir > 0)
      rsi_ok = (rsi0 >= 30.0 && rsi0 <= 65.0); // Diperlebar dari 40-50
   else
      rsi_ok = (rsi0 >= 35.0 && rsi0 <= 70.0); // Diperlebar dari 50-60

   double ad_m15[];
   if(!BuildAD(m15, ad_m15))
      return 0;

   bool divergence = false;

   // Catatan penting:
   // Logika divergence pada Python asli:
   // last['close'] < df['close'].iloc[-10:].min()
   // secara teknis hampir tidak pernah true karena bar terakhir ikut dalam min().
   //
   // Di sini saya buat versi yang lebih logis:
   // bandingkan bar terakhir dengan 9 bar sebelumnya.

   if(dir > 0)
   {
      double min_close_prev, min_ad_prev;

      if(MinClose(m15, 9, 1, min_close_prev) &&
         MinDouble(ad_m15, 9, 1, min_ad_prev))
      {
         divergence = (close0 < min_close_prev && ad_m15[0] > min_ad_prev);
      }
   }
   else
   {
      double max_close_prev, max_ad_prev;

      if(MaxClose(m15, 9, 1, max_close_prev) &&
         MaxDouble(ad_m15, 9, 1, max_ad_prev))
      {
         divergence = (close0 > max_close_prev && ad_m15[0] < max_ad_prev);
      }
   }

   if((dir > 0 && (rsi_ok || divergence)) ||
      (dir < 0 && (rsi_ok || divergence)))
   {
      score += 25;
   }

   //---------------------------------------------------------------
   // 3. VALIDASI VOLUME & A/D (Max 25)
   //---------------------------------------------------------------
   double ad_h1[];
   if(!BuildAD(h1, ad_h1))
      return 0;

   double ad_slope_h1 = 0.0;

   if(ArraySize(ad_h1) >= 6)
   {
      double sum_diff = 0.0;

      for(int i = 0; i < 5; i++)
         sum_diff += (ad_h1[i] - ad_h1[i + 1]);

      ad_slope_h1 = sum_diff / 5.0;
   }

   double vol_avg = 0.0;
   bool vol_confirmed = false;

   if(VolumeAverage(m15, 20, 0, vol_avg))
      vol_confirmed = ((double)m15[0].tick_volume > vol_avg);

   if((dir > 0 && ad_slope_h1 >= 0.0 && vol_confirmed) ||
      (dir < 0 && ad_slope_h1 <= 0.0 && vol_confirmed))
   {
      score += 25;
   }

   //---------------------------------------------------------------
   // 4. CANDLE TRIGGER (Max 20)
   //---------------------------------------------------------------
   double range = m15[0].high - m15[0].low + 1e-10;
   double body_ratio = MathAbs(m15[0].close - m15[0].open) / range;

   bool bullish_candle = (m15[0].close > m15[0].open);

   if((dir > 0 && bullish_candle && body_ratio > 0.3) ||
      (dir < 0 && !bullish_candle && body_ratio > 0.3))
   {
      score += 20;
   }

   return score;
}

//+------------------------------------------------------------------+
//| Normalize volume                                                 |
//+------------------------------------------------------------------+
double NormalizeVolume(double volume, const string symbol)
{
   double min_volume  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_volume  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(step_volume > 0.0)
      volume = MathRound(volume / step_volume) * step_volume;

   if(volume < min_volume)
      volume = min_volume;

   if(volume > max_volume)
      volume = max_volume;

   return volume;
}

//+------------------------------------------------------------------+
//| Adjust SL/TP jika terlalu dekat dengan price                    |
//+------------------------------------------------------------------+
void AdjustStops(const string symbol,
                 const int dir,
                 const double entry,
                 double &sl,
                 double &tp)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);

   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);

   double min_stop_distance = (double)stops_level * point;

   if(min_stop_distance <= 0.0)
      return;

   if(dir > 0)
   {
      if(entry - sl < min_stop_distance)
         sl = entry - min_stop_distance;

      if(tp - entry < min_stop_distance)
         tp = entry + min_stop_distance;
   }
   else
   {
      if(sl - entry < min_stop_distance)
         sl = entry + min_stop_distance;

      if(entry - tp < min_stop_distance)
         tp = entry - min_stop_distance;
   }
}

//+------------------------------------------------------------------+
//| Eksekusi order                                                   |
//+------------------------------------------------------------------+
bool ExecuteTrade(const string symbol,
                  const int dir,
                  double entry,
                  double sl,
                  double tp)
{
   MqlTick tick;

   if(!SymbolInfoTick(symbol, tick))
   {
      Log(StringFormat("[ERROR] %s: gagal ambil tick.", symbol));
      return false;
   }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(point <= 0.0)
   {
      Log(StringFormat("[ERROR] %s: point tidak valid.", symbol));
      return false;
   }

    int max_spread_points = GetMaxSpreadPoints(symbol);
   double spread = tick.ask - tick.bid;

   // UBAH: Jangan skip, cukup beri WARNING. 
   // SL sudah otomatis dijauhkan oleh logika actual_sl_distance di ProcessSymbol
   if(spread > max_spread_points * point)
   {
      Log(StringFormat("[WARNING] %s: spread sangat lebar %.1f points, tapi EA tetap entry karena SL sudah disesuaikan.",
                       symbol,
                       spread / point));
   }

   // Hitung jarak SL dalam harga untuk kalkulasi lot
   double sl_distance_price = MathAbs(entry - sl);
   
   // GANTI: Gunakan Smart Lot untuk melindungi modal $100
   double lot = GetSmartLot(symbol, sl_distance_price);
   
   Log(StringFormat("[LOT INFO] %s | Modal: %.2f | Risiko: %.2f%% | Lot Terpakai: %.2f", 
                    symbol, AccountInfoDouble(ACCOUNT_BALANCE), InpRiskPercent, lot));

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
      Log(StringFormat("[SKIP] %s: free margin kurang. Free margin=%.2f, margin_required=%.2f",
                       symbol,
                       free_margin,
                       margin_required));
      return false;
   }

   AdjustStops(symbol, dir, entry, sl, tp);

   entry = NormalizeDouble(entry, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(symbol);

   bool ok = false;

   if(dir > 0)
      ok = trade.Buy(lot, symbol, entry, sl, tp, "Confluence_BUY");
   else
      ok = trade.Sell(lot, symbol, entry, sl, tp, "Confluence_SELL");

   uint retcode = trade.ResultRetcode();

   if(ok &&
      (retcode == TRADE_RETCODE_DONE ||
       retcode == TRADE_RETCODE_DONE_PARTIAL ||
       retcode == TRADE_RETCODE_PLACED))
   {
      Log(StringFormat("[SUCCESS] %s %s @ %s | SL:%s TP:%s",
                       symbol,
                       (dir > 0 ? "BUY" : "SELL"),
                       DoubleToString(entry, digits),
                       DoubleToString(sl, digits),
                       DoubleToString(tp, digits)));
      return true;
   }

   Log(StringFormat("[ERROR] %s: retcode=%d, comment=%s",
                    symbol,
                    retcode,
                    trade.ResultComment()));

   return false;
}

//+------------------------------------------------------------------+
//| Proses satu symbol                                               |
//+------------------------------------------------------------------+
void ProcessSymbol(const string symbol, const int idx)
{
   Log(StringFormat("=== %s | Cek %s ===",
                    TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
                    symbol));

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

   MqlRates m15[];
   MqlRates h1[];

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

   int trend = CheckH1Trend(h1);

   if(trend == 1)
      Log(StringFormat("Trend H1 %s: BULLISH", symbol));
   else if(trend == -1)
      Log(StringFormat("Trend H1 %s: BEARISH", symbol));
   else
      Log(StringFormat("Trend H1 %s: RANGING", symbol));

   if(trend == 0)
   {
      Log(StringFormat("[SKIP] %s: market ranging.", symbol));
      return;
   }
   
      // --- FILTER TREND M15 (WAJIB SEARAH H1) ---
   double m15_ma20, m15_ma50;
   if(!SMA(m15, 20, 0, m15_ma20) || !SMA(m15, 50, 0, m15_ma50))
   {
      Log(StringFormat("[SKIP] %s: Gagal hitung MA M15.", symbol));
      return;
   }
   
   bool m15_trend_ok = false;
   if(trend > 0 && m15[0].close > m15_ma20 && m15_ma20 > m15_ma50) m15_trend_ok = true;
   if(trend < 0 && m15[0].close < m15_ma20 && m15_ma20 < m15_ma50) m15_trend_ok = true;
   
   if(!m15_trend_ok)
   {
      Log(StringFormat("[SKIP] %s: Trend M15 belum searah dengan H1 (Menunggu konfirmasi trend).", symbol));
      return;
   }
   // ------------------------------------------

   MqlTick tick;

   if(!SymbolInfoTick(symbol, tick))
   {
      Log(StringFormat("[ERROR] %s: tick None.", symbol));
      return;
   }

      int signal = 0;
   int score = 0;
   double entry = 0.0;

   if(trend > 0)
   {
      score = CalculateEntryScore(m15, h1, 1);
      Log(StringFormat("Score BUY %s: %d (Threshold: %d)", symbol, score, InpEntryScoreThreshold));

      if(score >= InpEntryScoreThreshold)
      {
         signal = 1;
         entry = tick.ask;
      }
   }
   else
   {
      score = CalculateEntryScore(m15, h1, -1);
      Log(StringFormat("Score SELL %s: %d (Threshold: %d)", symbol, score, InpEntryScoreThreshold));

      if(score >= InpEntryScoreThreshold)
      {
         signal = -1;
         entry = tick.bid;
      }
   }

   if(signal == 0 || entry <= 0.0)
   {
      Log(StringFormat("No signal untuk %s (Score %d < Threshold %d)",
                       symbol, score, InpEntryScoreThreshold));
      return;
   }
   
   double sl_distance = GetSLDistance(symbol);
   // --- LOGIKA ANTI INVALID STOPS (WAJIB DIPAKAI) ---
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS); 
   long stops_level = SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_stop = (stops_level > 0 ? (double)stops_level * point : 10 * point);
   
   MqlTick current_tick;
   SymbolInfoTick(symbol, current_tick);
   double spread = current_tick.ask - current_tick.bid;
   
   // Paksa jarak SL minimal = Spread + Stop Level Broker + Buffer 10 point
   double actual_sl_distance = MathMax(sl_distance, spread + min_stop + 10 * point);
   // -------------------------------------------------
   
   // >>> TAMBAHAN LOG 1: DEBUG PERHITUNGAN JARAK <<<
   Log(StringFormat("[DEBUG SL/TP] %s | Input SL Dist: %.5f | Stops Level: %d pts | Min Stop Dist: %.5f | Current Spread: %.5f | ACTUAL SL Dist: %.5f",
                    symbol, sl_distance, (int)stops_level, min_stop, spread, actual_sl_distance));
   // -------------------------------------------------

   double sl = 0.0;
   double tp = 0.0;

   if(signal > 0)
   {
      sl = entry - (actual_sl_distance*12); // Gunakan actual_sl_distance
      tp = entry + actual_sl_distance * 20;
   }
   else
   {
      sl = entry + (actual_sl_distance*12); // Gunakan actual_sl_distance
      tp = entry - actual_sl_distance * 20;
   }
   
   // >>> TAMBAHAN LOG 2: HARGA FINAL SEBELUM ORDER DIKIRIM <<<
   Log(StringFormat("[FINAL SL/TP] %s | Arah: %s | Entry: %s | Final SL: %s | Final TP: %s",
                    symbol, 
                    (signal > 0 ? "BUY" : "SELL"),
                    DoubleToString(entry, digits), 
                    DoubleToString(sl, digits), 
                    DoubleToString(tp, digits)));

   bool success = ExecuteTrade(symbol, signal, entry, sl, tp);

   if(success && idx >= 0)
      g_last_entry[idx] = TimeCurrent();
}

//+------------------------------------------------------------------+
//| SMART EXIT: Tutup posisi otomatis jika trend M15 berbalik arah   |
//+------------------------------------------------------------------+
void ManageSmartExit()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      
      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      
      if(magic != InpMagic) continue;
      
      // Cek apakah symbol ini ada di list kita
      bool is_our_symbol = false;
      for(int s = 0; s < ArraySize(g_symbols); s++)
      {
         if(g_symbols[s] == symbol) { is_our_symbol = true; break; }
      }
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
      
      // Jika posisi BUY, tapi trend M15 berubah jadi BEARISH, tutup posisi
      if(pos_type == POSITION_TYPE_BUY && m15_bearish) 
      {
         should_close = true;
         reason = "M15 Trend Berubah jadi BEARISH";
      }
      // Jika posisi SELL, tapi trend M15 berubah jadi BULLISH, tutup posisi
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

//+------------------------------------------------------------------+
//| Run periodic checks                                              |
//+------------------------------------------------------------------+
void RunChecks()
{
   static datetime last_check = 0;

   if(TimeCurrent() - last_check < InpCheckIntervalSeconds)
      return;

   last_check = TimeCurrent();
   
   // >>> TAMBAHAN: Cek dan tutup posisi yang trend-nya sudah berbalik <<<
   ManageSmartExit();
   // -------------------------------------------------------------------


   double daily_loss = GetDailyLoss();

   if(daily_loss >= InpMaxDailyLoss)
   {
      Log(StringFormat("DAILY LOSS LIMIT: %.2f. Bot istirahat, tidak cek entry dulu.",
                       daily_loss));
      return;
   }

   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      ProcessSymbol(g_symbols[i], i);
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpCheckIntervalSeconds <= 0)
   {
      Print("InpCheckIntervalSeconds harus lebih dari 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(ParseSymbols(InpSymbols) <= 0)
   {
      Print("Symbol list kosong. Isi InpSymbols, contoh: BTCUSD.vx");
      return INIT_PARAMETERS_INCORRECT;
   }

   ArrayResize(g_last_entry, ArraySize(g_symbols));
   ArrayInitialize(g_last_entry, 0);

   for(int i = 0; i < ArraySize(g_symbols); i++)
   {
      if(!SymbolSelect(g_symbols[i], true))
         Print("Warning: SymbolSelect gagal untuk ", g_symbols[i]);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(!DiagnoseAccount())
      return INIT_FAILED;

   // Timer dipakai untuk live trading.
   // Untuk Strategy Tester, OnTick juga dipanggil agar EA tetap bisa berjalan.
   EventSetTimer(1);

   Print("Bot running...");
   Print("Symbols: ", InpSymbols);
   Print("Interval cek: ", InpCheckIntervalSeconds, " detik");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   RunChecks();
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   RunChecks();
}