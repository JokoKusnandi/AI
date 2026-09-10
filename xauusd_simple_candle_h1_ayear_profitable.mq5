//+------------------------------------------------------------------+
//|                                              CandleStrategy.mq5  |
//|                           Real-time Current Candle Strategy M5   |
//+------------------------------------------------------------------+
#property copyright "Candle Strategy"
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

// Input Parameters
input double InpLotSize = 0.01;           // Lot Size
input double InpStopLossPrice = 15.0;      // Jarak Stop Loss dalam HARGA (Contoh: 15.0 = $15.00 move)
input double InpTakeProfitPrice = 30;    // Jarak Take Profit dalam HARGA (Contoh: 30.0 = $30.00 move)
input int    InpMagicNumber = 123456;     // Magic Number

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Setup CTrade agar lebih stabil dan otomatis menyesuaikan mode filling broker
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol); 
   
   Print("✅ EA Initialized - Symbol: ", _Symbol, " | TF: H1");
   Print("   Mode: Trading pada CANDLE SAAT INI (Real-time)");
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
   // 1. PENGUNCI UTAMA: Jika sudah ada posisi terbuka, JANGAN lakukan apa-apa.
   // Ini mencegah EA membuka order berulang-ulang pada setiap tick di candle yang sama.
   if(CountPositions() > 0)
   {
      return; 
   }
   
   // 2. Ambil data candle SAAT INI (index 0)
   // iOpen index 0 = Harga pembukaan candle yang sedang berjalan
   // iClose index 0 = Harga saat ini (current price) dari candle yang sedang berjalan
   double currentOpen = iOpen(_Symbol, PERIOD_H1, 0);
   double currentClose = iClose(_Symbol, PERIOD_H1, 0);
   
   // Validasi data (jika data belum siap, skip)
   if(currentOpen == 0 || currentClose == 0)
      return;
   
   // 3. Sinyal Trading Berdasarkan Candle SAAT INI
   // Jika harga saat ini (currentClose) lebih tinggi dari harga buka (currentOpen) = Candle Hijau/Bullish
   if(currentClose > currentOpen)
   {
      OpenBuyOrder();
      OpenBuyOrder();
      OpenBuyOrder();
      OpenBuyOrder();
      OpenBuyOrder();
   }
   // Jika harga saat ini (currentClose) lebih rendah dari harga buka (currentOpen) = Candle Merah/Bearish
   else if(currentClose < currentOpen)
   {
      OpenSellOrder();
      OpenSellOrder();
      OpenSellOrder();
      OpenSellOrder();
      OpenSellOrder();
   }
   // Jika currentClose == currentOpen (Doji sempurna), EA tidak melakukan apa-apa.
}

//+------------------------------------------------------------------+
//| Open Buy Order                                                   |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Hitung SL/TP berdasarkan jarak harga (Price Distance)
   double sl = NormalizeDouble(ask - InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(ask + InpTakeProfitPrice, _Digits);
   
   Print("📈 Sinyal BUY terdeteksi (Candle Saat Ini Bullish) | Entry: ", ask, " | SL: ", sl, " | TP: ", tp);
   
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
   
   // Hitung SL/TP berdasarkan jarak harga (Price Distance)
   double sl = NormalizeDouble(bid + InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(bid - InpTakeProfitPrice, _Digits);
   
   Print("📉 Sinyal SELL terdeteksi (Candle Saat Ini Bearish) | Entry: ", bid, " | SL: ", sl, " | TP: ", tp);
   
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