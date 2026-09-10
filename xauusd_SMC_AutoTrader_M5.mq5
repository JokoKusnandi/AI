//+------------------------------------------------------------------+
//|                                      SMC_AutoTrader_M5.mq5       |
//|                   EA Otomatis BOS & CHoCH (Smart Money Concepts) |
//|                   Optimized for M5 Timeframe with USD Risk Mgmt  |
//+------------------------------------------------------------------+
#property copyright "Joko Kusnandi"
#property version   "1.04"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input double InpLotSize      = 0.01;    // Lot Size
input int    InpMagicNumber  = 123456;  // Magic Number
input double InpRiskUSD      = 20.0;    // Risiko per trade dalam USD ($)
input double InpRewardUSD    = 30.0;    // Target Profit per trade dalam USD ($)
input int    InpLeftBars     = 5;       // Candle kiri untuk validasi Swing
input int    InpRightBars    = 5;       // Candle kanan untuk validasi Swing
input bool   InpShowLogs     = true;    // Tampilkan detail log di Journal

//--- Enum untuk Status Trend
enum TrendState { TREND_BULLISH, TREND_BEARISH, TREND_UNKNOWN };

//--- Global Variables
CTrade trade;
TrendState current_trend = TREND_UNKNOWN;

double last_swing_high = 0;
double last_swing_low = 0;
datetime last_swing_high_time = 0;
datetime last_swing_low_time = 0;

double last_traded_swing_high = 0; 
double last_traded_swing_low = 0;

datetime last_trade_time = 0;
bool swings_initialized = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol); 
   
   Print("✅ EA SMC BOS/CHoCH Initialized (v1.04 - Fixed Bearish Logic)");
   Print("   Symbol: ", _Symbol, " | TF: M5");
   Print("   Risk: $", InpRiskUSD, " | Reward: $", InpRewardUSD, " | Lot: ", InpLotSize);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. CEK POSISI: Jika sudah ada posisi, tunggu sampai tertutup.
   if(CountPositions() > 0) return;

   // 2. Update referensi Struktur Pasar (Swing High/Low)
   UpdateStructure();
   
   // 3. Ambil data candle M5 yang SUDAH CLOSE (index 1)
   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   datetime time1 = iTime(_Symbol, PERIOD_M5, 1);
   
   if(time1 == 0 || close1 == 0) return;
   if(time1 == last_trade_time) return; // Mencegah eksekusi ganda di candle yang sama

   // 4. Pastikan struktur pasar sudah terdeteksi sebelum trading
   if(!swings_initialized)
   {
      if(InpShowLogs && (time1 % 3600) == 0) 
         Print("⚠️ Menunggu pembentukan Swing High/Low pertama...");
      return;
   }

   // 5. LOGIKA DETEKSI BOS & CHoCH
   
   // --- SKENARIO BULLISH (Close di atas Swing High) ---
   if(close1 > last_swing_high && last_swing_high > 0)
   {
      if(last_traded_swing_high == 0 || last_swing_high > last_traded_swing_high)
      {
         if(current_trend == TREND_BEARISH || current_trend == TREND_UNKNOWN)
         {
            if(InpShowLogs) Print("🔄 Sinyal CHoCH BULLISH | Break High: ", last_swing_high);
            ExecuteTrade(ORDER_TYPE_BUY, "CHoCH Bull");
            current_trend = TREND_BULLISH;
            last_trade_time = time1;
            last_traded_swing_high = last_swing_high;
         }
         else if(current_trend == TREND_BULLISH)
         {
            if(InpShowLogs) Print("📈 Sinyal BOS BULLISH | Break High: ", last_swing_high);
            ExecuteTrade(ORDER_TYPE_BUY, "BOS Bull");
            last_trade_time = time1;
            last_traded_swing_high = last_swing_high;
         }
      }
   }

   // --- SKENARIO BEARISH (Close di bawah Swing Low) ---
   if(close1 < last_swing_low && last_swing_low > 0)
   {
      if(last_traded_swing_low == 0 || last_swing_low < last_traded_swing_low)
      {
         if(current_trend == TREND_BULLISH || current_trend == TREND_UNKNOWN)
         {
            if(InpShowLogs) Print("🔄 Sinyal CHoCH BEARISH | Break Low: ", last_swing_low);
            ExecuteTrade(ORDER_TYPE_SELL, "CHoCH Bear");
            current_trend = TREND_BEARISH;
            last_trade_time = time1;
            last_traded_swing_low = last_swing_low;
         }
         else if(current_trend == TREND_BEARISH)
         {
            if(InpShowLogs) Print("📉 Sinyal BOS BEARISH | Break Low: ", last_swing_low);
            ExecuteTrade(ORDER_TYPE_SELL, "BOS Bear");
            last_trade_time = time1;
            last_traded_swing_low = last_swing_low;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Fungsi Update Struktur Pasar (PERBAIKAN UTAMA)                   |
//+------------------------------------------------------------------+
void UpdateStructure()
{
   double candidate_high = 0, candidate_low = 999999;
   datetime time_high = 0, time_low = 0;
   
   // Cari Swing High terbaru
   for(int i = InpRightBars; i <= 100; i++)
   {
      if(IsSwingConfirmed(i, true))
      {
         candidate_high = iHigh(_Symbol, PERIOD_M5, i);
         time_high = iTime(_Symbol, PERIOD_M5, i);
         break; 
      }
   }
   // Cari Swing Low terbaru
   for(int i = InpRightBars; i <= 100; i++)
   {
      if(IsSwingConfirmed(i, false))
      {
         candidate_low = iLow(_Symbol, PERIOD_M5, i);
         time_low = iTime(_Symbol, PERIOD_M5, i);
         break;
      }
   }

   // --- LOGIKA PENTING: Mencegah "Moving Goalpost" ---
   
   if(current_trend == TREND_BEARISH)
   {
      // Dalam downtrend, kita BEBAS update Swing High untuk mendeteksi "Lower High" (Pullback)
      if(candidate_high > 0 && (last_swing_high == 0 || time_high > last_swing_high_time))
      {
         last_swing_high = candidate_high;
         last_swing_high_time = time_high;
      }
      // TAPI, kita KUNCI Swing Low (target break). 
      // Hanya update ke Low baru JIKA low tersebut terbentuk SETELAH trade terakhir kita.
      // Ini menandakan pullback sudah selesai dan struktur Lower Low baru siap di-break (BOS).
      if(candidate_low > 0 && time_low > last_trade_time)
      {
         last_swing_low = candidate_low;
         last_swing_low_time = time_low;
      }
   }
   else if(current_trend == TREND_BULLISH)
   {
      // Dalam uptrend, kita BEBAS update Swing Low untuk mendeteksi "Higher Low" (Pullback)
      if(candidate_low > 0 && (last_swing_low == 0 || time_low > last_swing_low_time))
      {
         last_swing_low = candidate_low;
         last_swing_low_time = time_low;
      }
      // KUNCI Swing High. Hanya update jika terbentuk setelah trade terakhir.
      if(candidate_high > 0 && time_high > last_trade_time)
      {
         last_swing_high = candidate_high;
         last_swing_high_time = time_high;
      }
   }
   else // TREND_UNKNOWN (Fase awal mencari CHoCH pertama)
   {
      if(candidate_high > 0) { last_swing_high = candidate_high; last_swing_high_time = time_high; }
      if(candidate_low > 0)  { last_swing_low = candidate_low; last_swing_low_time = time_low; }
      
      if(last_swing_high > 0 && last_swing_low > 0) 
      {
         swings_initialized = true;
         if(InpShowLogs) Print("✅ Struktur Awal Terdeteksi | High: ", last_swing_high, " | Low: ", last_swing_low);
      }
   }
}

//+------------------------------------------------------------------+
//| Fungsi Helper: Cek apakah candle adalah Swing yang Confirmed     |
//+------------------------------------------------------------------+
bool IsSwingConfirmed(int i, bool isHigh)
{
   int total_bars = iBars(_Symbol, PERIOD_M5);
   if(i - InpLeftBars < 0 || i + InpRightBars >= total_bars) return false;
   
   double val = isHigh ? iHigh(_Symbol, PERIOD_M5, i) : iLow(_Symbol, PERIOD_M5, i);
   
   for(int j = 1; j <= InpLeftBars; j++)
   {
      if(isHigh && iHigh(_Symbol, PERIOD_M5, i-j) >= val) return false;
      if(!isHigh && iLow(_Symbol, PERIOD_M5, i-j) <= val) return false;
   }
   for(int j = 1; j <= InpRightBars; j++)
   {
      if(isHigh && iHigh(_Symbol, PERIOD_M5, i+j) >= val) return false;
      if(!isHigh && iLow(_Symbol, PERIOD_M5, i+j) <= val) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Fungsi Eksekusi Order dengan Kalkulasi SL/TP berbasis USD        |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE order_type, string comment)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   CalculateSLTP(sl, tp, (order_type == ORDER_TYPE_BUY));

   if(order_type == ORDER_TYPE_BUY)
   {
      if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, comment))
         Print("✅ BUY Sukses | Ticket: ", trade.ResultOrder(), " | SL: ", sl, " | TP: ", tp);
      else
         Print("❌ BUY Gagal: ", trade.ResultRetcodeDescription());
   }
   else
   {
      if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, comment))
         Print("✅ SELL Sukses | Ticket: ", trade.ResultOrder(), " | SL: ", sl, " | TP: ", tp);
      else
         Print("❌ SELL Gagal: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Kalkulasi SL/TP Presisi berdasarkan Nilai USD                    |
//+------------------------------------------------------------------+
void CalculateSLTP(double &sl, double &tp, bool isBuy)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double current_price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(tick_size <= 0 || tick_value <= 0 || InpLotSize <= 0) return;
   
   double sl_distance = (InpRiskUSD * tick_size) / (tick_value * InpLotSize);
   double tp_distance = (InpRewardUSD * tick_size) / (tick_value * InpLotSize);
   
   sl_distance = MathRound(sl_distance / point) * point;
   tp_distance = MathRound(tp_distance / point) * point;
   
   if(isBuy)
   {
      sl = NormalizeDouble(current_price - sl_distance, _Digits);
      tp = NormalizeDouble(current_price + tp_distance, _Digits);
   }
   else
   {
      sl = NormalizeDouble(current_price + sl_distance, _Digits);
      tp = NormalizeDouble(current_price - tp_distance, _Digits);
   }
   
   long stop_level_points = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stop_level_points > 0)
   {
      double min_dist = stop_level_points * point;
      if(isBuy)
      {
         if(current_price - sl < min_dist) sl = NormalizeDouble(current_price - min_dist, _Digits);
         if(tp - current_price < min_dist) tp = NormalizeDouble(current_price + min_dist, _Digits);
      }
      else
      {
         if(sl - current_price < min_dist) sl = NormalizeDouble(current_price + min_dist, _Digits);
         if(current_price - tp < min_dist) tp = NormalizeDouble(current_price - min_dist, _Digits);
      }
   }
}

//+------------------------------------------------------------------+
//| Fungsi Helper: Hitung Posisi Aktif EA Ini                        |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}