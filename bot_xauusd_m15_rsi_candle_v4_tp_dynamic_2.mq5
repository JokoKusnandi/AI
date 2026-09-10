//+------------------------------------------------------------------+
//|                      bot_xauusd_m15_rsi_candle_v4_tp_dynamic.mq5 |
//|               Price Action 150pts + Pure Time-Based Exit         |
//+------------------------------------------------------------------+
#property copyright "Qwen Assistant"
#property version   "1.02" // Versi Pure Time-Based Exit
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input int    InpMagicNumber     = 777999;     // Magic Number
input int    InpRSIPeriod       = 14;         // Periode RSI
input double InpDailyLossLimit  = 1500.0;     // Batas Rugi Harian ($)
input int    InpSL_Points       = 1500;       // Stop Loss dalam Poin (Fixed)
input int    InpPriceThreshold  = 200;        // Threshold Harga dari Open (200 poin)
input bool   InpShowLogs        = true;       // Tampilkan Log
input bool   InpForceCloseM15   = true;       // Paksa Close di 1 menit terakhir jika profit/impas

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
   
   Print("EA Initialized. Symbol: ", _Symbol, " TF: M15 | Pure Time-Based Exit Active");
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

   //--- 2. Cek Waktu: Apakah sudah masuk 1 menit terakhir candle M15?
   datetime candle_open_time = iTime(_Symbol, PERIOD_M15, 0);
   datetime last_minute_start = candle_open_time + (14 * 60); // 14 menit = 840 detik
   bool is_last_minute = (TimeCurrent() >= last_minute_start);

   //--- 3. [PENTING] Eksekusi Time-Based Exit & Blokir Entry Baru di Menit Terakhir
   if(InpForceCloseM15 && is_last_minute)
   {
      ManageTimeBasedExit();
      
      // SKIP logika entry baru jika sudah di 1 menit terakhir. 
      // Ini memaksa EA menunggu candle berikutnya (perpindahan candle) untuk entry kembali.
      return; 
   }

   //--- 4. Cek Posisi Terbuka (Satu posisi pada satu waktu)
   if(PositionsTotal() > 0) return;

   //--- 5. Update Data Indikator & Harga
   if(CopyBuffer(handle_rsi, 0, 0, 5, rsi_buf) <= 0) return;
   
   double open_price = iOpen(_Symbol, PERIOD_M15, 0);
   double low_price = iLow(_Symbol, PERIOD_M15, 0);
   double high_price = iHigh(_Symbol, PERIOD_M15, 0);
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double rsi_current = rsi_buf[0];
   double rsi_prev_3 = rsi_buf[3]; 
   
   //--- 6. Hitung Lot Dinamis
   double lot_size = CalculateDynamicLot();
   
   //--- 7. Konversi Poin ke Harga
   double point_val = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double threshold_price = InpPriceThreshold * point_val; 
   double sl_distance = InpSL_Points * point_val;          
   
   //--- 8. Logika Entry
   
   // --- LOGIKA BUY ---
   bool condition_buy_price = (ask > (open_price + threshold_price)) && (ask > low_price);
   bool condition_buy_rsi = (rsi_current > (rsi_prev_3 + 3));
   
   if(condition_buy_price && condition_buy_rsi)
   {
      // [PERBAIKAN] TP Harga di-set 0 (NOL). 
      // Tidak ada TP statis. Penutupan 100% dikendalikan oleh ManageTimeBasedExit.
      double tp_price = 0; 
      double sl_price = ask - sl_distance;
      
      if(InpShowLogs) Print("BUY SIGNAL! Ask: ", ask, " | Open: ", open_price, " | RSI: ", rsi_current);
      
      if(trade.Buy(lot_size, _Symbol, ask, sl_price, tp_price, "DynBuy_150"))
      {
         Print("Order BUY Executed. Lot: ", lot_size, " | Pure Time-Based TP Active");
      }
      return;
   }
   
   // --- LOGIKA SELL ---
   bool condition_sell_price = (bid < (open_price - threshold_price)) && (bid < high_price);
   bool condition_sell_rsi = (rsi_current < (rsi_prev_3 - 3));
   
   if(condition_sell_price && condition_sell_rsi)
   {
      // [PERBAIKAN] TP Harga di-set 0 (NOL).
      double tp_price = 0;
      double sl_price = bid + sl_distance;
      
      if(InpShowLogs) Print("SELL SIGNAL! Bid: ", bid, " | Open: ", open_price, " | RSI: ", rsi_current);
      
      if(trade.Sell(lot_size, _Symbol, bid, sl_price, tp_price, "DynSell_150"))
      {
         Print("Order SELL Executed. Lot: ", lot_size, " | Pure Time-Based TP Active");
      }
      return;
   }
}

//+------------------------------------------------------------------+
//| Helper: Manage Time Based Exit (1 Menit Terakhir M15)            |
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
         // Hitung total profit bersih (Profit + Swap + Commission)
         double total_profit = PositionGetDouble(POSITION_PROFIT) + 
                               PositionGetDouble(POSITION_SWAP) + 
                               PositionGetDouble(POSITION_COMMISSION);
         
         // Tutup jika profit (>= 0 artinya profit atau minimal impas/break-even)
         // Ini mencegah posisi yang tadinya profit berubah jadi loss saat pergantian candle
         if(total_profit >= 5)
         {
            if(InpShowLogs) 
               Print("TIME EXIT: Closing position at last minute of M15. Profit: $", DoubleToString(total_profit, 2));
            
            trade.PositionClose(ticket);
         }
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