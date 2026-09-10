#include <Trade\Trade.mqh>
CTrade trade;

// ====================================================================
// PARAMETER INPUT
// ====================================================================
input double LotSize = 0.01;          // Ukuran lot
input int GridDistance = 300;          // Jarak grid pertama dari harga saat ini (dalam poin)
input double TakeProfit = 3000.0;      // Target profit (dalam mata uang akun, misal USD)
input int StopLossPoints = 1500;       // Jarak Stop Loss dari harga entry (dalam poin)
input int MagicNumber = 12345;        // Nomor magic untuk EA

// Grid & Manajemen Order
input int NumGridOrders = 15;          // Jumlah pending order per arah (grid)
input int GridStep = 100;             // Jarak antar pending order grid (dalam poin)
input int MaxDistanceToKeepOrder = 1500;// Hapus pending order jika harga menjauh X poin dari setup

// Filter Opsi
input bool UseMAFilter = true;        // Aktifkan filter tren Moving Average (MA 9 & 20)
input bool UseCandlestickFilter = true; // Aktifkan filter pola candlestick
input bool UseRSIFilter = true;       // BARU: Aktifkan filter momentum RSI (Periode 5)

// ====================================================================
// VARIABEL GLOBAL
// ====================================================================
int ma9_handle = INVALID_HANDLE;
int ma20_handle = INVALID_HANDLE;
int rsi_handle = INVALID_HANDLE;      // BARU: Handle untuk indikator RSI
double m_point = 1.0;                 // Akan diisi nilai _Point broker

// ====================================================================
// FUNGSI INIT & DEINIT
// ====================================================================
void OnInit() {
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    
    m_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    Print("==================================================");
    Print("INFO BROKER: 1 Poin di ", _Symbol, " = ", m_point, " harga.");
    Print("INFO: Stop Loss diatur berjarak ", StopLossPoints, " poin dari harga entry.");
    Print("==================================================");
    
    // Inisialisasi Indikator
    ma9_handle = iMA(_Symbol, PERIOD_CURRENT, 9, 0, MODE_SMA, PRICE_CLOSE);
    ma20_handle = iMA(_Symbol, PERIOD_CURRENT, 20, 0, MODE_SMA, PRICE_CLOSE);
    rsi_handle = iRSI(_Symbol, PERIOD_CURRENT, 5, PRICE_CLOSE); // BARU: RSI Periode 5
    
    if(ma9_handle == INVALID_HANDLE || ma20_handle == INVALID_HANDLE || rsi_handle == INVALID_HANDLE) {
        Print("Gagal membuat handle indikator. EA dihentikan.");
        ExpertRemove();
        return;
    }
    
    DeleteAllPendingOrders();
    CloseAllPositions(); 
}

void OnDeinit(const int reason) {
    if(ma9_handle != INVALID_HANDLE) IndicatorRelease(ma9_handle);
    if(ma20_handle != INVALID_HANDLE) IndicatorRelease(ma20_handle);
    if(rsi_handle != INVALID_HANDLE) IndicatorRelease(rsi_handle); // BARU: Bersihkan handle RSI
}

// ====================================================================
// FUNGSI ONTICK (LOGIKA UTAMA)
// ====================================================================
void OnTick() {
    ManagePendingOrders();

    if (!HasActiveOrdersOrPositions()) {
        bool allowBuy = true;
        bool allowSell = true;

        // --- A. FILTER MOVING AVERAGE (Trend) ---
        if (UseMAFilter) {
            double ma9 = GetMAValue(ma9_handle, 1);   
            double ma20 = GetMAValue(ma20_handle, 1);
            
            if (ma9 > 0 && ma20 > 0) {
                if (ma9 <= ma20) allowBuy = false;
                if (ma9 >= ma20) allowSell = false;
            }
        }

        // --- B. FILTER CANDLESTICK (Price Action) ---
        if (UseCandlestickFilter) {
            MqlRates rates[];
            ArraySetAsSeries(rates, true);
            
            if (CopyRates(_Symbol, PERIOD_CURRENT, 0, 5, rates) < 5) return;

            bool candleBuy = false;
            bool candleSell = false;

            if (IsBullishMarubozu(rates, 1) || IsBullishEngulfing(rates, 1) || IsMorningStar(rates, 1)) {
                candleBuy = true;
            }
            
            if (IsBearishMarubozu(rates, 1) || IsBearishEngulfing(rates, 1) || IsEveningStar(rates, 1)) {
                candleSell = true;
            }

            if (allowBuy) allowBuy = candleBuy;
            if (allowSell) allowSell = candleSell;
        }

        // --- C. FILTER RSI (Momentum) - BARU ---
        if (UseRSIFilter) {
            double rsi = GetRSIValue(rsi_handle, 1); // Ambil nilai RSI candle terakhir yang sudah close (shift 1)
            
            if (rsi > 0) { // Pastikan data indikator valid
                if (rsi <= 50.0) allowBuy = false;  // Bias Buy HANYA jika RSI > 50
                if (rsi >= 50.0) allowSell = false; // Bias Sell HANYA jika RSI < 50
            }
        }

        // Hanya place grid order jika lolos SEMUA filter yang diaktifkan
        if (allowBuy || allowSell) {
            PlaceGridOrders(allowBuy, allowSell);
        }
        return;
    }

    // Jika ada posisi, cek apakah profit bersih mencapai target
    if (CheckProfit()) {
        CloseAllPositions();
        DeleteAllPendingOrders();
    }
}

// ====================================================================
// FUNGSI HELPER INDICATOR
// ====================================================================
double GetMAValue(int handle, int shift) {
    double val[];
    ArraySetAsSeries(val, true);
    if(CopyBuffer(handle, 0, shift, 1, val) > 0) return val[0];
    return 0;
}

// BARU: Fungsi untuk mengambil nilai RSI
double GetRSIValue(int handle, int shift) {
    double val[];
    ArraySetAsSeries(val, true);
    if(CopyBuffer(handle, 0, shift, 1, val) > 0) return val[0];
    return 0;
}

// ====================================================================
// FUNGSI PEMBANTU CANDLESTICK
// ====================================================================
double GetBody(const MqlRates &rates[], int shift) { return MathAbs(rates[shift].close - rates[shift].open); }
double GetRange(const MqlRates &rates[], int shift) { return rates[shift].high - rates[shift].low; }
double GetUpperShadow(const MqlRates &rates[], int shift) { return rates[shift].high - MathMax(rates[shift].open, rates[shift].close); }
double GetLowerShadow(const MqlRates &rates[], int shift) { return MathMin(rates[shift].open, rates[shift].close) - rates[shift].low; }

bool IsBullishMarubozu(const MqlRates &rates[], int shift) {
    if(rates[shift].close <= rates[shift].open) return false;
    double range = GetRange(rates, shift); if(range == 0) return false;
    return (GetBody(rates, shift) / range > 0.90) && (GetUpperShadow(rates, shift) / range < 0.05) && (GetLowerShadow(rates, shift) / range < 0.05);
}
bool IsBearishMarubozu(const MqlRates &rates[], int shift) {
    if(rates[shift].close >= rates[shift].open) return false;
    double range = GetRange(rates, shift); if(range == 0) return false;
    return (GetBody(rates, shift) / range > 0.90) && (GetUpperShadow(rates, shift) / range < 0.05) && (GetLowerShadow(rates, shift) / range < 0.05);
}
bool IsBullishEngulfing(const MqlRates &rates[], int shift) {
    if(rates[shift].close <= rates[shift].open) return false;
    if(rates[shift+1].close >= rates[shift+1].open) return false;
    return (rates[shift].close > rates[shift+1].open) && (rates[shift].open < rates[shift+1].close) && (GetBody(rates, shift) > GetBody(rates, shift+1));
}
bool IsBearishEngulfing(const MqlRates &rates[], int shift) {
    if(rates[shift].close >= rates[shift].open) return false;
    if(rates[shift+1].close <= rates[shift+1].open) return false;
    return (rates[shift].close < rates[shift+1].open) && (rates[shift].open > rates[shift+1].close) && (GetBody(rates, shift) > GetBody(rates, shift+1));
}
bool IsDoji(const MqlRates &rates[], int shift) {
    double range = GetRange(rates, shift); if(range == 0) return false;
    return (GetBody(rates, shift) / range) < 0.15;
}
bool IsMorningStar(const MqlRates &rates[], int shift) {
    if(shift + 2 >= ArraySize(rates)) return false;
    bool first_bearish = (rates[shift+2].close < rates[shift+2].open);
    if(!first_bearish || GetBody(rates, shift+2)/GetRange(rates, shift+2) < 0.5) return false;
    bool second_small = IsDoji(rates, shift+1) || (GetBody(rates, shift+1)/GetRange(rates, shift+1) < 0.3);
    if(!second_small) return false;
    bool third_bullish = (rates[shift].close > rates[shift].open);
    if(!third_bullish || GetBody(rates, shift)/GetRange(rates, shift) < 0.5) return false;
    double midpoint1 = (rates[shift+2].open + rates[shift+2].close) / 2.0;
    return (rates[shift].close > midpoint1);
}
bool IsEveningStar(const MqlRates &rates[], int shift) {
    if(shift + 2 >= ArraySize(rates)) return false;
    bool first_bullish = (rates[shift+2].close > rates[shift+2].open);
    if(!first_bullish || GetBody(rates, shift+2)/GetRange(rates, shift+2) < 0.5) return false;
    bool second_small = IsDoji(rates, shift+1) || (GetBody(rates, shift+1)/GetRange(rates, shift+1) < 0.3);
    if(!second_small) return false;
    bool third_bearish = (rates[shift].close < rates[shift].open);
    if(!third_bearish || GetBody(rates, shift)/GetRange(rates, shift) < 0.5) return false;
    double midpoint1 = (rates[shift+2].open + rates[shift+2].close) / 2.0;
    return (rates[shift].close < midpoint1);
}

// ====================================================================
// MANAJEMEN ORDER & POSISI
// ====================================================================
bool HasActiveOrdersOrPositions() {
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetTicket(i) > 0) {
            if (PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
        }
    }
    for (int i = 0; i < OrdersTotal(); i++) {
        ulong ticket = OrderGetTicket(i);
        if (ticket > 0 && OrderSelect(ticket)) {
            if (OrderGetInteger(ORDER_MAGIC) == MagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol) return true;
        }
    }
    return false;
}

void ManagePendingOrders() {
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double max_dist = MaxDistanceToKeepOrder * m_point;
    
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket > 0 && OrderSelect(ticket)) {
            if (OrderGetInteger(ORDER_MAGIC) == MagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol) {
                double order_price = OrderGetDouble(ORDER_PRICE_OPEN);
                long order_type = OrderGetInteger(ORDER_TYPE);
                
                bool should_delete = false;
                
                if (order_type == ORDER_TYPE_BUY_STOP) {
                    if (order_price - ask > max_dist) should_delete = true;
                } 
                else if (order_type == ORDER_TYPE_SELL_STOP) {
                    if (bid - order_price > max_dist) should_delete = true;
                }
                
                if (should_delete) {
                    trade.OrderDelete(ticket);
                }
            }
        }
    }
}

void PlaceGridOrders(bool allowBuy, bool allowSell) {
    if (!IsTradeAllowed()) return;

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double contract_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
    
    if (contract_size == 0) contract_size = 100.0; 

    double price_distance_for_tp = TakeProfit / (LotSize * contract_size);
    if (price_distance_for_tp <= 0) {
        Print("Error: Parameter TakeProfit (USD) atau LotSize tidak valid.");
        return;
    }

    int effectiveGridStep = MathMax(1, GridStep);
    int effectiveGridDistance = MathMax(1, GridDistance);
    int effectiveSL = MathMax(1, StopLossPoints);

    long stops_level = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    
    if (effectiveSL < stops_level) {
        Print("⚠️ PERINGATAN: Stop Loss (", effectiveSL, " poin) lebih kecil dari batas minimum broker (", stops_level, " poin).");
    }

    // Setup Buy Stop
    if (allowBuy) {
        double baseBuyPrice = ask + effectiveGridDistance * m_point;
        double lastPrice = 0;
        
        for (int i = 0; i < NumGridOrders; i++) {
            double buyStopPrice = NormalizeDouble(baseBuyPrice + (i * effectiveGridStep * m_point), _Digits);
            
            if (i > 0 && buyStopPrice == lastPrice) continue;
            lastPrice = buyStopPrice;
            
            double buySLPrice = NormalizeDouble(buyStopPrice - (effectiveSL * m_point), _Digits);
            double buyTPPrice = NormalizeDouble(buyStopPrice + price_distance_for_tp, _Digits);
            
            if (MathAbs(buyStopPrice - ask) < (stops_level * m_point)) continue; 

            if (!trade.BuyStop(LotSize, buyStopPrice, _Symbol, buySLPrice, buyTPPrice)) {
                Print("❌ GAGAL BuyStop ke-", i+1, ": ", trade.ResultRetcodeDescription());
            } else {
                Print("✅ BERHASIL: BuyStop ke-", i+1, " | Entry: ", buyStopPrice, " | SL: ", buySLPrice);
            }
        }
    }
    
    // Setup Sell Stop
    if (allowSell) {
        double baseSellPrice = bid - effectiveGridDistance * m_point;
        double lastPrice = 0;
        
        for (int i = 0; i < NumGridOrders; i++) {
            double sellStopPrice = NormalizeDouble(baseSellPrice - (i * effectiveGridStep * m_point), _Digits);
            
            if (i > 0 && sellStopPrice == lastPrice) continue;
            lastPrice = sellStopPrice;
            
            double sellSLPrice = NormalizeDouble(sellStopPrice + (effectiveSL * m_point), _Digits);
            double sellTPPrice = NormalizeDouble(sellStopPrice - price_distance_for_tp, _Digits);
            
            if (MathAbs(sellStopPrice - bid) < (stops_level * m_point)) continue;

            if (!trade.SellStop(LotSize, sellStopPrice, _Symbol, sellSLPrice, sellTPPrice)) {
                Print("❌ GAGAL SellStop ke-", i+1, ": ", trade.ResultRetcodeDescription());
            } else {
                Print("✅ BERHASIL: SellStop ke-", i+1, " | Entry: ", sellStopPrice, " | SL: ", sellSLPrice);
            }
        }
    }
}

bool CheckProfit() {
    double totalProfit = 0.0;
    for (int i = 0; i < PositionsTotal(); i++) {
        ulong ticket = PositionGetTicket(i);
        if (ticket > 0 && PositionSelectByTicket(ticket)) {
            if (PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) {
                totalProfit += PositionGetDouble(POSITION_PROFIT) + 
                               PositionGetDouble(POSITION_SWAP) + 
                               PositionGetDouble(POSITION_COMMISSION);
            }
        }
    }
    return (totalProfit >= TakeProfit);
}

void DeleteAllPendingOrders() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        ulong ticket = OrderGetTicket(i);
        if (ticket > 0 && OrderSelect(ticket)) {
            if (OrderGetInteger(ORDER_MAGIC) == MagicNumber && OrderGetString(ORDER_SYMBOL) == _Symbol) {
                trade.OrderDelete(ticket);
            }
        }
    }
}

void CloseAllPositions() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (ticket > 0 && PositionSelectByTicket(ticket)) {
            if (PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) {
                trade.PositionClose(ticket);
            }
        }
    }
}

bool IsTradeAllowed() {
    if (!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
    if (!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)) return false;
    if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
    return true;
}