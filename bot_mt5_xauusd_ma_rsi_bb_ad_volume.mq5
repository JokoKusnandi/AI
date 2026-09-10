//+------------------------------------------------------------------+
//|                                           TrendFollowXAUUSD.mq5  |
//|                        Strategi Multi-Timeframe XAUUSD           |
//+------------------------------------------------------------------+
#property copyright "Qwen Assistant"
#property link      ""
#property version   "1.01"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input double InpLotSize = 0.01;       // Lot Size
input int    InpMagicNumber = 123456; // Magic Number
input bool   InpShowLogs = true;      // Tampilkan Log Detail di Journal
input double InpRiskAmount = 25.0;    // Risiko per trade dalam USD ($)
input double InpRewardAmount = 0.8;  // Target Profit per trade dalam USD ($)

//--- Global Variables
CTrade trade;
int handle_rsi_h4, handle_rsi_h1, handle_rsi_m15, handle_rsi_m5;
int handle_ma20_m5, handle_ma50_m5, handle_ma20_m15, handle_ma50_m15, handle_ma20_h1, handle_ma50_h1;
int handle_macd_m5, handle_macd_m15, handle_macd_h1;

//--- Buffer Arrays
double rsi_h4_buf[], rsi_h1_buf[], rsi_m15_buf[], rsi_m5_buf[];
double ma20_m5_buf[], ma50_m5_buf[], ma20_m15_buf[], ma50_m15_buf[], ma20_h1_buf[], ma50_h1_buf[];
double macd_m5_buf[], macd_main_m5[], macd_signal_m5[];
double macd_m15_buf[], macd_main_m15[], macd_signal_m15[];
double macd_h1_buf[], macd_main_h1[], macd_signal_h1[];

//--- State Tracking
bool last_trend_bullish = false;
bool last_trend_bearish = false;
datetime last_candle_time_m5 = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Set Magic Number
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   //--- Initialize Indicators
   handle_rsi_h4  = iRSI(_Symbol, PERIOD_H4,  14, PRICE_CLOSE);
   handle_rsi_h1  = iRSI(_Symbol, PERIOD_H1,  14, PRICE_CLOSE);
   handle_rsi_m15 = iRSI(_Symbol, PERIOD_M15, 14, PRICE_CLOSE);
   handle_rsi_m5  = iRSI(_Symbol, PERIOD_M5,  14, PRICE_CLOSE);

   handle_ma20_m5  = iMA(_Symbol, PERIOD_M5,  20, 0, MODE_SMA, PRICE_CLOSE);
   handle_ma50_m5  = iMA(_Symbol, PERIOD_M5,  50, 0, MODE_SMA, PRICE_CLOSE);
   handle_ma20_m15 = iMA(_Symbol, PERIOD_M15, 20, 0, MODE_SMA, PRICE_CLOSE);
   handle_ma50_m15 = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_SMA, PRICE_CLOSE);
   handle_ma20_h1  = iMA(_Symbol, PERIOD_H1,  20, 0, MODE_SMA, PRICE_CLOSE);
   handle_ma50_h1  = iMA(_Symbol, PERIOD_H1,  50, 0, MODE_SMA, PRICE_CLOSE);

   handle_macd_m5  = iMACD(_Symbol, PERIOD_M5,  12, 26, 9, PRICE_CLOSE);
   handle_macd_m15 = iMACD(_Symbol, PERIOD_M15, 12, 26, 9, PRICE_CLOSE);
   handle_macd_h1  = iMACD(_Symbol, PERIOD_H1,  12, 26, 9, PRICE_CLOSE);

   if(handle_rsi_h4 == INVALID_HANDLE || handle_rsi_h1 == INVALID_HANDLE || 
      handle_rsi_m15 == INVALID_HANDLE || handle_rsi_m5 == INVALID_HANDLE ||
      handle_ma20_m5 == INVALID_HANDLE || handle_ma50_m5 == INVALID_HANDLE ||
      handle_ma20_m15 == INVALID_HANDLE || handle_ma50_m15 == INVALID_HANDLE ||
      handle_ma20_h1 == INVALID_HANDLE || handle_ma50_h1 == INVALID_HANDLE ||
      handle_macd_m5 == INVALID_HANDLE || handle_macd_m15 == INVALID_HANDLE || handle_macd_h1 == INVALID_HANDLE)
   {
      Print("Error initializing indicators");
      return(INIT_FAILED);
   }

   //--- Set array as series (index 0 is current candle)
   ArraySetAsSeries(rsi_h4_buf, true);
   ArraySetAsSeries(rsi_h1_buf, true);
   ArraySetAsSeries(rsi_m15_buf, true);
   ArraySetAsSeries(rsi_m5_buf, true);
   
   ArraySetAsSeries(ma20_m5_buf, true);
   ArraySetAsSeries(ma50_m5_buf, true);
   ArraySetAsSeries(ma20_m15_buf, true);
   ArraySetAsSeries(ma50_m15_buf, true);
   ArraySetAsSeries(ma20_h1_buf, true);
   ArraySetAsSeries(ma50_h1_buf, true);

   ArraySetAsSeries(macd_main_m5, true);
   ArraySetAsSeries(macd_main_m15, true);
   ArraySetAsSeries(macd_main_h1, true);

   Print("EA Initialized Successfully for XAUUSD");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handle_rsi_h4);
   IndicatorRelease(handle_rsi_h1);
   IndicatorRelease(handle_rsi_m15);
   IndicatorRelease(handle_rsi_m5);
   
   IndicatorRelease(handle_ma20_m5);
   IndicatorRelease(handle_ma50_m5);
   IndicatorRelease(handle_ma20_m15);
   IndicatorRelease(handle_ma50_m15);
   IndicatorRelease(handle_ma20_h1);
   IndicatorRelease(handle_ma50_h1);
   
   IndicatorRelease(handle_macd_m5);
   IndicatorRelease(handle_macd_m15);
   IndicatorRelease(handle_macd_h1);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime current_candle_time = iTime(_Symbol, PERIOD_M5, 0);
   
   if(!UpdateIndicators()) return;

   double h4_rsi = rsi_h4_buf[1];
   double h1_rsi = rsi_h1_buf[1];
   double m15_rsi = rsi_m15_buf[1];
   double m5_rsi = rsi_m5_buf[0];

   double ma20_m5 = ma20_m5_buf[0];
   double ma50_m5 = ma50_m5_buf[0];
   double ma20_m15 = ma20_m15_buf[1];
   double ma50_m15 = ma50_m15_buf[1];
   double ma20_h1 = ma20_h1_buf[1];
   double ma50_h1 = ma50_h1_buf[1];

   double macd_m5_val = macd_main_m5[1];
   double macd_m15_val = macd_main_m15[1];
   double macd_h1_val = macd_main_h1[1];

   if(InpShowLogs)
   {
      PrintFormat("RSI: H4=%.2f, H1=%.2f, M15=%.2f, M5(Curr)=%.2f", h4_rsi, h1_rsi, m15_rsi, m5_rsi);
      PrintFormat("MA: M5(20/50)=%.2f/%.2f, M15(20/50)=%.2f/%.2f, H1(20/50)=%.2f/%.2f", 
                  ma20_m5, ma50_m5, ma20_m15, ma50_m15, ma20_h1, ma50_h1);
      PrintFormat("MACD: M5=%.4f, M15=%.4f, H1=%.4f", macd_m5_val, macd_m15_val, macd_h1_val);
   }

   bool is_bullish_trend = false;
   bool is_bearish_trend = false;

   if(h4_rsi > 50 && h1_rsi > 50 && m15_rsi > 50 && 
       ma20_m15 > ma50_m15 && ma20_h1 > ma50_h1 &&
       macd_m15_val > 0 && macd_h1_val > 0)
   {
      is_bullish_trend = true;
   }

   if(h4_rsi < 50 && h1_rsi < 50 && m15_rsi < 50 && 
       ma20_m15 < ma50_m15 && ma20_h1 < ma50_h1 &&
       macd_m15_val < 0 && macd_h1_val < 0)
   {
      is_bearish_trend = true;
   }

   bool isNewCandle = (current_candle_time != last_candle_time_m5);
   if(isNewCandle)
   {
      last_candle_time_m5 = current_candle_time;
   }

   if(PositionsTotal() > 0) 
   {
      return; 
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double prev_m5_high = iHigh(_Symbol, PERIOD_M5, 1);
   double prev_m5_low = iLow(_Symbol, PERIOD_M5, 1);

   // --- BUY LOGIC ---
   if(is_bullish_trend)
   {
      bool m5_buy_signal = (m5_rsi > 50 || m5_rsi <30) && (ma20_m5 > ma50_m5) && (h1_rsi<30 || h1_rsi >50);
      
      if(m5_buy_signal && ask > prev_m5_high)
      {
         Print(">>> SIGNAL BUY DETECTED <<<");
         double sl = 0, tp = 0;
         CalculateSLTP(sl, tp, true);
         
         if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Trend Buy"))
         {
            PrintFormat("Order Buy Executed at %s, SL: %s, TP: %s", DoubleToString(ask, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
         }
         else
         {
            Print("Order Buy Failed: ", trade.ResultRetcodeDescription());
         }
      }
   }

   // --- SELL LOGIC ---
   if(is_bearish_trend)
   {
      bool m5_sell_signal = (m5_rsi < 50 || m5_rsi >70) && (ma20_m5 < ma50_m5) && (h1_rsi >70 || h1_rsi<50) ;
      
      if(m5_sell_signal && bid < prev_m5_low)
      {
         Print(">>> SIGNAL SELL DETECTED <<<");
         double sl = 0, tp = 0;
         CalculateSLTP(sl, tp, false);
         
         if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Trend Sell"))
         {
            PrintFormat("Order Sell Executed at %s, SL: %s, TP: %s", DoubleToString(bid, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
         }
         else
         {
            Print("Order Sell Failed: ", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helper Function to Calculate SL and TP based on USD Amount       |
//+------------------------------------------------------------------+
void CalculateSLTP(double &sl, double &tp, bool isBuy)
{
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lot = InpLotSize;
   
   // Hindari pembagian dengan nol atau nilai tidak valid
   if(tick_size <= 0 || tick_value <= 0 || lot <= 0)
   {
      sl = 0;
      tp = 0;
      return;
   }
   
   // Hitung jarak harga (dalam satuan harga simbol, misal 20.0 untuk XAUUSD)
   double sl_distance = (InpRiskAmount * tick_size) / (tick_value * lot);
   double tp_distance = (InpRewardAmount * tick_size) / (tick_value * lot);
   
   // Normalisasi jarak ke kelipatan point terdekat agar sesuai format broker
   sl_distance = MathRound(sl_distance / point) * point;
   tp_distance = MathRound(tp_distance / point) * point;
   
   double current_price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
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
   
   // Pastikan SL dan TP memenuhi batas minimum Stop Level dari broker
   long stop_level_points = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stop_level_points > 0)
   {
      double stop_level_distance = stop_level_points * point;
      if(isBuy)
      {
         if(current_price - sl < stop_level_distance) 
            sl = NormalizeDouble(current_price - stop_level_distance, _Digits);
         if(tp - current_price < stop_level_distance) 
            tp = NormalizeDouble(current_price + stop_level_distance, _Digits);
      }
      else
      {
         if(sl - current_price < stop_level_distance) 
            sl = NormalizeDouble(current_price + stop_level_distance, _Digits);
         if(current_price - tp < stop_level_distance) 
            tp = NormalizeDouble(current_price - stop_level_distance, _Digits);
      }
   }
}

//+------------------------------------------------------------------+
//| Helper Function to Update Indicator Buffers                      |
//+------------------------------------------------------------------+
bool UpdateIndicators()
{
   if(CopyBuffer(handle_rsi_h4, 0, 0, 3, rsi_h4_buf) <= 0) return false;
   if(CopyBuffer(handle_rsi_h1, 0, 0, 3, rsi_h1_buf) <= 0) return false;
   if(CopyBuffer(handle_rsi_m15, 0, 0, 3, rsi_m15_buf) <= 0) return false;
   if(CopyBuffer(handle_rsi_m5, 0, 0, 3, rsi_m5_buf) <= 0) return false;

   if(CopyBuffer(handle_ma20_m5, 0, 0, 3, ma20_m5_buf) <= 0) return false;
   if(CopyBuffer(handle_ma50_m5, 0, 0, 3, ma50_m5_buf) <= 0) return false;
   if(CopyBuffer(handle_ma20_m15, 0, 0, 3, ma20_m15_buf) <= 0) return false;
   if(CopyBuffer(handle_ma50_m15, 0, 0, 3, ma50_m15_buf) <= 0) return false;
   if(CopyBuffer(handle_ma20_h1, 0, 0, 3, ma20_h1_buf) <= 0) return false;
   if(CopyBuffer(handle_ma50_h1, 0, 0, 3, ma50_h1_buf) <= 0) return false;

   if(CopyBuffer(handle_macd_m5, 0, 0, 3, macd_main_m5) <= 0) return false;
   if(CopyBuffer(handle_macd_m15, 0, 0, 3, macd_main_m15) <= 0) return false;
   if(CopyBuffer(handle_macd_h1, 0, 0, 3, macd_main_h1) <= 0) return false;

   return true;
}