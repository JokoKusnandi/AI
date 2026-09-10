//+------------------------------------------------------------------+
//|                 XAU_M/15_Trend_SR_EA.mq5                          |
//|                 XAUUSD M15 Strategy                              |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Strategy"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//====================================================================
// INPUT
//====================================================================
input group "=== Trading Setting ==="
input double Lots                    = 0.01;
input ulong  MagicNumber             = 20260909;
input int    MaxDeviationPoints      = 50;

input group "=== M15 Entry Timing ==="
input int StartEntryAfterSeconds     = 60;       // Entry after 1 minute
input int CloseBeforeEndSeconds      = 60;       // Close 1 minute before M15 ends

input group "=== Price Trigger ==="
input int EntryOffsetPoints          = 30;       // Open +/- 30 points
input int BreakoutOffsetPoints       = 500;      // S/R +/- 500 points
input int SRTolerancePoints          = 100;      // Distance from S/R

input group "=== Support Resistance ==="
input int SRLookbackBars             = 20;

input group "=== RSI ==="
input int    RSIPeriod               = 14;
input int    RSICompareShift         = 3;
input double RSIDifference           = 3.0;

input group "=== Filters ==="
input bool UseH1TrendFilter          = true;
input bool UseM15TrendFilter         = true;
input bool UseRSIFilter              = true;
input bool UsePatternFilter          = true;
input bool UseSupportResistance      = true;
input bool UseBreakout               = true;

//====================================================================
// INDICATOR HANDLES
//====================================================================

// H1
int hMA20_H1;
int hMA50_H1;
int hMA100_H1;
int hMA200_H1;

// M15
int hMA9_M15;
int hMA20_M15;
int hMA50_M15;

// RSI M15
int hRSI_M15;

//====================================================================
// VARIABLES
//====================================================================
datetime lastEntryM15Bar = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   //===============================================================
   // H1 Moving Averages
   //===============================================================
   hMA20_H1  = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
   hMA50_H1  = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   hMA100_H1 = iMA(_Symbol, PERIOD_H1, 100, 0, MODE_EMA, PRICE_CLOSE);
   hMA200_H1 = iMA(_Symbol, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);

   //===============================================================
   // M15 Moving Averages
   //===============================================================
   hMA9_M15  = iMA(_Symbol, PERIOD_M15, 9, 0, MODE_EMA, PRICE_CLOSE);
   hMA20_M15 = iMA(_Symbol, PERIOD_M15, 20, 0, MODE_EMA, PRICE_CLOSE);
   hMA50_M15 = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);

   //===============================================================
   // RSI
   //===============================================================
   hRSI_M15 = iRSI(
      _Symbol,
      PERIOD_M15,
      RSIPeriod,
      PRICE_CLOSE
   );

   if(
      hMA20_H1  == INVALID_HANDLE ||
      hMA50_H1  == INVALID_HANDLE ||
      hMA100_H1 == INVALID_HANDLE ||
      hMA200_H1 == INVALID_HANDLE ||
      hMA9_M15  == INVALID_HANDLE ||
      hMA20_M15 == INVALID_HANDLE ||
      hMA50_M15 == INVALID_HANDLE ||
      hRSI_M15  == INVALID_HANDLE
   )
   {
      Print("ERROR: Failed creating indicator handles.");
      return(INIT_FAILED);
   }

   Print("=============================================");
   Print("XAUUSD M15 EA initialized.");
   Print("Symbol        : ", _Symbol);
   Print("Point         : ", _Point);
   Print("30 points     : ", EntryOffsetPoints * _Point);
   Print("500 points    : ", BreakoutOffsetPoints * _Point);
   Print("=============================================");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hMA20_H1);
   IndicatorRelease(hMA50_H1);
   IndicatorRelease(hMA100_H1);
   IndicatorRelease(hMA200_H1);

   IndicatorRelease(hMA9_M15);
   IndicatorRelease(hMA20_M15);
   IndicatorRelease(hMA50_M15);

   IndicatorRelease(hRSI_M15);
}

//+------------------------------------------------------------------+
//| Read Indicator Buffer                                            |
//+------------------------------------------------------------------+
double GetIndicatorValue(int handle, int shift)
{
   double buffer[];

   if(CopyBuffer(handle, 0, shift, 1, buffer) != 1)
      return EMPTY_VALUE;

   return buffer[0];
}

//+------------------------------------------------------------------+
//| Get current M15 elapsed seconds                                  |
//+------------------------------------------------------------------+
int GetM15ElapsedSeconds()
{
   datetime candleTime = iTime(_Symbol, PERIOD_M15, 0);

   if(candleTime <= 0)
      return 0;

   return (int)(TimeCurrent() - candleTime);
}

//+------------------------------------------------------------------+
//| Is Entry Time                                                    |
//+------------------------------------------------------------------+
bool IsEntryTime()
{
   int elapsed = GetM15ElapsedSeconds();

   int totalM15Seconds = 15 * 60;

   // Entry from minute 1 until before minute 14
   if(elapsed < StartEntryAfterSeconds)
      return false;

   if(elapsed >= totalM15Seconds - CloseBeforeEndSeconds)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Is Exit Time                                                     |
//+------------------------------------------------------------------+
bool IsExitTime()
{
   int elapsed = GetM15ElapsedSeconds();

   // M15 = 900 seconds
   int closeStart = (15 * 60) - CloseBeforeEndSeconds;

   return (elapsed >= closeStart);
}

//+------------------------------------------------------------------+
//| BUY H1 Trend                                                     |
//+------------------------------------------------------------------+
bool IsH1Bullish()
{
   if(!UseH1TrendFilter)
      return true;

   double ma20  = GetIndicatorValue(hMA20_H1, 0);
   double ma50  = GetIndicatorValue(hMA50_H1, 0);
   double ma100 = GetIndicatorValue(hMA100_H1, 0);
   double ma200 = GetIndicatorValue(hMA200_H1, 0);

   if(
      ma20  == EMPTY_VALUE ||
      ma50  == EMPTY_VALUE ||
      ma100 == EMPTY_VALUE ||
      ma200 == EMPTY_VALUE
   )
      return false;

   return (
      ma20 > ma50 &&
      ma50 > ma100 &&
      ma100 > ma200
   );
}

//+------------------------------------------------------------------+
//| SELL H1 Trend                                                    |
//+------------------------------------------------------------------+
bool IsH1Bearish()
{
   if(!UseH1TrendFilter)
      return true;

   double ma20  = GetIndicatorValue(hMA20_H1, 0);
   double ma50  = GetIndicatorValue(hMA50_H1, 0);
   double ma100 = GetIndicatorValue(hMA100_H1, 0);
   double ma200 = GetIndicatorValue(hMA200_H1, 0);

   if(
      ma20  == EMPTY_VALUE ||
      ma50  == EMPTY_VALUE ||
      ma100 == EMPTY_VALUE ||
      ma200 == EMPTY_VALUE
   )
      return false;

   return (
      ma20 < ma50 &&
      ma50 < ma100 &&
      ma100 < ma200
   );
}

//+------------------------------------------------------------------+
//| BUY M15 Trend                                                    |
//+------------------------------------------------------------------+
bool IsM15Bullish()
{
   if(!UseM15TrendFilter)
      return true;

   double ma9  = GetIndicatorValue(hMA9_M15, 0);
   double ma20 = GetIndicatorValue(hMA20_M15, 0);
   double ma50 = GetIndicatorValue(hMA50_M15, 0);

   if(
      ma9  == EMPTY_VALUE ||
      ma20 == EMPTY_VALUE ||
      ma50 == EMPTY_VALUE
   )
      return false;

   return (
      ma9 > ma20 &&
      ma20 > ma50
   );
}

//+------------------------------------------------------------------+
//| SELL M15 Trend                                                   |
//+------------------------------------------------------------------+
bool IsM15Bearish()
{
   if(!UseM15TrendFilter)
      return true;

   double ma9  = GetIndicatorValue(hMA9_M15, 0);
   double ma20 = GetIndicatorValue(hMA20_M15, 0);
   double ma50 = GetIndicatorValue(hMA50_M15, 0);

   if(
      ma9  == EMPTY_VALUE ||
      ma20 == EMPTY_VALUE ||
      ma50 == EMPTY_VALUE
   )
      return false;

   return (
      ma9 < ma20 &&
      ma20 < ma50
   );
}

//+------------------------------------------------------------------+
//| RSI BUY                                                          |
//| Current RSI > RSI 3 candles ago + 3                              |
//+------------------------------------------------------------------+
bool IsRSIBuy()
{
   if(!UseRSIFilter)
      return true;

   double currentRSI =
      GetIndicatorValue(hRSI_M15, 0);

   double previousRSI =
      GetIndicatorValue(hRSI_M15, RSICompareShift);

   if(
      currentRSI  == EMPTY_VALUE ||
      previousRSI == EMPTY_VALUE
   )
      return false;

   return (
      currentRSI >
      previousRSI + RSIDifference
   );
}

//+------------------------------------------------------------------+
//| RSI SELL                                                         |
//| Current RSI < RSI 3 candles ago - 3                              |
//+------------------------------------------------------------------+
bool IsRSISell()
{
   if(!UseRSIFilter)
      return true;

   double currentRSI =
      GetIndicatorValue(hRSI_M15, 0);

   double previousRSI =
      GetIndicatorValue(hRSI_M15, RSICompareShift);

   if(
      currentRSI  == EMPTY_VALUE ||
      previousRSI == EMPTY_VALUE
   )
      return false;

   return (
      currentRSI <
      previousRSI - RSIDifference
   );
}

//====================================================================
// CANDLESTICK PATTERNS
//====================================================================

//+------------------------------------------------------------------+
//| Bullish Engulfing                                                |
//| shift 1 = latest CLOSED candle                                   |
//| shift 2 = previous candle                                        |
//+------------------------------------------------------------------+
bool BullishEngulfing()
{
   double o1 = iOpen(_Symbol, PERIOD_M15, 1);
   double c1 = iClose(_Symbol, PERIOD_M15, 1);

   double o2 = iOpen(_Symbol, PERIOD_M15, 2);
   double c2 = iClose(_Symbol, PERIOD_M15, 2);

   bool previousBearish = c2 < o2;
   bool currentBullish  = c1 > o1;

   bool engulf =
      o1 <= c2 &&
      c1 >= o2;

   return (
      previousBearish &&
      currentBullish &&
      engulf
   );
}

//+------------------------------------------------------------------+
//| Bearish Engulfing                                                |
//+------------------------------------------------------------------+
bool BearishEngulfing()
{
   double o1 = iOpen(_Symbol, PERIOD_M15, 1);
   double c1 = iClose(_Symbol, PERIOD_M15, 1);

   double o2 = iOpen(_Symbol, PERIOD_M15, 2);
   double c2 = iClose(_Symbol, PERIOD_M15, 2);

   bool previousBullish = c2 > o2;
   bool currentBearish  = c1 < o1;

   bool engulf =
      o1 >= c2 &&
      c1 <= o2;

   return (
      previousBullish &&
      currentBearish &&
      engulf
   );
}

//+------------------------------------------------------------------+
//| Bullish Reversal = Hammer / Bullish Pin Bar                      |
//+------------------------------------------------------------------+
bool BullishReversal()
{
   double o = iOpen(_Symbol, PERIOD_M15, 1);
   double c = iClose(_Symbol, PERIOD_M15, 1);
   double h = iHigh(_Symbol, PERIOD_M15, 1);
   double l = iLow(_Symbol, PERIOD_M15, 1);

   double body = MathAbs(c - o);
   double range = h - l;

   if(range <= 0)
      return false;

   // Prevent zero-body problem
   double safeBody = MathMax(body, _Point);

   double lowerWick =
      MathMin(o, c) - l;

   double upperWick =
      h - MathMax(o, c);

   bool smallBody =
      body <= range * 0.40;

   bool longLowerWick =
      lowerWick >= safeBody * 2.0;

   bool shortUpperWick =
      upperWick <= range * 0.30;

   return (
      smallBody &&
      longLowerWick &&
      shortUpperWick
   );
}

//+------------------------------------------------------------------+
//| Bearish Reversal = Shooting Star / Bearish Pin Bar               |
//+------------------------------------------------------------------+
bool BearishReversal()
{
   double o = iOpen(_Symbol, PERIOD_M15, 1);
   double c = iClose(_Symbol, PERIOD_M15, 1);
   double h = iHigh(_Symbol, PERIOD_M15, 1);
   double l = iLow(_Symbol, PERIOD_M15, 1);

   double body = MathAbs(c - o);
   double range = h - l;

   if(range <= 0)
      return false;

   double safeBody = MathMax(body, _Point);

   double upperWick =
      h - MathMax(o, c);

   double lowerWick =
      MathMin(o, c) - l;

   bool smallBody =
      body <= range * 0.40;

   bool longUpperWick =
      upperWick >= safeBody * 2.0;

   bool shortLowerWick =
      lowerWick <= range * 0.30;

   return (
      smallBody &&
      longUpperWick &&
      shortLowerWick
   );
}

//+------------------------------------------------------------------+
//| Bullish Continuation                                             |
//+------------------------------------------------------------------+
bool BullishContinuation()
{
   double o1 = iOpen(_Symbol, PERIOD_M15, 1);
   double c1 = iClose(_Symbol, PERIOD_M15, 1);
   double h1 = iHigh(_Symbol, PERIOD_M15, 1);
   double l1 = iLow(_Symbol, PERIOD_M15, 1);

   double o2 = iOpen(_Symbol, PERIOD_M15, 2);
   double c2 = iClose(_Symbol, PERIOD_M15, 2);
   double h2 = iHigh(_Symbol, PERIOD_M15, 2);
   double l2 = iLow(_Symbol, PERIOD_M15, 2);

   return (
      c1 > o1 &&
      c2 > o2 &&
      c1 > c2 &&
      h1 > h2 &&
      l1 >= l2
   );
}

//+------------------------------------------------------------------+
//| Bearish Continuation                                             |
//+------------------------------------------------------------------+
bool BearishContinuation()
{
   double o1 = iOpen(_Symbol, PERIOD_M15, 1);
   double c1 = iClose(_Symbol, PERIOD_M15, 1);
   double h1 = iHigh(_Symbol, PERIOD_M15, 1);
   double l1 = iLow(_Symbol, PERIOD_M15, 1);

   double o2 = iOpen(_Symbol, PERIOD_M15, 2);
   double c2 = iClose(_Symbol, PERIOD_M15, 2);
   double h2 = iHigh(_Symbol, PERIOD_M15, 2);
   double l2 = iLow(_Symbol, PERIOD_M15, 2);

   return (
      c1 < o1 &&
      c2 < o2 &&
      c1 < c2 &&
      h1 <= h2 &&
      l1 < l2
   );
}

//+------------------------------------------------------------------+
//| Any Bullish Pattern                                              |
//+------------------------------------------------------------------+
bool HasBullishPattern()
{
   if(!UsePatternFilter)
      return true;

   return (
      BullishEngulfing()    ||
      BullishReversal()     ||
      BullishContinuation()
   );
}

//+------------------------------------------------------------------+
//| Any Bearish Pattern                                              |
//+------------------------------------------------------------------+
bool HasBearishPattern()
{
   if(!UsePatternFilter)
      return true;

   return (
      BearishEngulfing()    ||
      BearishReversal()     ||
      BearishContinuation()
   );
}

//====================================================================
// SUPPORT & RESISTANCE
//====================================================================

//+------------------------------------------------------------------+
//| Support                                                          |
//+------------------------------------------------------------------+
double GetSupport()
{
   double lowest = DBL_MAX;

   for(int i = 1; i <= SRLookbackBars; i++)
   {
      double low =
         iLow(_Symbol, PERIOD_M15, i);

      if(low < lowest)
         lowest = low;
   }

   return lowest;
}

//+------------------------------------------------------------------+
//| Resistance                                                       |
//+------------------------------------------------------------------+
double GetResistance()
{
   double highest = -DBL_MAX;

   for(int i = 1; i <= SRLookbackBars; i++)
   {
      double high =
         iHigh(_Symbol, PERIOD_M15, i);

      if(high > highest)
         highest = high;
   }

   return highest;
}

//+------------------------------------------------------------------+
//| BUY at support                                                   |
//+------------------------------------------------------------------+
bool IsBuyAtSupport(double price, double support)
{
   if(!UseSupportResistance)
      return false;

   double tolerance =
      SRTolerancePoints * _Point;

   return (
      price >= support &&
      price <= support + tolerance
   );
}

//+------------------------------------------------------------------+
//| SELL at resistance                                               |
//+------------------------------------------------------------------+
bool IsSellAtResistance(double price, double resistance)
{
   if(!UseSupportResistance)
      return false;

   double tolerance =
      SRTolerancePoints * _Point;

   return (
      price <= resistance &&
      price >= resistance - tolerance
   );
}

//+------------------------------------------------------------------+
//| Breakout Resistance BUY                                          |
//+------------------------------------------------------------------+
bool IsResistanceBreakout(double price, double resistance)
{
   if(!UseBreakout)
      return false;

   double breakoutLevel =
      resistance +
      BreakoutOffsetPoints * _Point;

   return price > breakoutLevel;
}

//+------------------------------------------------------------------+
//| Breakout Support SELL                                            |
//+------------------------------------------------------------------+
bool IsSupportBreakout(double price, double support)
{
   if(!UseBreakout)
      return false;

   double breakoutLevel =
      support -
      BreakoutOffsetPoints * _Point;

   return price < breakoutLevel;
}

//====================================================================
// POSITION MANAGEMENT
//====================================================================

//+------------------------------------------------------------------+
//| Check EA Position                                                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      long magic =
         PositionGetInteger(POSITION_MAGIC);

      if(
         symbol == _Symbol &&
         magic == (long)MagicNumber
      )
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Close All EA Positions                                           |
//+------------------------------------------------------------------+
void CloseAllEAPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket =
         PositionGetTicket(i);

      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol =
         PositionGetString(POSITION_SYMBOL);

      long magic =
         PositionGetInteger(POSITION_MAGIC);

      if(
         symbol != _Symbol ||
         magic != (long)MagicNumber
      )
         continue;

      if(!trade.PositionClose(ticket))
      {
         Print(
            "ERROR closing ticket ",
            ticket,
            " Retcode=",
            trade.ResultRetcode(),
            " ",
            trade.ResultRetcodeDescription()
         );
      }
      else
      {
         Print(
            "Position closed before M15 candle ends. Ticket=",
            ticket
         );
      }
   }
}

//====================================================================
// ENTRY LOGIC
//====================================================================

//+------------------------------------------------------------------+
//| BUY Condition                                                    |
//+------------------------------------------------------------------+
bool BuySignal()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double currentPrice = tick.ask;

   // Current M15 candle
   double candleOpen =
      iOpen(_Symbol, PERIOD_M15, 0);

   double candleLow =
      iLow(_Symbol, PERIOD_M15, 0);

   //===============================================================
   // USER PRICE RULE
   // Current > Open + 30
   // Current > Low
   // Open > Low
   //===============================================================
   bool priceCondition =
      currentPrice >
         candleOpen +
         EntryOffsetPoints * _Point
      &&
      currentPrice > candleLow
      &&
      candleOpen > candleLow;

   if(!priceCondition)
      return false;

   // H1 bias
   if(!IsH1Bullish())
      return false;

   // M15 trend
   if(!IsM15Bullish())
      return false;

   // RSI
   if(!IsRSIBuy())
      return false;

   // Candlestick
   if(!HasBullishPattern())
      return false;

   // Support Resistance
   double support =
      GetSupport();

   double resistance =
      GetResistance();

   bool supportEntry =
      IsBuyAtSupport(
         currentPrice,
         support
      );

   bool breakoutEntry =
      IsResistanceBreakout(
         currentPrice,
         resistance
      );

   // BUY either from SUPPORT or breakout RESISTANCE
   if(
      UseSupportResistance ||
      UseBreakout
   )
   {
      if(
         !supportEntry &&
         !breakoutEntry
      )
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| SELL Condition                                                   |
//+------------------------------------------------------------------+
bool SellSignal()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol, tick))
      return false;

   double currentPrice = tick.bid;

   double candleOpen =
      iOpen(_Symbol, PERIOD_M15, 0);

   double candleHigh =
      iHigh(_Symbol, PERIOD_M15, 0);

   //===============================================================
   // USER PRICE RULE
   // Current < Open - 30
   // Current < High
   // Open < High
   //===============================================================
   bool priceCondition =
      currentPrice <
         candleOpen -
         EntryOffsetPoints * _Point
      &&
      currentPrice < candleHigh
      &&
      candleOpen < candleHigh;

   if(!priceCondition)
      return false;

   // H1 bias
   if(!IsH1Bearish())
      return false;

   // M15 trend
   if(!IsM15Bearish())
      return false;

   // RSI
   if(!IsRSISell())
      return false;

   // Candlestick
   if(!HasBearishPattern())
      return false;

   double support =
      GetSupport();

   double resistance =
      GetResistance();

   bool resistanceEntry =
      IsSellAtResistance(
         currentPrice,
         resistance
      );

   bool breakoutEntry =
      IsSupportBreakout(
         currentPrice,
         support
      );

   // SELL either at RESISTANCE or breakout SUPPORT
   if(
      UseSupportResistance ||
      UseBreakout
   )
   {
      if(
         !resistanceEntry &&
         !breakoutEntry
      )
         return false;
   }

   return true;
}

//====================================================================
// EXECUTION
//====================================================================

//+------------------------------------------------------------------+
//| Open BUY                                                         |
//+------------------------------------------------------------------+
void OpenBuy()
{
   if(trade.Buy(
      Lots,
      _Symbol,
      0,
      0,
      0,
      "XAU M15 BUY"
   ))
   {
      Print(
         "BUY executed. Price=",
         trade.ResultPrice(),
         " Deal=",
         trade.ResultDeal()
      );
   }
   else
   {
      Print(
         "BUY FAILED. Retcode=",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
//| Open SELL                                                        |
//+------------------------------------------------------------------+
void OpenSell()
{
   if(trade.Sell(
      Lots,
      _Symbol,
      0,
      0,
      0,
      "XAU M15 SELL"
   ))
   {
      Print(
         "SELL executed. Price=",
         trade.ResultPrice(),
         " Deal=",
         trade.ResultDeal()
      );
   }
   else
   {
      Print(
         "SELL FAILED. Retcode=",
         trade.ResultRetcode(),
         " ",
         trade.ResultRetcodeDescription()
      );
   }
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   //===============================================================
   // 1. EXIT ONE MINUTE BEFORE M15 CANDLE CLOSE
   //===============================================================
   if(IsExitTime())
   {
      if(HasOpenPosition())
         CloseAllEAPositions();

      return;
   }

   //===============================================================
   // 2. ENTRY ONLY AFTER FIRST MINUTE
   //===============================================================
   if(!IsEntryTime())
      return;

   datetime currentM15Bar =
      iTime(_Symbol, PERIOD_M15, 0);

   //===============================================================
   // 3. ONE ENTRY MAXIMUM PER M15 CANDLE
   //===============================================================
   if(lastEntryM15Bar == currentM15Bar)
      return;

   //===============================================================
   // 4. DON'T STACK POSITIONS
   //===============================================================
   if(HasOpenPosition())
      return;

   //===============================================================
   // 5. BUY
   //===============================================================
   if(BuySignal())
   {
      OpenBuy();

      // only lock candle when trade really executed
      if(trade.ResultDeal() > 0)
         lastEntryM15Bar = currentM15Bar;

      return;
   }

   //===============================================================
   // 6. SELL
   //===============================================================
   if(SellSignal())
   {
      OpenSell();

      if(trade.ResultDeal() > 0)
         lastEntryM15Bar = currentM15Bar;

      return;
   }
}
//+------------------------------------------------------------------+