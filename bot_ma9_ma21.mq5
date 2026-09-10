//+------------------------------------------------------------------+
//|                                      Vinfastrade_ma9_ma21_v1.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//|                        XAUUSD Scalping with MA Filter            |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.02" // Versi diperbarui

//--- PERBAIKAN 1: Include library trading standar MQL5
#include <Trade/Trade.mqh>
CTrade trade;

//--- Input Parameters
input double   LotSize          = 0.01;       // Lot size tetap kecil untuk modal $30
input int      TakeProfitPips   = 90;         // TP dalam pips
input int      StopLossPips     = 30;         // SL dalam pips
input int      MagicNumber      = 123456;     
input int      Slippage         = 30;         // Slippage dalam points (MQL5)

//--- Parameter Moving Average
input int      MAPeriodFast     = 9;          // MA Cepat
input int      MAPeriodSlow     = 21;         // MA Lambat
input ENUM_MA_METHOD MAMethod   = MODE_SMA;   // Metode MA (SMA/EMA)
input int      MAShift          = 0;          // Shift MA

//--- Parameter Candlestick
input bool     UseEngulfing     = true;       
input bool     UseMarubozu      = true;       

//--- Global Variables
double point;
int maFastHandle = INVALID_HANDLE;
int maSlowHandle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Setup CTrade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   
   // PERBAIKAN 2: Deteksi mode filling yang didukung broker (FOK, IOC, atau RETURN)
   // Metode SetTypeFillingBySymbol TIDAK ADA di MQL5, ini penyebab error "open parenthesis"
   long filling_mode = SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE);
   if((filling_mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling_mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   // Hitung nilai point yang disesuaikan untuk broker 3/5 digit (termasuk XAUUSD)
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(Digits() == 3 || Digits() == 5) 
      point *= 10;
   
   // Buat handle indikator sekali saja di OnInit
   maFastHandle = iMA(Symbol(), PERIOD_CURRENT, MAPeriodFast, MAShift, MAMethod, PRICE_CLOSE);
   maSlowHandle = iMA(Symbol(), PERIOD_CURRENT, MAPeriodSlow, MAShift, MAMethod, PRICE_CLOSE);
   
   if(maFastHandle == INVALID_HANDLE || maSlowHandle == INVALID_HANDLE)
   {
      Print("Gagal membuat handle MA. Error: ", GetLastError());
      return INIT_FAILED;
   }
   
   // PERBAIKAN 3: Validasi Lot Size untuk modal kecil
   double min_lot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   if(LotSize < min_lot)
   {
      Print("PERINGATAN: LotSize (", LotSize, ") lebih kecil dari minimum broker (", min_lot, ")");
   }
   
   Print("EA Berhasil Diinisialisasi. Point Value: ", point, " | Filling Mode: OK");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Bersihkan handle indikator untuk mencegah memory leak
   if(maFastHandle != INVALID_HANDLE) IndicatorRelease(maFastHandle);
   if(maSlowHandle != INVALID_HANDLE) IndicatorRelease(maSlowHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Gunakan PositionsTotal() untuk MQL5
   if(PositionsTotal() > 0) return; // Hanya 1 posisi sekaligus

   // Ambil data MA menggunakan CopyBuffer
   double maFastArr[], maSlowArr[];
   ArraySetAsSeries(maFastArr, true);
   ArraySetAsSeries(maSlowArr, true);
   
   // Ambil 2 data terakhir mulai dari index 1 (candle sebelumnya)
   if(CopyBuffer(maFastHandle, 0, 1, 2, maFastArr) <= 0) return;
   if(CopyBuffer(maSlowHandle, 0, 1, 2, maSlowArr) <= 0) return;
   
   double maFastPrev = maFastArr[0]; 
   double maSlowPrev = maSlowArr[0]; 
   
   // Ambil data candle untuk deteksi pola
   double open1 = iOpen(Symbol(), PERIOD_CURRENT, 1);
   double close1 = iClose(Symbol(), PERIOD_CURRENT, 1);
   double high1 = iHigh(Symbol(), PERIOD_CURRENT, 1);
   double low1 = iLow(Symbol(), PERIOD_CURRENT, 1);
   
   double open2 = iOpen(Symbol(), PERIOD_CURRENT, 2);
   double close2 = iClose(Symbol(), PERIOD_CURRENT, 2);

   //--- Deteksi Pola Candlestick
   bool isBullishSignal = false;
   bool isBearishSignal = false;

   // 1. Bullish Engulfing
   if(UseEngulfing && close2 < open2 && close1 > open1 && close1 > open2 && open1 < close2)
      isBullishSignal = true;
      
   // 2. Bearish Engulfing
   if(UseEngulfing && close2 > open2 && close1 < open1 && close1 < open2 && open1 > close2)
      isBearishSignal = true;

   // 3. Bullish/Bearish Marubozu
   if(UseMarubozu)
   {
      double body1 = MathAbs(close1 - open1);
      double range1 = high1 - low1;
      if(range1 > 0 && (high1 - MathMax(open1, close1))/range1 < 0.1 && (MathMin(open1, close1) - low1)/range1 < 0.1)
      {
         if(close1 > open1) isBullishSignal = true;
         else if(close1 < open1) isBearishSignal = true;
      }
   }

   //--- Logika Eksekusi dengan Filter MA
   
   // BUY: Sinyal Bullish + Harga > MA Fast + MA Fast > MA Slow
   if(isBullishSignal && close1 > maFastPrev && maFastPrev > maSlowPrev)
   {
      OpenBuy();
   }
   
   // SELL: Sinyal Bearish + Harga < MA Fast + MA Fast < MA Slow
   if(isBearishSignal && close1 < maFastPrev && maFastPrev < maSlowPrev)
   {
      OpenSell();
   }
}

//+------------------------------------------------------------------+
//| Fungsi Buka Posisi BUY                                           |
//+------------------------------------------------------------------+
void OpenBuy()
{
   double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double sl = 0, tp = 0;
   CalculateSLTP(sl, tp, false);

   if(!trade.Buy(LotSize, Symbol(), ask, sl, tp, "MA Scalp Buy"))
   {
      // PERBAIKAN 4: Tambahkan ResultRetcodeDescription agar Anda tahu PENYEBAB gagal (misal: "Not enough money")
      Print("Buy GAGAL! Error: ", GetLastError(), " | Retcode: ", trade.ResultRetcode(), " | Alasan: ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("Buy BERHASIL! Ticket: ", trade.ResultOrder());
   }
}

//+------------------------------------------------------------------+
//| Fungsi Buka Posisi SELL                                          |
//+------------------------------------------------------------------+
void OpenSell()
{
   double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   //---
   double sl = 0, tp = 0;
   CalculateSLTP(sl, tp, false);

   if(!trade.Sell(LotSize, Symbol(), bid, sl, tp, "MA Scalp Sell"))
   {
      Print("Sell GAGAL! Error: ", GetLastError(), " | Retcode: ", trade.ResultRetcode(), " | Alasan: ", trade.ResultRetcodeDescription());
   }
   else
   {
      Print("Sell BERHASIL! Ticket: ", trade.ResultOrder());
   }
}
//+------------------------------------------------------------------+

void CalculateSLTP(double &sl, double &tp, bool isBuy)
{
   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot         = LotSize;
   double price       = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(tick_size <= 0 || tick_value <= 0 || lot <= 0)
   {
      sl = 0; tp = 0;
      return;
   }

   // Hitung jarak SL/TP berdasarkan risk/reward dalam USD
   double sl_distance = (StopLossPips * tick_size) / (tick_value * lot);
   double tp_distance = (TakeProfitPips * tick_size) / (tick_value * lot);

   sl_distance = MathMax(sl_distance, point);
   tp_distance = MathMax(tp_distance, point);

   sl_distance = MathRound(sl_distance / point) * point;
   tp_distance = MathRound(tp_distance / point) * point;

   // --- Hitung SL/TP awal ---
   if(isBuy)
   {
      sl = NormalizeDouble(price - sl_distance, _Digits);
      tp = NormalizeDouble(price + tp_distance, _Digits);
   }
   else
   {
      sl = NormalizeDouble(price + sl_distance, _Digits);
      tp = NormalizeDouble(price - tp_distance, _Digits);
   }

   // --- Validasi Stop Level ---
   long stop_level_points  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze_level_points = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double min_distance = (stop_level_points + freeze_level_points) * point;

   if(min_distance < point) min_distance = point; // fallback

   // Tambahkan buffer ekstra 2x point
   min_distance += 2 * point;

   if(isBuy)
   {
      if(price - sl < min_distance)
         sl = NormalizeDouble(price - min_distance, _Digits);
      if(tp - price < min_distance)
         tp = NormalizeDouble(price + min_distance, _Digits);
   }
   else
   {
      if(sl - price < min_distance)
         sl = NormalizeDouble(price + min_distance, _Digits);
      if(price - tp < min_distance)
         tp = NormalizeDouble(price - min_distance, _Digits);
   }
}
