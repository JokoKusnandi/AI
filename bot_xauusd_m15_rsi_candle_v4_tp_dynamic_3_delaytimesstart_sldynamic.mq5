//+------------------------------------------------------------------+
//|                      bot_xauusd_m15_rsi_candle_v4_tp_dynamic.mq5 |
//|        Price Action + Time Delay Entry + Dynamic Time-Based SL   |
//+------------------------------------------------------------------+
#property copyright "jk"
#property version   "1.03" // Versi Time Delay & Dynamic Time SL
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input int    InpMagicNumber        = 777999;     // Magic Number
input int    InpRSIPeriod          = 14;         // Periode RSI
input double InpDailyLossLimit     = 1500.0;     // Batas Rugi Harian ($)
input int    InpSL_Points          = 1500;       // Stop Loss Hard (Poin) - Pengaman darurat
input int    InpPriceThreshold     = 200;        // Threshold Harga dari Open (Poin)
input int    InpEntryDelayMinutes  = 3;          // [BARU] Tunggu X menit setelah candle start sebelum entry
input bool   InpShowLogs           = true;       // Tampilkan Log
input bool   InpForceCloseM15      = true;       // Paksa Close di 1 menit terakhir (Profit ATAU Loss)

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
   trade.SetDeviationInPoints(10); 
   
   handle_rsi = iRSI(_Symbol, PERIOD_M15, InpRSIPeriod, PRICE_CLOSE);
   if(handle_rsi == INVALID_HANDLE)
   {
      Print("Error creating RSI indicator");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(rsi_buf, true);
   daily_loss_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   last_trade_date = TimeCurrent();
   
   Print("EA Initialized. Symbol: ", _Symbol, " TF: M15");
   Print("Entry Delay: ", InpEntryDelayMinutes, " mins | Time-Based Exit: Active");
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

   //--- 2. Kalkulasi Waktu Candle M15
   datetime candle_open_time = iTime(_Symbol, PERIOD_M15, 0);
   int time_elapsed_seconds = (int)(TimeCurrent() - candle_open_time);
   
   bool is_last_minute = (time_elapsed_seconds >= (14 * 60)); // >= 14 menit (840 detik)
   bool is_entry_window = (time_elapsed_seconds >= (InpEntryDelayMinutes * 60)) && !is_last_minute;

   //--- 3. [ATURAN 2] Eksekusi Dynamic SL (Wajib Close di 1 Menit Terakhir)
   if(InpForceCloseM15 && is_last_minute)
   {
      ManageTimeBasedExit();
      
      // STOP semua proses. Jangan cari entry baru di menit terakhir.
      // EA akan "diam" menunggu candle M15 berikutnya dimulai.
      return; 
   }

   //--- 4. [ATURAN 1] Blokir Entry jika belum 2 menit dari awal candle
   if(!is_entry_window)
   {
      return; // Abaikan tick, tunggu hingga 2 menit pertama berlalu
   }

   //--- 5. Cek Posisi Terbuka (Satu posisi pada satu waktu)
   if(PositionsTotal() > 0) return;

   //--- 6. Update Data Indikator & Harga
   if(CopyBuffer(handle_rsi, 0, 0, 5, rsi_buf) <= 0) return;
   
   double open_price = iOpen(_Symbol, PERIOD_M15, 0);
   double low_price = iLow(_Symbol, PERIOD_M15, 0);
   double high_price = iHigh(_Symbol, PERIOD_M15, 0);
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double rsi_current = rsi_buf[0];
   double rsi_prev_3 = rsi_buf[3]; 
   
   //--- 7. Hitung Lot Dinamis
   double lot_size = CalculateDynamicLot();
   
   //--- 8. Konversi Poin ke Harga
   double point_val = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double threshold_price = InpPriceThreshold * point_val; 
   double sl_distance = InpSL_Points * point_val;          
   
   //--- 9. Logika Entry (Hanya berjalan di menit ke-2 s/d ke-14)
   
   // --- LOGIKA BUY ---
   bool condition_buy_price = (ask > (open_price + threshold_price)) && (ask > low_price);
   bool condition_buy_rsi = (rsi_current > (rsi_prev_3 + 3));
   
   if(condition_buy_price && condition_buy_rsi)
   {
      double tp_price = 0; // TP dikendalikan waktu, bukan harga
      double sl_price = ask - sl_distance; // Hard SL tetap ada sebagai pengaman darurat
      
      if(InpShowLogs) Print("BUY SIGNAL! Time elapsed: ", time_elapsed_seconds/60, "m | Ask: ", ask);
      
      if(trade.Buy(lot_size, _Symbol, ask, sl_price, tp_price, "DynBuy_Time"))
      {
         Print("Order BUY Executed. Lot: ", lot_size);
      }
      return;
   }
   
   // --- LOGIKA SELL ---
   bool condition_sell_price = (bid < (open_price - threshold_price)) && (bid < high_price);
   bool condition_sell_rsi = (rsi_current < (rsi_prev_3 - 3));
   
   if(condition_sell_price && condition_sell_rsi)
   {
      double tp_price = 0; // TP dikendalikan waktu, bukan harga
      double sl_price = bid + sl_distance; // Hard SL tetap ada sebagai pengaman darurat
      
      if(InpShowLogs) Print("SELL SIGNAL! Time elapsed: ", time_elapsed_seconds/60, "m | Bid: ", bid);
      
      if(trade.Sell(lot_size, _Symbol, bid, sl_price, tp_price, "DynSell_Time"))
      {
         Print("Order SELL Executed. Lot: ", lot_size);
      }
      return;
   }
}

//+------------------------------------------------------------------+
//| Helper: Manage Time Based Exit (Dynamic SL di Menit Terakhir)    |
//+------------------------------------------------------------------+
void ManageTimeBasedExit()
{
   if(PositionsTotal() == 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         double total_profit = PositionGetDouble(POSITION_PROFIT) + 
                               PositionGetDouble(POSITION_SWAP) + 
                               PositionGetDouble(POSITION_COMMISSION);
         
         // [PERUBAHAN PENTING] 
         // Tidak ada lagi cek "if(total_profit >= 0)". 
         // Di menit terakhir, posisi WAJIB ditutup (Profit ATAU Loss) 
         // untuk mencegah carry over posisi rugi ke candle baru.
         
         if(InpShowLogs) 
            Print("TIME EXIT (Dynamic SL): Closing at last minute. Profit/Loss: $", DoubleToString(total_profit, 2));
         
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Calculate Dynamic Lot based on Balance                   |
//+------------------------------------------------------------------+
double CalculateDynamicLot()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double base_lot = 0.01;
   
   if(balance < 100) return base_lot;
   
   int multiplier = (int)(balance / 100);
   if(multiplier < 1) multiplier = 1;
   
   double final_lot = base_lot * multiplier;
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   final_lot = MathFloor(final_lot / lot_step) * lot_step;
   
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
   
   if(dt_now.day != dt_last.day)
   {
      daily_loss_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      last_trade_date = TimeCurrent();
      Print("New Day Started. Daily Loss Counter Reset.");
   }
}