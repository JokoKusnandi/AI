//+------------------------------------------------------------------+
//|                                              CandleStrategy.mq5  |
//|                      Real-time Current Candle + Recovery Hedge   |
//+------------------------------------------------------------------+
#property copyright "Candle Strategy"
#property version   "1.05"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

// ====================================================================
// INPUT PARAMETERS
// ====================================================================
input double InpLotSize = 0.01;           // Lot Size untuk entry awal
input double InpStopLossPrice = 15.0;     // Jarak Stop Loss awal dalam HARGA (Contoh: 12.0 = $12.00)
input double InpTakeProfitPrice = 5;    // Jarak Take Profit awal dalam HARGA

// FITUR RECOVERY HEDGE (MARTINGALE TERKONTROL)
input double InpRecoveryLossTrigger = -10.0; // Trigger hedge jika floating loss mencapai nilai ini (USD)
input double InpHedgeLotSize = 0.01;        // Lot size untuk SETIAP order hedge (Total hedge = 2 x 0.01 = 0.02)
input double InpBasketCloseProfit = 0.50;   // TUTUP SEMUA posisi jika total profit gabungan mencapai nilai ini (USD)

// FITUR BREAK EVEN
input double InpBreakEvenTrigger = 1.0;   // Aktifkan Break Even ketika profit mencapai nilai ini (USD)
input double InpBreakEvenBuffer = 0.08;   // Buffer keamanan agar tidak tersentuh spread

input int    InpMagicNumber = 123456;     // Magic Number

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol); 
   
   Print("✅ EA Initialized - Symbol: ", _Symbol, " | TF: M5");
   Print("   Mode: Real-time Candle + Recovery Hedge @ $", InpRecoveryLossTrigger);
   Print("   Basket Close Target: $", InpBasketCloseProfit);
   
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
   int posCount = CountPositions();

   // =================================================================
   // BAGIAN 1: MANAJEMEN POSISI YANG SEDANG BERJALAN
   // =================================================================
   if(posCount > 0)
   {
      // A. Jika sudah ada 3 posisi (1 awal + 2 hedge), cek apakah total profit sudah target
      if(posCount >= 3)
      {
         if(CheckBasketProfit())
         {
            CloseAllPositions(); // Tutup semua, misi penyelamatan selesai
         }
         return; // Jangan buka posisi baru selama proses recovery berjalan
      }
      
      // B. Jika baru ada 1 posisi, cek apakah perlu trigger hedge atau break even
      if(posCount == 1)
      {
         TriggerRecoveryHedge();
         ManageBreakEven();
      }
      
      return; // Jangan eksekusi sinyal entry baru jika masih ada posisi aktif
   }

   // =================================================================
   // BAGIAN 2: CARI SINYAL ENTRY BARU (Hanya jika tidak ada posisi)
   // =================================================================
   double currentOpen = iOpen(_Symbol, PERIOD_M5, 0);
   double currentClose = iClose(_Symbol, PERIOD_M5, 0);
   
   if(currentOpen == 0 || currentClose == 0)
      return;
   
   if(currentClose > currentOpen) // Candle Hijau/Bullish
   {
      OpenBuyOrder(InpLotSize);
   }
   else if(currentClose < currentOpen) // Candle Merah/Bearish
   {
      OpenSellOrder(InpLotSize);
   }
}

//+------------------------------------------------------------------+
//| FUNGSI 1: Trigger Recovery Hedge (Loss -$3 -> Buka 2x Lawan)     |
//+------------------------------------------------------------------+
void TriggerRecoveryHedge()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
         long type = PositionGetInteger(POSITION_TYPE);

         // Jika loss mencapai atau melebihi trigger (misal -3.0)
         if(profit <= InpRecoveryLossTrigger)
         {
            if(type == POSITION_TYPE_BUY)
            {
               Print("⚠️ RECOVERY TRIGGERED! Buy loss: $", profit, ". Opening 2x SELL (", InpHedgeLotSize, " each)");
               OpenSellOrder(InpHedgeLotSize);
               OpenSellOrder(InpHedgeLotSize);
            }
            else if(type == POSITION_TYPE_SELL)
            {
               Print("⚠️ RECOVERY TRIGGERED! Sell loss: $", profit, ". Opening 2x BUY (", InpHedgeLotSize, " each)");
               OpenBuyOrder(InpHedgeLotSize);
               OpenBuyOrder(InpHedgeLotSize);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FUNGSI 2: Cek Total Profit Gabungan (Basket)                     |
//+------------------------------------------------------------------+
bool CheckBasketProfit()
{
   double totalProfit = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
      }
   }
   
   // Jika total profit gabungan sudah mencapai target (misal $0.50)
   if(totalProfit >= InpBasketCloseProfit)
   {
      Print("✅ BASKET PROFIT REACHED! Total Net Profit: $", totalProfit, ". Closing ALL positions to secure safety.");
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| FUNGSI 3: Break Even (Hanya untuk posisi tunggal awal)           |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         double currentProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
         
         if(currentProfit >= InpBreakEvenTrigger)
         {
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            double currentTP = PositionGetDouble(POSITION_TP);
            long posType = PositionGetInteger(POSITION_TYPE);
            
            double newSL = 0;
            bool modifyNeeded = false;
            
            if(posType == POSITION_TYPE_BUY)
            {
               newSL = NormalizeDouble(entryPrice + InpBreakEvenBuffer, _Digits);
               if(newSL > currentSL) modifyNeeded = true;
            }
            else if(posType == POSITION_TYPE_SELL)
            {
               newSL = NormalizeDouble(entryPrice - InpBreakEvenBuffer, _Digits);
               if(currentSL == 0 || newSL < currentSL) modifyNeeded = true;
            }
            
            if(modifyNeeded)
            {
               if(trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("🛡️ BREAK EVEN DIAKTIFKAN! Ticket: ", ticket, " | SL baru: ", newSL);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open Buy Order (Dapat menerima parameter lot dinamis)            |
//+------------------------------------------------------------------+
void OpenBuyOrder(double lotSize)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(ask + InpTakeProfitPrice, _Digits);
   
   string comment = (lotSize == InpLotSize) ? "Buy - Initial" : "Buy - RECOVERY HEDGE";
   
   if(trade.Buy(lotSize, _Symbol, ask, sl, tp, comment))
   {
      Print("✅ BUY Opened | Lot: ", lotSize, " | Entry: ", ask, " | SL: ", sl, " | TP: ", tp);
   }
   else
   {
      Print("❌ BUY Failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Open Sell Order (Dapat menerima parameter lot dinamis)           |
//+------------------------------------------------------------------+
void OpenSellOrder(double lotSize)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(bid - InpTakeProfitPrice, _Digits);
   
   string comment = (lotSize == InpLotSize) ? "Sell - Initial" : "Sell - RECOVERY HEDGE";
   
   if(trade.Sell(lotSize, _Symbol, bid, sl, tp, comment))
   {
      Print("✅ SELL Opened | Lot: ", lotSize, " | Entry: ", bid, " | SL: ", sl, " | TP: ", tp);
   }
   else
   {
      Print("❌ SELL Failed: ", trade.ResultRetcodeDescription());
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
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Close ALL positions (Untuk Basket Exit)                          |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         trade.PositionClose(ticket);
      }
   }
}
//+------------------------------------------------------------------+