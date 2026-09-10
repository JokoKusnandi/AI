//+------------------------------------------------------------------+
//|                      bot_xauusd_m15_rsi_candle_v4_tp_dynamic.mq5 |
//|               Price Action 150pts + Dynamic TP + RSI Logic       |
//+------------------------------------------------------------------+
#property copyright "Qwen Assistant"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input int    InpMagicNumber = 777999;     // Magic Number
input int    InpRSIPeriod   = 14;         // Periode RSI
input double InpDailyLossLimit = 1000.0;    // Batas Rugi Harian ($)
input int    InpSL_Points   = 1000;         // Stop Loss dalam Poin (Fixed)
input int    InpPriceThreshold = 150;     // Threshold Harga dari Open (150 poin)
input bool   InpShowLogs    = true;       // Tampilkan Log

//--- Global Variables
CTrade trade;
int handle_rsi;
double rsi_buf[];
datetime last_trade_date = 0;
double daily_loss_start_balance = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   // Inisialisasi RSI on M15
   handle_rsi = iRSI(_Symbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   if(handle_rsi == INVALID_HANDLE)
   {
      Print("Error creating RSI indicator");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(rsi_buf, true);
   
   // Set awal balance harian
   daily_loss_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   last_trade_date = TimeCurrent();
   
   Print("EA Initialized. Symbol: ", _Symbol, " TF: M15");
   Print("Price Threshold: ", InpPriceThreshold, " points");
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
   //--- 1. Cek Daily Reset & Loss Limit
   CheckDailyReset();
   
   double current_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double daily_loss = daily_loss_start_balance - current_equity;
   
   if(daily_loss >= InpDailyLossLimit)
   {
      if(InpShowLogs) Print("Daily Loss Limit Reached: $", DoubleToString(daily_loss, 2), ". Trading Halted.");
      return;
   }

   //--- 2. Cek Posisi Terbuka (Satu posisi pada satu waktu)
   if(PositionsTotal() > 0) return;

   //--- 3. Update Data Indikator & Harga
   if(CopyBuffer(handle_rsi, 0, 0, 5, rsi_buf) <= 0) return;
   
   // Data Candle M15
   // Index 0 = Candle sedang berjalan (Current)
   // Index 1 = Candle terakhir yang sudah close (Previous Closed)
   double open_price = iOpen(_Symbol, PERIOD_M15, 0);
   double low_price = iLow(_Symbol, PERIOD_M15, 0);
   double high_price = iHigh(_Symbol, PERIOD_M15, 0);
   double prev_close_price = iClose(_Symbol, PERIOD_M15, 1); // Close candle 15 menit terakhir
   
   // Harga Real-time
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double rsi_current = rsi_buf[0];
   double rsi_prev_3 = rsi_buf[3]; // RSI 3 candle sebelumnya
   
   //--- 4. Hitung Lot Dinamis
   double lot_size = CalculateDynamicLot();
   
   //--- 5. Konversi Poin ke Harga
   double point_val = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double threshold_price = InpPriceThreshold * point_val; // 150 poin
   double sl_distance = InpSL_Points * point_val;          // 300 poin
   
   //--- 6. Logika Entry
   
   // --- LOGIKA BUY ---
   // 1. Current (Ask) > Open + 150 poin
   // 2. Current (Ask) > Low
   // 3. RSI Current > RSI (t-3) + 3
   
   bool condition_buy_price = (ask >= (open_price + threshold_price)) || (ask >= (low_price + 2));
   bool condition_buy_rsi = (rsi_current > (rsi_prev_3 + 3));
   
   if(condition_buy_price && condition_buy_rsi)
   {
      // TP Dinamis: Dekat closed candle terakhir (Prev Close)
      // Jika Prev Close > Ask, kita set TP di Prev Close. 
      // Jika Prev Close < Ask, kita beri buffer sedikit agar TP masuk akal
      double tp_price = prev_close_price;
      
      // Validasi TP harus lebih tinggi dari Entry untuk Buy
      if(tp_price <= ask) 
      {
         // Jika close candle sebelumnya lebih rendah dari harga sekarang, 
         // kita gunakan rata-rata atau tambah buffer minimal 20 poin agar profit
         tp_price = ask + (200 * point_val); 
      }
      
      double sl_price = ask - sl_distance;
      
      if(InpShowLogs) Print("BUY SIGNAL! Ask: ", ask, " | Open: ", open_price, " | RSI: ", rsi_current, " vs Prev3: ", rsi_prev_3);
      
      if(trade.Buy(lot_size, _Symbol, ask, sl_price, tp_price, "DynBuy_150"))
      {
         Print("Order BUY Executed. Lot: ", lot_size, " TP: ", tp_price);
      }
      return;
   }
   
   // --- LOGIKA SELL ---
   // 1. Current (Bid) < Open - 150 poin
   // 2. Current (Bid) < High
   // 3. RSI Current < RSI (t-3) - 3
   
   bool condition_sell_price = (bid <= (open_price - threshold_price)) || (bid <= (high_price-2));
   bool condition_sell_rsi = (rsi_current < (rsi_prev_3 - 3));
   
   if(condition_sell_price && condition_sell_rsi)
   {
      // TP Dinamis: Dekat closed candle terakhir (Prev Close)
      double tp_price = prev_close_price;
      
      // Validasi TP harus lebih rendah dari Entry untuk Sell
      if(tp_price >= bid)
      {
         // Jika close candle sebelumnya lebih tinggi dari harga sekarang,
         // kita kurangi buffer minimal 20 poin agar profit
         tp_price = bid - (200 * point_val);
      }
      
      double sl_price = bid + sl_distance;
      
      if(InpShowLogs) Print("SELL SIGNAL! Bid: ", bid, " | Open: ", open_price, " | RSI: ", rsi_current, " vs Prev3: ", rsi_prev_3);
      
      if(trade.Sell(lot_size, _Symbol, bid, sl_price, tp_price, "DynSell_150"))
      {
         Print("Order SELL Executed. Lot: ", lot_size, " TP: ", tp_price);
      }
      return;
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
   // <= 100 -> 0.01
   // >= 200 -> 0.02
   // >= 300 -> 0.03
   
   if(balance < 100) return base_lot;
   
   // Hitung kelipatan 100
   int multiplier = (int)(balance / 100);
   
   // Pastikan minimal 1 jika balance >= 100
   if(multiplier < 1) multiplier = 1;
   
   double final_lot = base_lot * multiplier;
   
   // Normalisasi lot sesuai broker
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   final_lot = MathFloor(final_lot / lot_step) * lot_step;
   
   // Cek Max Lot broker
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(final_lot > max_lot) final_lot = max_lot;
   
   return final_lot;
}

//+------------------------------------------------------------------+
//| Helper: Check Daily Reset                                        |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt_now;
   TimeToStruct(TimeCurrent(), dt_now);
   
   MqlDateTime dt_last;
   TimeToStruct(last_trade_date, dt_last);
   
   // Jika hari berganti
   if(dt_now.day != dt_last.day)
   {
      daily_loss_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      last_trade_date = TimeCurrent();
      Print("New Day Started. Daily Loss Counter Reset.");
   }
}