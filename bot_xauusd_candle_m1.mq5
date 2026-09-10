#include <Trade\Trade.mqh>
CTrade trade;

// ====================================================================
// PARAMETER INPUT
// ====================================================================
input double LotSize = 0.01;        // Ukuran lot
input int GridDistance = 50;       // Jarak grid PERTAMA dari harga tick terakhir (dalam poin)
input int GridStep = 100;           // Jarak antar grid berikutnya (dalam poin)
input int NumGridOrders = 15;        // Jumlah order dalam satu grid (Setup 5 grid)
input int StopLoss = 600;           // Stop loss per order (dalam poin)
input int TakeProfit = 500;         // Target profit per order (dalam poin)
input int MagicNumber = 12345;      // Nomor magic untuk EA

// BARU: Manajemen Jarak Order
input int MaxDistanceToKeepOrder = 300; // Hapus pending order jika harga menjauh X poin dari setup

// ====================================================================
// FUNGSI INIT
// ====================================================================
void OnInit() {
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_IOC); 
    
    // Hapus semua pending order lama saat EA diinisialisasi agar bersih
    DeleteAllPendingOrders();
}

// ====================================================================
// FUNGSI ONTICK (LOGIKA UTAMA)
// ====================================================================
void OnTick() {
    // 0. BARU: Selalu cek dan hapus pending order yang sudah terlalu jauh dari harga pasar
    ManagePendingOrders();

    // 1. CEK PENCEGAHAN DUPLIKAT: 
    // Jika sudah ada posisi terbuka ATAU pending order (yang masih valid/dekat), JANGAN buat grid baru.
    if (HasActiveOrdersOrPositions()) {
        return; 
    }

    // 2. Dapatkan data candle terakhir
    MqlRates rates[];
    ArraySetAsSeries(rates, true); // PENTING: Agar index 0 adalah candle terbaru
    
    int copied = CopyRates(_Symbol, PERIOD_M5, 0, 3, rates);
    if (copied < 3) return;

    // Logika candle bullish dan bearish
    bool currentBullish = (rates[0].close > rates[0].open);
    bool prevBullish    = (rates[1].close > rates[1].open);
    bool prevBearish    = (rates[1].close < rates[1].open);

    // 3. Tentukan Arah Tren & Pasang Grid
    bool isBullishTrend = currentBullish && (prevBullish || prevBearish);
    bool isBearishTrend = !currentBullish && (prevBearish || prevBullish);

    // Eksekusi Placement Grid (Hanya terjadi sekali karena ada pengecekan di langkah 1)
    if (isBullishTrend) {
        PlaceBuyGrid();
    } 
    else if (isBearishTrend) {
        PlaceSellGrid();
    }
}

// ====================================================================
// BARU: FUNGSI MANAJEMEN PENDING ORDER (HAPUS JIKA TERLALU JAUH)
// ====================================================================
void ManagePendingOrders() {
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double max_dist = MaxDistanceToKeepOrder * point;
    
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket > 0 && OrderSelect(ticket)) {
            if (OrderGetInteger(ORDER_MAGIC) == MagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol) {
                double order_price = OrderGetDouble(ORDER_PRICE_OPEN);
                long order_type = OrderGetInteger(ORDER_TYPE);
                
                bool should_delete = false;
                
                // Untuk Buy Stop: Hapus jika harga saat ini (Ask) sudah turun menjauh dari setup
                if (order_type == ORDER_TYPE_BUY_STOP) {
                    if (order_price - ask > max_dist) should_delete = true;
                } 
                // Untuk Sell Stop: Hapus jika harga saat ini (Bid) sudah naik menjauh dari setup
                else if (order_type == ORDER_TYPE_SELL_STOP) {
                    if (bid - order_price > max_dist) should_delete = true;
                }
                
                if (should_delete) {
                    trade.OrderDelete(ticket);
                    Print("🗑️ Pending order dihapus karena harga menjauh. Ticket: ", ticket, " | Jarak: > ", MaxDistanceToKeepOrder, " poin");
                }
            }
        }
    }
}

// ====================================================================
// FUNGSI PEMBUATAN GRID
// ====================================================================
void PlaceBuyGrid() {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    for (int i = 0; i < NumGridOrders; i++) {
        double buyPrice = NormalizeDouble(ask + (GridDistance + (i * GridStep)) * point, _Digits);
        double sl = NormalizeDouble(buyPrice - StopLoss * point*12, _Digits);
        double tp = NormalizeDouble(buyPrice + TakeProfit * point, _Digits);
        
        if (!trade.BuyStop(LotSize, buyPrice, _Symbol, sl, tp)) {
            Print("❌ Gagal pasang BuyStop ke-", i+1, ": ", trade.ResultRetcodeDescription());
        } else {
            Print("✅ BERHASIL: BuyStop ke-", i+1, " di harga: ", buyPrice);
        }
        
    }
    
}

void PlaceSellGrid() {
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    for (int i = 0; i < NumGridOrders; i++) {
        double sellPrice = NormalizeDouble(bid - (GridDistance + (i * GridStep)) * point, _Digits);
        double sl = NormalizeDouble(sellPrice + StopLoss * point*12, _Digits);
        double tp = NormalizeDouble(sellPrice - TakeProfit * point, _Digits);
        
        if (!trade.SellStop(LotSize, sellPrice, _Symbol, sl, tp)) {
            Print("❌ Gagal pasang SellStop ke-", i+1, ": ", trade.ResultRetcodeDescription());
        } else {
            Print("✅ BERHASIL: SellStop ke-", i+1, " di harga: ", sellPrice);
        }
    }
}

// ====================================================================
// FUNGSI PEMBANTU (HELPERS)
// ====================================================================

bool HasActiveOrdersOrPositions() {
    // Cek posisi terbuka
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (PositionSelectByTicket(ticket)) {
            if (PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
                PositionGetString(POSITION_SYMBOL) == _Symbol) {
                return true; 
            }
        }
    }
    
    // Cek pending order
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i); 
        if (ticket > 0 && OrderSelect(ticket)) {
            if (OrderGetInteger(ORDER_MAGIC) == MagicNumber && 
                OrderGetString(ORDER_SYMBOL) == _Symbol) {
                return true; 
            }
        }
    }
    
    return false; 
}

void CloseAllPositions(ENUM_POSITION_TYPE type) {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (PositionSelectByTicket(ticket)) {
            if (PositionGetInteger(POSITION_MAGIC) == MagicNumber && 
                PositionGetString(POSITION_SYMBOL) == _Symbol && 
                PositionGetInteger(POSITION_TYPE) == type) {
                trade.PositionClose(ticket);
            }
        }
    }
}

void DeleteAllPendingOrders() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i); 
        if (ticket > 0 && OrderSelect(ticket)) {
            if (OrderGetInteger(ORDER_MAGIC) == MagicNumber && 
                OrderGetString(ORDER_SYMBOL) == _Symbol) {
                trade.OrderDelete(ticket);
            }
        }
    }
}