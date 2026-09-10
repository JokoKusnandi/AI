//+------------------------------------------------------------------+
//|                      bot_xauusd_m15_rsi_candle_v4_tp_dynamic.mq5 |
//|               Price Action 150pts + Dynamic TP + RSI Logic       |
//+------------------------------------------------------------------+
#property copyright "Qwen Assistant"
#property version   "1.01" // Versi diperbarui
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input int    InpMagicNumber     = 777999;     // Magic Number
input int    InpRSIPeriod       = 14;         // Periode RSI
input double InpDailyLossLimit  = 1500.0;     // Batas Rugi Harian ($)
input int    InpSL_Points       = 1000;       // Stop Loss dalam Poin (Fixed)
input int    InpPriceThreshold  = 150;        // Threshold Harga dari Open (150 poin)
input bool   InpShowLogs        = true;       // Tampilkan Log
input bool   InpForceCloseM15   = true;       // [BARU] Paksa Close di 1 menit terakhir jika profit

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
   trade.SetDeviationInPoints(10); // Tambahkan deviasi agar eksekusi lebih aman
   
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

   //--- 2. [BARU] Cek Manajemen Waktu (Closed Profit di 1 Menit Terakhir M15)
   if(InpForceCloseM15)
   {
      ManageTimeBasedExit();
   }

   //--- 3. Cek Posisi Terbuka (Satu posisi pada satu waktu)
   // Jika sudah ada posisi, jangan cari entry baru
   if(PositionsTotal() > 0) return;

   //--- 4. Update Data Indikator & Harga
   if(CopyBuffer(handle_rsi, 0, 0, 5, rsi_buf) <= 0) return;
   
   // Data Candle M15
   double open_price = iOpen(_Symbol, PERIOD_M15, 0);
   double low_price = iLow(_Symbol, PERIOD_M15, 0);
   double high_price = iHigh(_Symbol, PERIOD_M15, 0);
   double prev_close_price = iClose(_Symbol, PERIOD_M15, 1); // Close candle 15 menit terakhir
   
   // Harga Real-time
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double rsi_current = rsi_buf[0];
   double rsi_prev_3 = rsi_buf[3]; // RSI 3 candle sebelumnya
   
   //--- 5. Hitung Lot Dinamis
   double lot_size = CalculateDynamicLot();
   
   //--- 6. Konversi Poin ke Harga
   double point_val = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double threshold_price = InpPriceThreshold * point_val; 
   double sl_distance = InpSL_Points * point_val;          
   
   //--- 7. Logika Entry
   
   // --- LOGIKA BUY ---
   bool condition_buy_price = (ask > (open_price + threshold_price)) && (ask > low_price);
   bool condition_buy_rsi = (rsi_current > (rsi_prev_3 + 3));
   
   if(condition_buy_price && condition_buy_rsi)
   {
      double tp_price = prev_close_price;
      if(tp_price <= ask) 
         tp_price = ask + (20 * point_val); 
      
      double sl_price = ask - sl_distance;
      
      if(InpShowLogs) Print("BUY SIGNAL! Ask: ", ask, " | Open: ", open_price, " | RSI: ", rsi_current, " vs Prev3: ", rsi_prev_3);
      
      if(trade.Buy(lot_size, _Symbol, ask, sl_price, tp_price, "DynBuy_150"))
      {
         Print("Order BUY Executed. Lot: ", lot_size, " TP: ", tp_price);
      }
      return;
   }
   
   // --- LOGIKA SELL ---
   bool condition_sell_price = (bid < (open_price - threshold_price)) && (bid < high_price);
   bool condition_sell_rsi = (rsi_current < (rsi_prev_3 - 3));
   
   if(condition_sell_price && condition_sell_rsi)
   {
      double tp_price = prev_close_price;
      if(tp_price >= bid)
         tp_price = bid - (20 * point_val);
      
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
//| [BARU] Helper: Manage Time Based Exit (1 Menit Terakhir M15)     |
//+------------------------------------------------------------------+
void ManageTimeBasedExit()
{
   if(PositionsTotal() == 0) return;
   
   // Hitung waktu mulai menit terakhir dari candle M15 saat ini
   // 1 Candle M15 = 900 detik (15 menit). Menit terakhir dimulai pada detik ke 840 (14 menit)
   datetime candle_open_time = iTime(_Symbol, PERIOD_M15, 0);
   datetime last_minute_start = candle_open_time + (14 * 60); 
   
   // Jika waktu server sudah masuk 1 menit terakhir candle M15
   if(TimeCurrent() >= last_minute_start)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         
         // Pastikan hanya mengelola posisi dari EA ini
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            // Hitung total profit bersih (Profit + Swap + Commission)
            double total_profit = PositionGetDouble(POSITION_PROFIT) + 
                                  PositionGetDouble(POSITION_SWAP) + 
                                  PositionGetDouble(POSITION_COMMISSION);
            
            // Jika profit > 0 (Ubah menjadi >= 0 jika ingin close saat break-even)
            if(total_profit > 0)
            {
               if(InpShowLogs) 
                  Print("TIME EXIT: Closing in profit at last minute of M15. Profit: $", DoubleToString(total_profit, 2));
               
               trade.PositionClose(ticket);
            }
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