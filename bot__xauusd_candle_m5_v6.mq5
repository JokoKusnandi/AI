//+------------------------------------------------------------------+
//|                                              CandleStrategy.mq5  |
//|   Real-time Candle + Scaling (SL/TP Bertingkat) + Recovery       |
//+------------------------------------------------------------------+
#property copyright "Candle Strategy"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

// ====================================================================
// INPUT PARAMETERS
// ====================================================================
input double InpLotSize = 0.01;           // Lot Size untuk entry awal
input double InpStopLossPrice = 25.0;     // Jarak Stop Loss awal dalam HARGA
input double InpTakeProfitPrice = 5.0;    // Jarak Take Profit awal dalam HARGA

// FITUR SCALING ENTRY (Trailing Position dengan SL & TP Bertingkat)
input bool   InpUseScaling = true;        // Aktifkan fitur tambah posisi saat profit
input double InpScalingTrigger = 1.0;     // Tambah posisi setiap profit awal kelipatan nilai ini (USD)
input double InpScalingLot = 0.01;        // Lot size untuk posisi tambahan (Scaling)
input double InpTPReductionPerScale = 1.0;// Pengurangan jarak TP dari jarak Initial setiap kali scaling
input double InpSLReductionPerScale = 4.0;// Pengurangan jarak SL dari jarak Initial setiap kali scaling

// FITUR RECOVERY HEDGE
input double InpRecoveryLossTrigger = -5.0; // Trigger hedge jika floating loss mencapai nilai ini (USD)
input double InpHedgeLotSize = 0.01;         // Lot size untuk SETIAP order hedge
input double InpHedgeStopLossPrice = 2.0;    // BARU: Jarak Stop Loss khusus untuk posisi HEDGE (dalam HARGA)
input double InpHedgeTakeProfitPrice = 2.0;  // BARU: Jarak Take Profit khusus untuk posisi HEDGE (dalam HARGA)
input double InpBasketCloseProfit = 0.50;    // TUTUP SEMUA posisi jika total profit gabungan mencapai nilai ini

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
   Print("   Scaling: Trigger $", InpScalingTrigger, " | TP Berkurang: ", InpTPReductionPerScale, " | SL Berkurang: ", InpSLReductionPerScale);
   Print("   Recovery: Trigger di $", InpRecoveryLossTrigger, " | Hedge SL: ", InpHedgeStopLossPrice, " | Hedge TP: ", InpHedgeTakeProfitPrice);
   Print("   Basket Close di $", InpBasketCloseProfit);
   
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
      // A. RECOVERY MODE ACTIVE (Minimal 3 positions: 1 Initial + 2 Hedge)
      if(posCount >= 3)
      {
         if(CheckBasketProfit()) CloseAllPositions();
         return; 
      }
      
      // B. NORMAL MODE (1 Initial + possible Scaling positions)
      TriggerRecoveryHedge();
      ManageBreakEven();
      
      if(InpUseScaling) {
          ManageScalingEntry(); 
      }
      
      return; 
   }

   // =================================================================
   // BAGIAN 2: CARI SINYAL ENTRY BARU (Hanya jika tidak ada posisi)
   // =================================================================
   double currentOpen = iOpen(_Symbol, PERIOD_M5, 0);
   double currentClose = iClose(_Symbol, PERIOD_M5, 0);
   
   if(currentOpen == 0 || currentClose == 0) return;
   
   if(currentClose > currentOpen) OpenInitialBuy();
   else if(currentClose < currentOpen) OpenInitialSell();
}

//+------------------------------------------------------------------+
//| FUNGSI SCALING ENTRY (SL & TP BERTINGKAT)                        |
//+------------------------------------------------------------------+
void ManageScalingEntry()
{
   ulong initialTicket = 0;
   long initialType = -1;
   double initialProfit = 0.0;
   double initialEntry = 0.0;
   double initialSL = 0.0;
   double initialTP = 0.0;
   
   // 1. Cari posisi "Initial"
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, "Initial") >= 0) {
            initialTicket = ticket;
            initialType = PositionGetInteger(POSITION_TYPE);
            initialProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
            initialEntry = PositionGetDouble(POSITION_PRICE_OPEN);
            initialSL = PositionGetDouble(POSITION_SL);
            initialTP = PositionGetDouble(POSITION_TP);
            break;
         }
      }
   }
   
   if(initialTicket == 0) return; 
   
   // 2. Hitung jarak SL dan TP awal (Absolute Distance)
   double initSLDist = MathAbs(initialEntry - initialSL);
   double initTPDist = MathAbs(initialTP - initialEntry);
   
   // 3. Hitung berapa banyak posisi "Scale" yang SUDAH ADA
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
   
   // 4. Logika Scaling: Butuh profit >= Trigger * (scaleCount + 1)
   double requiredProfit = InpScalingTrigger * (double)(scaleCount + 1);
   
   if(initialProfit >= requiredProfit) {
      int nextScaleNum = scaleCount + 1;
      string newComment = (initialType == POSITION_TYPE_BUY) ? "Buy - Scale " + IntegerToString(nextScaleNum) : "Sell - Scale " + IntegerToString(nextScaleNum);
      
      // 5. HITUNG JARAK BARU (Dikurangi sesuai input)
      double newSLDist = initSLDist - (InpSLReductionPerScale * (double)nextScaleNum);
      double newTPDist = initTPDist - (InpTPReductionPerScale * (double)nextScaleNum);
      
      long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minDist = stopsLevel * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      
      if(minDist < 1.0) minDist = 1.0; 
      
      if(newSLDist < minDist) newSLDist = minDist;
      if(newTPDist < minDist) newTPDist = minDist;
      
      // 6. Hitung harga absolut SL dan TP berdasarkan harga pasar SAAT INI
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double newSL = 0.0, newTP = 0.0; 
      
      if(initialType == POSITION_TYPE_BUY) {
         newSL = NormalizeDouble(currentAsk - newSLDist, _Digits);
         newTP = NormalizeDouble(currentAsk + newTPDist, _Digits);
      } else {
         newSL = NormalizeDouble(currentBid + newSLDist, _Digits);
         newTP = NormalizeDouble(currentBid - newTPDist, _Digits);
      }
      
      Print("🚀 SCALING TRIGGERED! Profit: $", initialProfit, " | Scale ke-", nextScaleNum);
      Print("   📉 New SL Distance: ", newSLDist, " (Reduced by ", InpSLReductionPerScale * (double)nextScaleNum, ")");
      Print("   📈 New TP Distance: ", newTPDist, " (Reduced by ", InpTPReductionPerScale * (double)nextScaleNum, ")");
      
      if(initialType == POSITION_TYPE_BUY) {
         OpenCustomBuyOrder(InpScalingLot, newComment, newSL, newTP);
      } else {
         OpenCustomSellOrder(InpScalingLot, newComment, newSL, newTP);
      }
   }
}

//+------------------------------------------------------------------+
//| FUNGSI RECOVERY HEDGE (DENGAN SL/TP KHUSUS)                      |
//+------------------------------------------------------------------+
void TriggerRecoveryHedge()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         string comment = PositionGetString(POSITION_COMMENT);
         
         if(StringFind(comment, "Initial") >= 0) {
            double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION);
            long type = PositionGetInteger(POSITION_TYPE);

            if(profit <= InpRecoveryLossTrigger) {
               if(type == POSITION_TYPE_BUY) {
                  Print("⚠️ RECOVERY TRIGGERED! Buy loss: $", profit, ". Opening 2x SELL HEDGE dengan SL=", InpHedgeStopLossPrice, " TP=", InpHedgeTakeProfitPrice);
                  
                  // Hitung SL/TP khusus untuk SELL HEDGE berdasarkan harga BID saat ini
                  double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                  double hedgeSL = NormalizeDouble(currentBid + InpHedgeStopLossPrice, _Digits);
                  double hedgeTP = NormalizeDouble(currentBid - InpHedgeTakeProfitPrice, _Digits);
                  
                  OpenCustomSellOrder(InpHedgeLotSize, "Sell - HEDGE 1", hedgeSL, hedgeTP); 
                  OpenCustomSellOrder(InpHedgeLotSize, "Sell - HEDGE 2", hedgeSL, hedgeTP);
               }
               else if(type == POSITION_TYPE_SELL) {
                  Print("⚠️ RECOVERY TRIGGERED! Sell loss: $", profit, ". Opening 2x BUY HEDGE dengan SL=", InpHedgeStopLossPrice, " TP=", InpHedgeTakeProfitPrice);
                  
                  // Hitung SL/TP khusus untuk BUY HEDGE berdasarkan harga ASK saat ini
                  double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                  double hedgeSL = NormalizeDouble(currentAsk - InpHedgeStopLossPrice, _Digits);
                  double hedgeTP = NormalizeDouble(currentAsk + InpHedgeTakeProfitPrice, _Digits);
                  
                  OpenCustomBuyOrder(InpHedgeLotSize, "Buy - HEDGE 1", hedgeSL, hedgeTP);
                  OpenCustomBuyOrder(InpHedgeLotSize, "Buy - HEDGE 2", hedgeSL, hedgeTP);
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
      Print("✅ BASKET PROFIT REACHED! Total Net: $", totalProfit, ". Closing ALL positions to secure safety.");
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
            
            double newSL = 0.0;
            bool modifyNeeded = false;
            
            if(posType == POSITION_TYPE_BUY) {
               newSL = NormalizeDouble(entryPrice + InpBreakEvenBuffer, _Digits);
               if(newSL > currentSL) modifyNeeded = true;
            }
            else if(posType == POSITION_TYPE_SELL) {
               newSL = NormalizeDouble(entryPrice - InpBreakEvenBuffer, _Digits);
               if(currentSL == 0.0 || newSL < currentSL) modifyNeeded = true;
            }
            
            if(modifyNeeded) trade.PositionModify(ticket, newSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| FUNGSI ORDER (INITIAL & CUSTOM)                                  |
//+------------------------------------------------------------------+
void OpenInitialBuy() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(ask + InpTakeProfitPrice, _Digits);
   OpenCustomBuyOrder(InpLotSize, "Buy - Initial", sl, tp);
}

void OpenInitialSell() {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + InpStopLossPrice, _Digits);
   double tp = NormalizeDouble(bid - InpTakeProfitPrice, _Digits);
   OpenCustomSellOrder(InpLotSize, "Sell - Initial", sl, tp);
}

void OpenCustomBuyOrder(double lotSize, string customComment, double forcedSL, double forcedTP)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = (forcedSL > 0.0) ? forcedSL : NormalizeDouble(ask - InpStopLossPrice, _Digits);
   double tp = (forcedTP > 0.0) ? forcedTP : NormalizeDouble(ask + InpTakeProfitPrice, _Digits);
   
   if(trade.Buy(lotSize, _Symbol, ask, sl, tp, customComment))
      Print("✅ BUY Opened | Lot: ", lotSize, " | Comment: ", customComment, " | SL: ", sl, " | TP: ", tp);
   else
      Print("❌ BUY Failed: ", trade.ResultRetcodeDescription());
}

void OpenCustomSellOrder(double lotSize, string customComment, double forcedSL, double forcedTP)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (forcedSL > 0.0) ? forcedSL : NormalizeDouble(bid + InpStopLossPrice, _Digits);
   double tp = (forcedTP > 0.0) ? forcedTP : NormalizeDouble(bid - InpTakeProfitPrice, _Digits);
   
   if(trade.Sell(lotSize, _Symbol, bid, sl, tp, customComment))
      Print("✅ SELL Opened | Lot: ", lotSize, " | Comment: ", customComment, " | SL: ", sl, " | TP: ", tp);
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