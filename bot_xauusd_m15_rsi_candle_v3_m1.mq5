//+------------------------------------------------------------------+
//|                                            XAUUSD_DynamicLot.mq5 |
//|               Logika Price Action + RSI + Dynamic Lot            |
//+------------------------------------------------------------------+
#property copyright "jk"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input int    InpMagicNumber = 555888;     // Magic Number
input int    InpRSIPeriod   = 14;         // Periode RSI
input int    InpSL_Points   = 600;       // Stop Loss dalam Poin
input int    InpTP_Points   =100;       // Take Profit dalam Poin
input bool   InpShowLogs    = true;       // Tampilkan Log

//--- Global Variables
CTrade trade;
int handle_rsi;
double rsi_buf[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   // Inisialisasi RSI pada Timeframe M1
   handle_rsi = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   if(handle_rsi == INVALID_HANDLE)
   {
      Print("Error creating RSI indicator");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(rsi_buf, true);
   
   Print("EA Initialized. Symbol: ", _Symbol, " TF: M1");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handle_rsi);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1. Cek Posisi Terbuka
   // Strategi ini dirancang untuk 1 posisi aktif pada satu waktu (opsional, bisa diubah)
   if(PositionsTotal() > 0) return;

   //--- 2. Update Data Indikator & Harga
   if(CopyBuffer(handle_rsi, 0, 0, 5, rsi_buf) <= 0) return;
   
   // Ambil data candle M1 saat ini (Index 0)
   double open_price = iOpen(_Symbol, PERIOD_M1, 0);
   double low_price = iLow(_Symbol, PERIOD_M1, 0);
   double high_price = iHigh(_Symbol, PERIOD_M1, 0);
   double current_price = iClose(_Symbol, PERIOD_M1, 0); 
   
   // Gunakan harga real-time untuk eksekusi yang lebih responsif daripada close candle
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double rsi_current = rsi_buf[0];
   double rsi_prev_3 = rsi_buf[3]; // RSI 3 candle sebelumnya
   
   //--- 3. Hitung Lot Dinamis
   double lot_size = CalculateDynamicLot();
   
   //--- 4. Logika Entry
   
   // --- LOGIKA BUY ---
   // 1. Current > Open + 300 points
   // 2. Current > Low
   // 3. RSI Current > RSI (t-3) + 3
   
   double point_val = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double threshold = 30 * point_val; 
   
   bool condition_buy_price = (ask > (open_price + threshold)) && (ask > low_price);
   bool condition_buy_rsi = (rsi_current > (rsi_prev_3 + 3));
   
   if(condition_buy_price && condition_buy_rsi)
   {
      double sl_price = ask - (InpSL_Points * point_val);
      double tp_price = ask + (InpTP_Points * point_val);
      
      if(InpShowLogs) Print("BUY SIGNAL! Price: ", ask, " RSI: ", rsi_current, " vs Prev3: ", rsi_prev_3);
      
      if(trade.Buy(lot_size, _Symbol, ask, sl_price, tp_price, "DynBuy"))
      {
         Print("Order BUY Executed. Lot: ", lot_size);
      }
      return; // Exit setelah entry
   }
   
   // --- LOGIKA SELL ---
   // 1. Current < Open - 300 points
   // 2. Current < High
   // 3. RSI Current < RSI (t-3) - 3
   
   bool condition_sell_price = (bid < (open_price - threshold)) && (bid < high_price);
   bool condition_sell_rsi = (rsi_current < (rsi_prev_3 - 3));
   
   if(condition_sell_price && condition_sell_rsi)
   {
      double sl_price = bid + (InpSL_Points * point_val);
      double tp_price = bid - (InpTP_Points * point_val);
      
      if(InpShowLogs) Print("SELL SIGNAL! Price: ", bid, " RSI: ", rsi_current, " vs Prev3: ", rsi_prev_3);
      
      if(trade.Sell(lot_size, _Symbol, bid, sl_price, tp_price, "DynSell"))
      {
         Print("Order SELL Executed. Lot: ", lot_size);
      }
      return; // Exit setelah entry
   }
}

//+------------------------------------------------------------------+
//| Helper: Calculate Dynamic Lot based on Balance                   |
//+------------------------------------------------------------------+
double CalculateDynamicLot()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double base_lot = 0.01;
   
   // Logika: 
   // < 100 -> 0.01
   // >= 100 -> 0.01 * multiplier
   
   if(balance < 100) return base_lot;
   
   // Hitung kelipatan 100
   int multiplier = (int)(balance / 100);
   
   // Pastikan minimal 0.01 jika balance >= 100
   if(multiplier < 1) multiplier = 1;
   
   double final_lot = base_lot * multiplier;
   
   // Normalisasi lot sesuai broker (biasanya 2 desimal)
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   final_lot = MathFloor(final_lot / lot_step) * lot_step;
   
   // Cek Max Lot broker
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(final_lot > max_lot) final_lot = max_lot;
   
   return final_lot;
}