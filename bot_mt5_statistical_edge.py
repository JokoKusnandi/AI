import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from datetime import datetime

# ==============================================================================
# KONFIGURASI MODAL MIKRO $30 & PARAMETER STATISTIK
# ==============================================================================
SYMBOL = "BTCUSD.vx"
LOT_SIZE = 0.01           # Fixed lot untuk akun $30
MAX_RISK_USD = 3.0        # Max risk per trade ($3 = 10% modal)
MAX_DAILY_LOSS_USD = 5.0  # Circuit breaker harian
ZSCORE_ENTRY_THRESHOLD = 2.0  # Deviasi statistik untuk entry trigger
VOLUME_ZSCORE_MIN = 1.0       # Validasi volume fakeout
ATR_TRAILING_MULT = 1.5       # Multiplier trailing stop berbasis volatilitas
MAGIC_NUMBER = 20260806

def get_rates(symbol, timeframe, count=500):
    """Ambil data OHLCV dari MT5"""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    return pd.DataFrame(rates) if rates is not None else pd.DataFrame()

def calculate_statistical_features(df):
    """
    Hitung fitur statistik murni (bukan indikator teknikal biasa):
    - Z-Score Bollinger Band (deviasi relatif terhadap mean)
    - Linear Regression Slope H4 (filter tren statistik)
    - Volume Z-Score (validasi kuantitatif)
    - ATR (volatilitas adaptif)
    """
    period = 20
    
    # 1. Z-Score Bollinger Band (Statistical Deviation)
    mean = df['close'].rolling(window=period).mean()
    std = df['close'].rolling(window=period).std()
    df['bb_zscore'] = (df['close'] - mean) / (std + 1e-10)
    
    # 2. Linear Regression Slope H4 (Trend Filter Statistik)
    x = np.arange(period)
    slope = df['close'].rolling(window=period).apply(
        lambda y: np.polyfit(x, y, 1)[0], raw=True
    )
    df['lr_slope'] = slope
    
    # 3. Volume Z-Score (Fakeout Filter Kuantitatif)
    vol_mean = df['tick_volume'].rolling(window=period).mean()
    vol_std = df['tick_volume'].rolling(window=period).std()
    df['vol_zscore'] = (df['tick_volume'] - vol_mean) / (vol_std + 1e-10)
    
    # 4. ATR (Average True Range) untuk Exit Adaptif
    high_low = df['high'] - df['low']
    high_close = (df['high'] - df['close'].shift()).abs()
    low_close = (df['low'] - df['close'].shift()).abs()
    true_range = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    df['atr'] = true_range.rolling(window=period).mean()
    
    return df.dropna()

def check_daily_loss_limit():
    """Cek apakah daily loss limit sudah tercapai"""
    today_start = datetime.today().replace(hour=0, minute=0, second=0)
    history = mt5.history_deals_get(today_start, datetime.now())
    if history is None:
        return False
    daily_loss = sum(d.profit for d in history if d.profit < 0)
    return abs(daily_loss) >= MAX_DAILY_LOSS_USD

def has_open_position():
    """Cek apakah sudah ada posisi terbuka (max 1 posisi untuk $30)"""
    positions = mt5.positions_get(symbol=SYMBOL)
    return positions is not None and len(positions) > 0

def execute_trade(direction, entry_price, sl, tp):
    """Eksekusi order dengan validasi margin & spread ketat"""
    tick = mt5.symbol_info_tick(SYMBOL)
    point = mt5.symbol_info(SYMBOL).point
    spread_points = (tick.ask - tick.bid) / point
    
    # Validasi Spread (biaya transaksi terlalu besar untuk modal $30)
    if spread_points > 20:
        print(f"[SKIP] Spread terlalu lebar: {spread_points:.1f} points")
        return False
    
    # Validasi Margin (buffer $15 wajib untuk akun mikro)
    order_type = mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL
    margin_req = mt5.order_calc_margin(order_type, SYMBOL, LOT_SIZE, entry_price)
    account = mt5.account_info()
    if account.margin_free < margin_req + 15:
        print(f"[SKIP] Free margin tidak cukup: ${account.margin_free:.2f}")
        return False

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": SYMBOL,
        "volume": LOT_SIZE,
        "type": order_type,
        "price": entry_price,
        "sl": round(sl, 2),
        "tp": round(tp, 2),
        "deviation": 20,
        "magic": MAGIC_NUMBER,
        "comment": f"StatEdge_{direction}",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"[ERROR] Order gagal: {result.comment}")
        return False
    print(f"[SUCCESS] {direction} @ {entry_price:.2f} | SL:{sl:.2f} TP:{tp:.2f}")
    return True

def manage_trailing_stop():
    """Trailing stop berbasis ATR untuk exit adaptif terhadap volatilitas"""
    positions = mt5.positions_get(symbol=SYMBOL)
    if positions is None or len(positions) == 0:
        return
    
    pos = positions[0]
    df_m15 = calculate_statistical_features(get_rates(SYMBOL, mt5.TIMEFRAME_M15))
    current_atr = df_m15.iloc[-1]['atr']
    trail_distance = current_atr * ATR_TRAILING_MULT
    
    tick = mt5.symbol_info_tick(SYMBOL)
    
    if pos.type == mt5.POSITION_TYPE_BUY:
        new_sl = tick.bid - trail_distance
        if new_sl > pos.sl and new_sl < tick.bid:
            request = {
                "action": mt5.TRADE_ACTION_SLTP,
                "symbol": SYMBOL,
                "sl": round(new_sl, 2),
                "position": pos.ticket,
            }
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"[TRAIL] Buy SL digeser ke {new_sl:.2f}")
                
    elif pos.type == mt5.POSITION_TYPE_SELL:
        new_sl = tick.ask + trail_distance
        if (new_sl < pos.sl or pos.sl == 0) and new_sl > tick.ask:
            request = {
                "action": mt5.TRADE_ACTION_SLTP,
                "symbol": SYMBOL,
                "sl": round(new_sl, 2),
                "position": pos.ticket,
            }
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"[TRAIL] Sell SL digeser ke {new_sl:.2f}")

def main_logic():
    """Business logic utama bot statistical edge"""
    if not mt5.initialize():
        print("Gagal connect ke MT5"); return

    # SAFETY CHECKS PRIORITAS TERTINGGI
    if check_daily_loss_limit():
        print(f"[HALT] Daily loss limit ${MAX_DAILY_LOSS_USD} tercapai"); mt5.shutdown(); return
    
    if has_open_position():
        manage_trailing_stop()
        mt5.shutdown(); return

    # AMBIL DATA MULTI-TIMEFRAME
    df_h4 = calculate_statistical_features(get_rates(SYMBOL, mt5.TIMEFRAME_H4))
    df_m15 = calculate_statistical_features(get_rates(SYMBOL, mt5.TIMEFRAME_M15))
    
    if df_h4.empty or df_m15.empty:
        print("Data tidak cukup"); mt5.shutdown(); return

    last_h4 = df_h4.iloc[-1]
    last_m15 = df_m15.iloc[-1]
    
    # FILTER TREN STATISTIK (Linear Regression Slope H4)
    trend_bullish = last_h4['lr_slope'] > 0
    trend_bearish = last_h4['lr_slope'] < 0
    
    signal = None
    entry_price = 0
    
    # LOGIKA ENTRY BERBASIS Z-SCORE (Deviasi Statistik, Bukan Level Absolut)
    # BUY: Tren H4 bullish + Harga M15 oversold secara statistik + Volume valid
    if trend_bullish and last_m15['bb_zscore'] <= -ZSCORE_ENTRY_THRESHOLD:
        if last_m15['vol_zscore'] >= VOLUME_ZSCORE_MIN:
            signal = "BUY"
            entry_price = mt5.symbol_info_tick(SYMBOL).ask
    
    # SELL: Tren H4 bearish + Harga M15 overbought secara statistik + Volume valid
    elif trend_bearish and last_m15['bb_zscore'] >= ZSCORE_ENTRY_THRESHOLD:
        if last_m15['vol_zscore'] >= VOLUME_ZSCORE_MIN:
            signal = "SELL"
            entry_price = mt5.symbol_info_tick(SYMBOL).bid
    
    # EKSEKUSI DENGAN RISK MATEMATIS FIXED FRACTIONAL
    if signal:
        atr_val = last_m15['atr']
        sl_distance = min(MAX_RISK_USD, atr_val * 2.0)  # Max $3 risk
        
        if signal == "BUY":
            sl = entry_price - sl_distance
            tp = entry_price + (sl_distance * 2.0)  # Expectancy: Avg Win >= 2x Avg Loss
        else:
            sl = entry_price + sl_distance
            tp = entry_price - (sl_distance * 2.0)
            
        execute_trade(signal, entry_price, sl, tp)
    else:
        print(f"No signal | H4 Slope:{last_h4['lr_slope']:.4f} | M15 Z-Score:{last_m15['bb_zscore']:.2f}")
        
    mt5.shutdown()

if __name__ == "__main__":
    main_logic()
