//+------------------------------------------------------------------+
//|                                              CandleStrategy.mq5 |
//|                                    Simple Candle Bullish/Bearish |
//|                                             XAUUSD M5 Strategy   |
//+------------------------------------------------------------------+
#property copyright "Candle Strategy"
#property version   "1.00"
#property strict

// Input Parameters
input double InpLotSize = 0.01;           // Lot Size
input double InpTakeProfit = 3;         // Take Profit (USD)
input double InpStopLoss = 1.0;           // Stop Loss (USD)
input string InpSymbol = "XAUUSD";        // Symbol
input int    InpMagicNumber = 123456;     // Magic Number

// Global Variables
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Check if symbol exists
   if(SymbolSelect(InpSymbol, false) == false)
   {
      Print("Symbol ", InpSymbol, " tidak tersedia!");
      return(INIT_FAILED);
   }
   
   Print("EA Initialized - Symbol: ", InpSymbol, " TF: M5");
   Print("Lot: ", InpLotSize, " TP: ", InpTakeProfit, " SL: ", InpStopLoss);
   
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
   // Get current bar time
   datetime currentBarTime = iTime(InpSymbol, PERIOD_M5, 0);
   
   // Check if new bar formed
   if(currentBarTime == lastBarTime)
      return;
   
   lastBarTime = currentBarTime;
   
   // Get previous completed candle data (index 1)
   double prevOpen = iOpen(InpSymbol, PERIOD_M5, 1);
   double prevClose = iClose(InpSymbol, PERIOD_M5, 1);
   double prevHigh = iHigh(InpSymbol, PERIOD_M5, 1);
   double prevLow = iLow(InpSymbol, PERIOD_M5, 1);
   
   // Check if we have valid data
   if(prevOpen == 0 || prevClose == 0)
      return;
   
   // Check existing positions
   if(CountPositions() > 0)
   {
      // Already have position, skip
      return;
   }
   
   // Buy Signal: Bullish candle (close > open) - Green candle
   if(prevClose > prevOpen)
   {
      OpenBuyOrder();
   }
   
   // Sell Signal: Bearish candle (close < open) - Red candle
   if(prevClose < prevOpen)
   {
      OpenSellOrder();
   }
}

//+------------------------------------------------------------------+
//| Open Buy Order                                                   |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   double sl = ask - (InpStopLoss * 10);  // Convert USD to points (XAUUSD: 1 USD = 10 points)
   double tp = ask + (InpTakeProfit * 10);
   
   MqlTradeRequest request;
   MqlTradeResult result;
   
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = InpSymbol;
   request.volume = InpLotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = ask;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = InpMagicNumber;
   request.comment = "Buy - Bullish Candle";
   request.type_filling = ORDER_FILLING_IOC;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         Print("BUY Order Opened Successfully!");
         Print("Price: ", ask, " SL: ", sl, " TP: ", tp);
      }
      else
      {
         Print("BUY Order Failed. Retcode: ", result.retcode);
      }
   }
   else
   {
      Print("OrderSend Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Open Sell Order                                                  |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
   double bid = SymbolInfoDouble(InpSymbol, SYMBOL_BID);
   double sl = bid + (InpStopLoss * 10);  // Convert USD to points
   double tp = bid - (InpTakeProfit * 10);
   
   MqlTradeRequest request;
   MqlTradeResult result;
   
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = InpSymbol;
   request.volume = InpLotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = bid;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = InpMagicNumber;
   request.comment = "Sell - Bearish Candle";
   request.type_filling = ORDER_FILLING_IOC;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         Print("SELL Order Opened Successfully!");
         Print("Price: ", bid, " SL: ", sl, " TP: ", tp);
      }
      else
      {
         Print("SELL Order Failed. Retcode: ", result.retcode);
      }
   }
   else
   {
      Print("OrderSend Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Count open positions                                             |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == InpSymbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}
//+------------------------------------------------------------------+