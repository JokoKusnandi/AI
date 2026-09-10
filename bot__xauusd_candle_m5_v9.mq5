//+------------------------------------------------------------------+
//|                                              CandleStrategy.mq5  |
//|                 Real-time Current Candle Strategy (Time Managed) |
//|                 exit last minutes 15 |
//+------------------------------------------------------------------+
#property copyright "Candle Strategy"
#property version   "1.03"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M15;  // Timeframe Candle (Default M5)
input double          InpLotSize          = 0.01;       // Lot Size
input double          InpStopLossPrice    = 15.0;       // Jarak Stop Loss dalam HARGA (Contoh: 15.0 = $15.00)
input double          InpTakeProfitPrice  = 30.0;       // Jarak Take Profit dalam HARGA (Contoh: 30.0 = $30.00)
input int             InpMagicNumber      = 123456;     // Magic Number
input int             InpEntryDelayMins   = 3;          // [BARU] Tunggu X menit setelah candle start sebelum entry
input bool            InpForceCloseEnd    = true;       // [BARU] Paksa Close di 1 menit terakhir (Profit/Loss)

//--- Global Variables
int candle_duration_seconds = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol); 
   
   // Hitung durasi candle dalam detik (M5 = 300 detik, H1 = 3600 detik, dst)
   candle_duration_seconds = PeriodSeconds(InpTimeframe);
   
   Print("✅ EA Initialized - Symbol: ", _Symbol, " | TF: ", EnumToString(InpTimeframe));
   Print("   Entry Delay: ", InpEntryDelayMins, " menit | Force Close: 1 menit terakhir");
   Print("   Lot: ", InpLotSize, " | SL Distance: $", InpStopLossPrice, " | TP Distance: $", InpTakeProfitPrice);
   
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
   // 1. Hitung Waktu Candle Saat Ini
   datetime candle_open_time = iTime(_Symbol, InpTimeframe, 0);
   int seconds_elapsed = (int)(TimeCurrent() - candle_open_time);
   
   // Definisi Zona Waktu
   bool is_last_minute = (seconds_elapsed >= (candle_duration_seconds - 60)); // 1 menit sebelum tutup
   bool is_entry_allowed = (seconds_elapsed >= (InpEntryDelayMins * 60)) && !is_last_minute;

   // 2. [ATURAN EXIT] Paksa Close di 1 Menit Terakhir
   if(InpForceCloseEnd && is_last_minute)
   {
      ManageTimeBasedExit();
      
      // STOP semua proses. Jangan cari entry baru di menit terakhir.
      // EA akan "diam" menunggu candle berikutnya dimulai.
      return; 
   }

   // 3. [ATURAN ENTRY] Blokir Entry jika belum 2 menit dari awal candle
   if(!is_entry_allowed)
   {
      return; // Abaikan tick, tunggu hingga 2 menit pertama berlalu
   }

   // 4. Cek Posisi Terbuka (Hanya 1 posisi pada satu waktu)
   if(CountPositions() > 0)
   {
      return; 
   }
   
   // 5. Ambil data candle SAAT INI (index 0)
   double currentOpen = iOpen(_Symbol, InpTimeframe, 0);
   double currentClose = iClose(_Symbol, InpTimeframe, 0); // Ini sama dengan harga saat ini (Bid/Ask)
   
   // Validasi data (jika data belum siap, skip)
   if(currentOpen == 0 || currentClose == 0)
      return;
   
   // 6. Sinyal Trading Berdasarkan Candle SAAT INI
   // Jika harga saat ini lebih tinggi dari harga buka = Candle Bullish
   if(currentClose >= currentOpen + 3)
   {
      OpenBuyOrder(); // Hanya dipanggil 1x agar terkontrol
   }
   // Jika harga saat ini lebih rendah dari harga buka = Candle Bearish
   else if(currentClose <= currentOpen - 3)
   {
      OpenSellOrder(); // Hanya dipanggil 1x agar terkontrol
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
         
         // Tutup posisi TANPA PEDULI profit atau loss. 
         // Waktu adalah stop loss mutlak di akhir candle.
         Print("⏰ TIME EXIT: Closing position at last minute. P/L: $", DoubleToString(total_profit, 2));
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Open Buy Order                                                   |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double sl = NormalizeDouble(ask - InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(ask + InpTakeProfitPrice, _Digits);
   
   Print("📈 Sinyal BUY (Candle Bullish) | Entry: ", ask, " | SL: ", sl, " | TP: ", tp);
   
   if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, "Buy - Current Candle"))
   {
      Print("✅ BUY Order Opened Successfully! Ticket: ", trade.ResultOrder());
   }
   else
   {
      Print("❌ BUY Order Failed. Retcode: ", trade.ResultRetcode(), " | Desc: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Open Sell Order                                                  |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double sl = NormalizeDouble(bid + InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(bid - InpTakeProfitPrice, _Digits);
   
   Print("📉 Sinyal SELL (Candle Bearish) | Entry: ", bid, " | SL: ", sl, " | TP: ", tp);
   
   if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, "Sell - Current Candle"))
   {
      Print("✅ SELL Order Opened Successfully! Ticket: ", trade.ResultOrder());
   }
   else
   {
      Print("❌ SELL Order Failed. Retcode: ", trade.ResultRetcode(), " | Desc: ", trade.ResultRetcodeDescription());
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
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}
//+------------------------------------------------------------------+