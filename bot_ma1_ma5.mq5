//+------------------------------------------------------------------+
//|                                       Vinfastrade_ma1_ma5_v1.mq5 |
//|                               XAUUSD Wolfe + SMC Quick Profit EA |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+

#include <Trade/Trade.mqh>

CTrade trade;

//==================================================================
// INPUTS
//==================================================================

//--- General
input string InpSymbol              = "";         // Blank = chart symbol
input ulong  MagicNumber             = 26082301;
input double InitialLot              = 0.01;
input double AddLot                  = 0.01;
input int    MaxPositions            = 3;
input double MaxTotalLots            = 0.03;

//--- Commission / profit
input double CommissionPer001        = 0.45;    // USD per 0.01 lot
input double MinimumNetProfit        = 0.50;    // Desired net profit
input double ProfitBuffer            = 0.05;    // Safety buffer

//--- Entry
input ENUM_TIMEFRAMES BiasTF         = PERIOD_M5;
input ENUM_TIMEFRAMES EntryTF        = PERIOD_M1;

input int    FastEMA                 = 20;
input int    SlowEMA                 = 50;

input int    SwingLookback           = 80;
input int    SwingStrength           = 2;

input double WolfeTolerancePoints    = 150;     // Kept for future use
input double EntryZonePoints         = 250;

//--- Risk
input double StopLossPoints          = 900;
input double MaxBasketLossUSD        = 25.0;
input double MaxDailyLossUSD         = 50.0;

//--- Spread
input double MaxSpreadPoints         = 120;

//--- Scaling
input double AddAfterProfitUSD       = 0.30;
input int    MinimumSecondsBetweenAdds = 60;

//--- Trading hours
input bool   UseTradingHours         = true;
input int    StartHour               = 2;
input int    EndHour                 = 24;

//--- Execution
input int    DeviationPoints         = 30;

//==================================================================
// GLOBALS
//==================================================================

string TradeSymbol;

datetime LastBarM1 = 0;
datetime LastAddTime = 0;
datetime DayStart = 0;

double DailyStartEquity = 0;

//--- Indicator Handles (Fixed: Prevents handle leak)
int fastEMAHandle = INVALID_HANDLE;
int slowEMAHandle = INVALID_HANDLE;
bool debugSymbolPrinted = false; // Untuk mencegah spam print

//==================================================================
// INITIALIZATION
//==================================================================

int OnInit()
{
   TradeSymbol = InpSymbol;
   if(TradeSymbol == "")
      TradeSymbol = _Symbol;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(DeviationPoints);
   
   //--- PERBAIKAN 2: Deteksi Filling Mode yang didukung broker/tester
   long filling_mode = SymbolInfoInteger(TradeSymbol, SYMBOL_FILLING_MODE);
   if((filling_mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling_mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   DailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   DayStart = StructToTime(dt);

   //--- Create indicator handles once
   fastEMAHandle = iMA(TradeSymbol, BiasTF, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowEMAHandle = iMA(TradeSymbol, BiasTF, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   if(fastEMAHandle == INVALID_HANDLE || slowEMAHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }
   
   //--- PERBAIKAN 3: Print informasi awal untuk debugging di Strategy Tester
   Print("==================================================");
   Print("EA initialized successfully on ", TradeSymbol);
   Print("Magic Number: ", MagicNumber);
   Print("Filling Mode Aktif: ", trade.RequestTypeFilling());
   Print("==================================================");
   return(INIT_SUCCEEDED);
}

//==================================================================
// DEINITIALIZATION
//==================================================================

void OnDeinit(const int reason)
{
   //--- Clean up indicator handles to prevent memory leaks
   if(fastEMAHandle != INVALID_HANDLE) IndicatorRelease(fastEMAHandle);
   if(slowEMAHandle != INVALID_HANDLE) IndicatorRelease(slowEMAHandle);
}

//==================================================================
// MAIN
//==================================================================

void OnTick()
{
   //--- PERBAIKAN 4: Debug jika symbol tidak cocok
   if(_Symbol != TradeSymbol)
   {
      if(!debugSymbolPrinted)
      {
         Print("PERINGATAN: EA Dihentikan! Symbol Chart (", _Symbol, ") tidak cocok dengan InpSymbol (", TradeSymbol, ")");
         Print("SOLUSI: Kosongkan input 'InpSymbol' atau ubah symbol di Strategy Tester menjadi ", TradeSymbol);
         debugSymbolPrinted = true;
      }
      return;
   }

   UpdateDailyReference();
   ManageBasket();

   if(DailyLossExceeded())
      return;

   if(!TradingTime()) 
   {
      // Opsional: aktifkan baris di bawah ini jika ingin tahu kapan EA berhenti karena jam
      // Print("Ditolak: Di luar jam trading (", StartHour, "-", EndHour, ")"); 
      return;
   }

   if(!SpreadOK()) 
   {
      static datetime lastSpreadPrint = 0;
      if(TimeCurrent() - lastSpreadPrint > 60) // Print maksimal 1x per menit
      {
         double spread = (SymbolInfoDouble(TradeSymbol, SYMBOL_ASK) - SymbolInfoDouble(TradeSymbol, SYMBOL_BID)) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
         Print("Ditolak: Spread terlalu tinggi (", spread, " points). Maksimal: ", MaxSpreadPoints);
         lastSpreadPrint = TimeCurrent();
      }
      return;
   }

   datetime currentBar = iTime(TradeSymbol, EntryTF, 0);
   if(currentBar == LastBarM1)
      return;

   LastBarM1 = currentBar;

   int positions = CountPositions();
   if(positions > 0)
   {
      ManageScaling();
      return;
   }

   int signal = GetTradeSignal();
    if(signal == 1)
   {
      Print("Sinyal BUY terdeteksi pada ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
      OpenBuy(InitialLot);
   }
   else if(signal == -1)
   {
      Print("Sinyal SELL terdeteksi pada ", TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES));
      OpenSell(InitialLot);
   }
}

//==================================================================
// SIGNAL ENGINE
//==================================================================

int GetTradeSignal()
{
   int bias = GetMarketBias();
   if(bias == 0) return 0;

   if(!DetectWolfeStyleSetup(bias)) return 0;
   if(!M1Confirmation(bias)) return 0;

   return bias;
}

//==================================================================
// MARKET BIAS (Optimized to use persistent handles)
//==================================================================

int GetMarketBias()
{
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(fastEMAHandle, 0, 1, 1, fast) <= 0) return 0;
   if(CopyBuffer(slowEMAHandle, 0, 1, 1, slow) <= 0) return 0;

   double close = iClose(TradeSymbol, BiasTF, 1);
   if(close == 0) return 0;

   if(fast[0] < slow[0] && close < fast[0]) return -1; // Bearish
   if(fast[0] > slow[0] && close > fast[0]) return 1;  // Bullish

   return 0;
}

//==================================================================
// WOLFE STYLE SETUP (Fixed indexing & removed dead code)
//==================================================================

bool DetectWolfeStyleSetup(int direction)
{
   double highs[10];
   double lows[10];

   int highCount = GetSwingHighs(highs, 10);
   int lowCount  = GetSwingLows(lows, 10);

   if(highCount < 3 || lowCount < 3)
      return false;

   double price = iClose(TradeSymbol, BiasTF, 1);
   if(price == 0) return false;

   if(direction == -1) // BEARISH
   {
      double h1 = highs[2]; // Oldest high (Point 1)
      double h3 = highs[1]; // Middle high (Point 3)
      double h5 = highs[0]; // Newest high (Point 5)

      double l2 = lows[1];  // Middle low (Point 2) - FIXED
      double l4 = lows[0];  // Newest low (Point 4) - FIXED

      bool higherHighs = (h3 > h1 && h5 > h3);
      bool higherLows  = (l4 > l2);

      if(!higherHighs && !higherLows)
         return false;

      double distance = MathAbs(price - h5) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      if(distance <= EntryZonePoints)
         return true;
   }
   else if(direction == 1) // BULLISH
   {
      double l1 = lows[2];  // Oldest low (Point 1)
      double l3 = lows[1];  // Middle low (Point 3)
      double l5 = lows[0];  // Newest low (Point 5)

      double h2 = highs[1]; // Middle high (Point 2) - FIXED
      double h4 = highs[0]; // Newest high (Point 4) - FIXED

      bool lowerLows  = (l3 < l1 && l5 < l3);
      bool lowerHighs = (h4 < h2);

      if(!lowerLows && !lowerHighs)
         return false;

      double distance = MathAbs(price - l5) / SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      if(distance <= EntryZonePoints)
         return true;
   }

   return false;
}

//==================================================================
// M1 CONFIRMATION
//==================================================================

bool M1Confirmation(int direction)
{
   double open1  = iOpen(TradeSymbol, EntryTF, 1);
   double close1 = iClose(TradeSymbol, EntryTF, 1);
   double high1  = iHigh(TradeSymbol, EntryTF, 1);
   double low1   = iLow(TradeSymbol, EntryTF, 1);

   if(direction == -1) // BEARISH
   {
      bool bearishCandle = close1 < open1;
      bool bearishShift  = close1 < iLow(TradeSymbol, EntryTF, 2);
      bool rejection     = (high1 - MathMax(open1, close1)) > (MathMin(open1, close1) - low1);

      if(bearishCandle && (bearishShift || rejection))
         return true;
   }
   else if(direction == 1) // BULLISH
   {
      bool bullishCandle = close1 > open1;
      bool bullishShift  = close1 > iHigh(TradeSymbol, EntryTF, 2);
      bool rejection     = (MathMin(open1, close1) - low1) > (high1 - MathMax(open1, close1));

      if(bullishCandle && (bullishShift || rejection))
         return true;
   }

   return false;
}

//==================================================================
// SWING DETECTION (Fixed out-of-bounds risk)
//==================================================================

int GetSwingHighs(double &values[], int maxValues)
{
   int found = 0;
   int totalBars = Bars(TradeSymbol, BiasTF);
   int limit = MathMin(SwingLookback, totalBars - SwingStrength - 1);

   for(int i = SwingStrength + 1; i < limit && found < maxValues; i++)
   {
      bool swing = true;
      double h = iHigh(TradeSymbol, BiasTF, i);

      for(int j = 1; j <= SwingStrength; j++)
      {
         if(h <= iHigh(TradeSymbol, BiasTF, i - j) || h <= iHigh(TradeSymbol, BiasTF, i + j))
         {
            swing = false;
            break;
         }
      }

      if(swing)
      {
         values[found] = h;
         found++;
      }
   }
   return found;
}

int GetSwingLows(double &values[], int maxValues)
{
   int found = 0;
   int totalBars = Bars(TradeSymbol, BiasTF);
   int limit = MathMin(SwingLookback, totalBars - SwingStrength - 1);

   for(int i = SwingStrength + 1; i < limit && found < maxValues; i++)
   {
      bool swing = true;
      double l = iLow(TradeSymbol, BiasTF, i);

      for(int j = 1; j <= SwingStrength; j++)
      {
         if(l >= iLow(TradeSymbol, BiasTF, i - j) || l >= iLow(TradeSymbol, BiasTF, i + j))
         {
            swing = false;
            break;
         }
      }

      if(swing)
      {
         values[found] = l;
         found++;
      }
   }
   return found;
}

//==================================================================
// POSITION MANAGEMENT
//==================================================================

void ManageBasket()
{
   if(CountPositions() <= 0) return;

   double basketProfit = BasketProfit();
   double requiredProfit = BasketCommission() + MinimumNetProfit + ProfitBuffer;

   if(basketProfit >= requiredProfit)
   {
      CloseBasket();
      Print("Basket closed. Gross P/L: ", basketProfit, " Required: ", requiredProfit);
      return;
   }

   if(basketProfit <= -MaxBasketLossUSD)
   {
      CloseBasket();
      Print("Emergency basket loss reached.");
   }
}

//==================================================================
// SCALING
//==================================================================

void ManageScaling()
{
   int count = CountPositions();
   if(count >= MaxPositions) return;

   double lots = TotalLots();
   if(lots + AddLot > MaxTotalLots) return;

   if(TimeCurrent() - LastAddTime < MinimumSecondsBetweenAdds) return;

   double profit = BasketProfit();
   if(profit < AddAfterProfitUSD) return; // NEVER add to a losing basket

   int direction = BasketDirection();
   if(direction == 1)
   {
      if(OpenBuy(AddLot)) LastAddTime = TimeCurrent();
   }
   else if(direction == -1)
   {
      if(OpenSell(AddLot)) LastAddTime = TimeCurrent();
   }
}

//==================================================================
// ORDER EXECUTION
//==================================================================

bool OpenBuy(double lot)
{
   lot = NormalizeLot(lot);
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   if(ask <= 0) return false;

     double sl = 0, tp = 0;
   if(StopLossPoints > 0)
   {
      sl = ask - StopLossPoints * SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS));
   }

   if(trade.Buy(lot, TradeSymbol, ask, sl, tp, "Wolfe-SMC BUY"))
   {
      Print("BUY BERHASIL! Ticket: ", trade.ResultOrder());
      return true;
   }
   else
   {
      Print("BUY GAGAL! Error: ", GetLastError(), " | Retcode: ", trade.ResultRetcode(), " | Alasan: ", trade.ResultRetcodeDescription());
      return false;
   }
}

bool OpenSell(double lot)
{
   lot = NormalizeLot(lot);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   if(bid <= 0) return false;

   double sl = 0, tp = 0;
   if(StopLossPoints > 0)
   {
      sl = bid + StopLossPoints * SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(TradeSymbol, SYMBOL_DIGITS));
   }

    if(trade.Sell(lot, TradeSymbol, bid, sl, tp, "Wolfe-SMC SELL"))
   {
      Print("SELL BERHASIL! Ticket: ", trade.ResultOrder());
      return true;
   }
   else
   {
      Print("SELL GAGAL! Error: ", GetLastError(), " | Retcode: ", trade.ResultRetcode(), " | Alasan: ", trade.ResultRetcodeDescription());
      return false;
   }
}

//==================================================================
// BASKET HELPERS
//==================================================================

double BasketProfit()
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      total += PositionGetDouble(POSITION_PROFIT);
      total += PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

double BasketCommission()
{
   double lots = TotalLots();
   return (lots / 0.01) * CommissionPer001;
}

double TotalLots()
{
   double lots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      lots += PositionGetDouble(POSITION_VOLUME);
   }
   return lots;
}

int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      count++;
   }
   return count;
}

int BasketDirection()
{
   double buyLots = 0, sellLots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double lots = PositionGetDouble(POSITION_VOLUME);

      if(type == POSITION_TYPE_BUY) buyLots += lots;
      if(type == POSITION_TYPE_SELL) sellLots += lots;
   }

   if(buyLots > sellLots) return 1;
   if(sellLots > buyLots) return -1;
   return 0;
}

void CloseBasket()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != TradeSymbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      trade.PositionClose(ticket);
   }
}

//==================================================================
// FILTERS & UTILITIES
//==================================================================

bool SpreadOK()
{
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);

   if(point <= 0) return false;
   return ((ask - bid) / point) <= MaxSpreadPoints;
}

bool TradingTime()
{
   if(!UseTradingHours) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentHour = dt.hour;

   if(StartHour < EndHour)
      return (currentHour >= StartHour && currentHour < EndHour);
   else
      return (currentHour >= StartHour || currentHour < EndHour);
}

bool DailyLossExceeded()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double loss = DailyStartEquity - equity;
   
   // --- OPSIONAL: Peringatan Dini (Early Warning) saat loss mencapai 80% ---
   // (Hapus tanda komentar /* dan */ di bawah ini jika ingin diaktifkan)
 
   static double lastWarningLevel = 0;
   double warningThreshold = MaxDailyLossUSD * 0.80; // 80% dari batas
   
   if(loss >= warningThreshold && loss > lastWarningLevel && loss < MaxDailyLossUSD)
   {
      Print("⚠️ PERINGATAN DINI: Daily Loss sudah mencapai $", DoubleToString(loss, 2), 
            " (80% dari batas $", MaxDailyLossUSD, "). Segera pertimbangkan untuk stop manual.");
      lastWarningLevel = loss; // Update agar pesan tidak muncul berulang-ulang di level yang sama
   }
  
   // --------------------------------------------------------------------------

   // --- Log Utama saat Batas Loss Tercapai ---
   if(loss >= MaxDailyLossUSD)
   {
      Print("==================================================");
      Print("🚨 PERINGATAN: BATAS LOSS HARIAN TERCAPAI! 🚨");
      Print("Equity Awal Hari Ini   : $", DoubleToString(DailyStartEquity, 2));
      Print("Equity Saat Ini        : $", DoubleToString(equity, 2));
      Print("Total Loss Hari Ini    : $", DoubleToString(loss, 2), " USD");
      Print("Batas Maksimal Loss    : $", DoubleToString(MaxDailyLossUSD, 2), " USD");
      Print("Tindakan               : EA akan berhenti trading sampai hari berikutnya.");
      Print("==================================================");
      
      return true;
   }
   
   return false;
}

void UpdateDailyReference()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != DayStart)
   {
      DayStart = today;
      DailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_STEP);

   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   lot = MathFloor(lot / step) * step;
   return NormalizeDouble(lot, 2);
}
//+------------------------------------------------------------------+