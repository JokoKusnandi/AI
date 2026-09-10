//+------------------------------------------------------------------+
//|                                              CandleStrategy.mq5  |
//|           Real-time Candle + Scaling + Recovery Hedge + BE       |
//+------------------------------------------------------------------+
#property copyright "Candle Strategy"
#property version   "1.06"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

// ====================================================================
// INPUT PARAMETERS
// ====================================================================
input double InpLotSize = 0.01;           // Lot Size untuk entry awal
input double InpStopLossPrice = 15.0;     // Jarak Stop Loss awal dalam HARGA
input double InpTakeProfitPrice = 5;    // Jarak Take Profit awal dalam HARGA

// FITUR SCALING ENTRY (Trailing Position)
input bool   InpUseScaling = true;        // Aktifkan fitur tambah posisi saat profit
input double InpScalingTrigger = 1.0;     // Tambah posisi setiap profit awal kelipatan nilai ini (USD)
input double InpScalingLot = 0.01;        // Lot size untuk posisi tambahan (Scaling)

// FITUR RECOVERY HEDGE
input double InpRecoveryLossTrigger = -10.0; // Trigger hedge jika floating loss mencapai nilai ini (USD)
input double InpHedgeLotSize = 0.01;        // Lot size untuk SETIAP order hedge
input double InpBasketCloseProfit = 0.50;   // TUTUP SEMUA posisi jika total profit gabungan mencapai nilai ini

// FITUR BREAK EVEN
input double InpBreakEvenTrigger = 1.5;   // Aktifkan Break Even ketika profit mencapai nilai ini (USD)
input double InpBreakEvenBuffer = 0.08;   // Buffer keamanan spread

input int    InpMagicNumber = 123456;     // Magic Number

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // VALIDASI WAJIB: EA ini HANYA bisa berjalan di akun tipe HEDGING
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) {
      Print("❌ FATAL ERROR: EA ini HANYA bisa berjalan di akun tipe HEDGING. Akun Anda saat ini Netting.");
      Print("❌ Silakan ganti tipe akun Anda di MetaTrader atau buat akun Hedging baru.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFillingBySymbol(_Symbol); 
   
   Print("✅ EA Initialized - Symbol: ", _Symbol, " | Mode: HEDGING Account");
   Print("   Scaling: Aktif setiap $", InpScalingTrigger, " | Recovery: Trigger di $", InpRecoveryLossTrigger);
   
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
      // A. RECOVERY MODE ACTIVE (1 Initial + 2 Hedge = minimal 3 positions)
      // Jika hedge sudah aktif, STOP SCALING & STOP BREAK EVEN. Fokus hanya pada Basket Close.
      if(posCount >= 3)
      {
         if(CheckBasketProfit()) CloseAllPositions();
         return; 
      }
      
      // B. NORMAL MODE (1 Initial + possible Scaling positions)
      TriggerRecoveryHedge();
      ManageBreakEven();
      
      if(InpUseScaling) {
          ManageScalingEntry(); // BARU: Tambah posisi jika profit >= 1
      }
      
      return; 
   }

   // =================================================================
   // BAGIAN 2: CARI SINYAL ENTRY BARU (Hanya jika tidak ada posisi)
   // =================================================================
   double currentOpen = iOpen(_Symbol, PERIOD_M5, 0);
   double currentClose = iClose(_Symbol, PERIOD_M5, 0);
   
   if(currentOpen == 0 || currentClose == 0) return;
   
   if(currentClose > currentOpen) OpenBuyOrder(InpLotSize, "Buy - Initial");
   else if(currentClose < currentOpen) OpenSellOrder(InpLotSize, "Sell - Initial");
}

//+------------------------------------------------------------------+
//| BARU: FUNGSI SCALING ENTRY (TAMBAH POSISI SAAT PROFIT)           |
//+------------------------------------------------------------------+
void ManageScalingEntry()
{
   ulong initialTicket = 0;
   long initialType = -1;
   double initialProfit = 0;
   
   // 1. Cari posisi "Initial" (Posisi awal/pertama)
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, "Initial") >= 0) {
            initialTicket = ticket;
            initialType = PositionGetInteger(POSITION_TYPE);
            initialProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
            break;
         }
      }
   }
   
   if(initialTicket == 0) return; // Tidak ada posisi initial ditemukan
   
   // 2. Hitung berapa banyak posisi "Scale" yang SUDAH ADA untuk arah yang sama
   int scaleCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, "Scale") >= 0 && PositionGetInteger(POSITION_TYPE) == initialType) {
            scaleCount++;
         }
      }
   }
   
   // 3. Logika Scaling: 
   // Jika scaleCount = 0, butuh profit >= 1.0 untuk buka Scale 1
   // Jika scaleCount = 1, butuh profit >= 2.0 untuk buka Scale 2
   double requiredProfit = InpScalingTrigger * (scaleCount + 1);
   
   if(initialProfit >= requiredProfit) {
      string newComment = (initialType == POSITION_TYPE_BUY) ? "Buy - Scale " + IntegerToString(scaleCount + 1) : "Sell - Scale " + IntegerToString(scaleCount + 1);
      
      Print("🚀 SCALING TRIGGERED! Initial Profit: $", initialProfit, " | Menambah posisi Scale ke-", scaleCount + 1);
      
      if(initialType == POSITION_TYPE_BUY) {
         OpenBuyOrder(InpScalingLot, newComment);
      } else {
         OpenSellOrder(InpScalingLot, newComment);
      }
   }
}

//+------------------------------------------------------------------+
//| FUNGSI RECOVERY HEDGE (Loss -$3 -> Buka 2x Lawan)                |
//+------------------------------------------------------------------+
void TriggerRecoveryHedge()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         string comment = PositionGetString(POSITION_COMMENT);
         
         // Hanya cek posisi Initial untuk trigger hedge
         if(StringFind(comment, "Initial") >= 0) {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
            long type = PositionGetInteger(POSITION_TYPE);

            if(profit <= InpRecoveryLossTrigger) {
               if(type == POSITION_TYPE_BUY) {
                  Print("⚠️ RECOVERY TRIGGERED! Buy loss: $", profit, ". Opening 2x SELL HEDGE");
                  OpenSellOrder(InpHedgeLotSize, "Sell - HEDGE 1");
                  OpenSellOrder(InpHedgeLotSize, "Sell - HEDGE 2");
               }
               else if(type == POSITION_TYPE_SELL) {
                  Print("⚠️ RECOVERY TRIGGERED! Sell loss: $", profit, ". Opening 2x BUY HEDGE");
                  OpenBuyOrder(InpHedgeLotSize, "Buy - HEDGE 1");
                  OpenBuyOrder(InpHedgeLotSize, "Buy - HEDGE 2");
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FUNGSI CEK TOTAL PROFIT GABUNGAN (BASKET)                        |
//+------------------------------------------------------------------+
bool CheckBasketProfit()
{
   double totalProfit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
      }
   }
   
   if(totalProfit >= InpBasketCloseProfit) {
      Print("✅ BASKET PROFIT REACHED! Total Net: $", totalProfit, ". Closing ALL positions.");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| FUNGSI BREAK EVEN                                                |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         double currentProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
         
         if(currentProfit >= InpBreakEvenTrigger) {
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            double currentTP = PositionGetDouble(POSITION_TP);
            long posType = PositionGetInteger(POSITION_TYPE);
            
            double newSL = 0;
            bool modifyNeeded = false;
            
            if(posType == POSITION_TYPE_BUY) {
               newSL = NormalizeDouble(entryPrice + InpBreakEvenBuffer, _Digits);
               if(newSL > currentSL) modifyNeeded = true;
            }
            else if(posType == POSITION_TYPE_SELL) {
               newSL = NormalizeDouble(entryPrice - InpBreakEvenBuffer, _Digits);
               if(currentSL == 0 || newSL < currentSL) modifyNeeded = true;
            }
            
            if(modifyNeeded) trade.PositionModify(ticket, newSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open Buy Order (Dengan Custom Comment)                           |
//+------------------------------------------------------------------+
void OpenBuyOrder(double lotSize, string customComment)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(ask + InpTakeProfitPrice, _Digits);
   
   if(trade.Buy(lotSize, _Symbol, ask, sl, tp, customComment))
      Print("✅ BUY Opened | Lot: ", lotSize, " | Comment: ", customComment);
   else
      Print("❌ BUY Failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Open Sell Order (Dengan Custom Comment)                          |
//+------------------------------------------------------------------+
void OpenSellOrder(double lotSize, string customComment)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(bid - InpTakeProfitPrice, _Digits);
   
   if(trade.Sell(lotSize, _Symbol, bid, sl, tp, customComment))
      Print("✅ SELL Opened | Lot: ", lotSize, " | Comment: ", customComment);
   else
      Print("❌ SELL Failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Count open positions                                             |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Close ALL positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         trade.PositionClose(ticket);
      }
   }
}
//+------------------------------------------------------------------+