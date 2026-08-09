import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time  # <-- TAMBAHAN: Wajib untuk time.sleep()
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

# Interval pengecekan dalam detik (Ganti 15 menjadi 60 jika ingin per 1 menit)
CHECK_INTERVAL_SECONDS = 15 

def get_rates(symbol, timeframe, count=500):
    """Ambil data OHLCV dari MT5"""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    return pd.DataFrame(rates) if rates is not None else pd.DataFrame()

def calculate_statistical_features(df):
    """Hitung fitur statistik murni"""
    period = 20
    
    # 1. Z-Score Bollinger Band
    mean = df['close'].rolling(window=period).mean()
    std = df['close'].rolling(window=period).std()
    df['bb_zscore'] = (df['close'] - mean) / (std + 1e-10)
    
    # 2. Linear Regression Slope H4
    x = np.arange(period)
    slope = df['close'].rolling(window=period).apply(
        lambda y: np.polyfit(x, y, 1)[0], raw=True
    )
    df['lr_slope'] = slope
    
    # 3. Volume Z-Score
    vol_mean = df['tick_volume'].rolling(window=period).mean()
    vol_std = df['tick_volume'].rolling(window=period).std()
    df['vol_zscore'] = (df['tick_volume'] - vol_mean) / (vol_std + 1e-10)
    
    # 4. ATR
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
    """Cek apakah sudah ada posisi terbuka"""
    positions = mt5.positions_get(symbol=SYMBOL)
    return positions is not None and len(positions) > 0

def execute_trade(direction, entry_price, sl, tp):
    """Eksekusi order dengan validasi margin & spread ketat"""
    tick = mt5.symbol_info_tick(SYMBOL)
    if tick is None:
        return False
        
    # point = mt5.symbol_info(SYMBOL).point
    # spread_points = (tick.ask - tick.bid) / point
    symbol_info = mt5.symbol_info(SYMBOL)
    point = symbol_info.point
    # Hitung spread dalam points DAN dalam Dollar
    spread_points = symbol_info.spread
    spread_dollars = spread_points * point

     # Cetak info spread agar Anda tahu nilai aslinya
    print(f"[{datetime.now().strftime('%H:%M:%S')}] [INFO] Spread saat ini: {spread_points} points (=${spread_dollars:.2f})")
    
    # ==========================================
    # REKOMENDASI NILAI BARU UNTUK BTC
    # ==========================================
    # Gunakan 150 hingga 300 points (setara $1.50 - $3.00)
    MAX_ALLOWED_SPREAD_POINTS = 3000

    
    # if spread_points > 20:
    #     print(f"[{datetime.now().strftime('%H:%M:%S')}] [SKIP] Spread terlalu lebar: {spread_points:.1f} points")
    #     return False
    if spread_points > MAX_ALLOWED_SPREAD_POINTS:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] [SKIP] Spread terlalu lebar: {spread_points} points (${spread_dollars:.2f})")
        return False
    
    order_type = mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL
    margin_req = mt5.order_calc_margin(order_type, SYMBOL, LOT_SIZE, entry_price)
    account = mt5.account_info()
    
    if account and account.margin_free < margin_req + 15:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] [SKIP] Free margin tidak cukup: ${account.margin_free:.2f}")
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
        "type_filling": mt5.ORDER_FILLING_IOC, # Jika error 10030, ganti ke mt5.ORDER_FILLING_FOK
    }
    
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] [ERROR] Order gagal: {result.retcode} - {result.comment}")
        return False
        
    print(f"[{datetime.now().strftime('%H:%M:%S')}] [SUCCESS] {direction} @ {entry_price:.2f} | SL:{sl:.2f} TP:{tp:.2f}")
    return True

def manage_trailing_stop():
    """Trailing stop berbasis ATR"""
    positions = mt5.positions_get(symbol=SYMBOL)
    if positions is None or len(positions) == 0:
        return
    
    pos = positions[0]
    df_m15 = calculate_statistical_features(get_rates(SYMBOL, mt5.TIMEFRAME_M15))
    
    if df_m15.empty:
        return
        
    current_atr = df_m15.iloc[-1]['atr']
    trail_distance = current_atr * ATR_TRAILING_MULT
    
    tick = mt5.symbol_info_tick(SYMBOL)
    if tick is None:
        return
    
    if pos.type == mt5.POSITION_TYPE_BUY:
        new_sl = tick.bid - trail_distance
        if new_sl > pos.sl and new_sl < tick.bid:
            request = {"action": mt5.TRADE_ACTION_SLTP, "symbol": SYMBOL, "sl": round(new_sl, 2), "position": pos.ticket}
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"[{datetime.now().strftime('%H:%M:%S')}] [TRAIL] Buy SL digeser ke {new_sl:.2f}")
                
    elif pos.type == mt5.POSITION_TYPE_SELL:
        new_sl = tick.ask + trail_distance
        if (new_sl < pos.sl or pos.sl == 0) and new_sl > tick.ask:
            request = {"action": mt5.TRADE_ACTION_SLTP, "symbol": SYMBOL, "sl": round(new_sl, 2), "position": pos.ticket}
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"[{datetime.now().strftime('%H:%M:%S')}] [TRAIL] Sell SL digeser ke {new_sl:.2f}")

def run_bot_cycle():
    """Menjalankan SATU siklus logika bot (dipanggil berulang oleh loop utama)"""
    
    # 1. SAFETY CHECKS
    if check_daily_loss_limit():
        print(f"\n[HALT] Daily loss limit ${MAX_DAILY_LOSS_USD} tercapai. Bot berhenti otomatis.")
        return False # Perintahkan loop utama untuk berhenti
    
    # 2. CEK POSISI & TRAILING STOP
    if has_open_position():
        manage_trailing_stop()
        print(f"[{datetime.now().strftime('%H:%M:%S')}] [HOLD] Posisi terbuka terdeteksi, memantau trailing stop...")
        return True # Lanjut ke siklus berikutnya
    
    # 3. AMBIL DATA
    df_h4 = calculate_statistical_features(get_rates(SYMBOL, mt5.TIMEFRAME_H4))
    df_h1 = calculate_statistical_features(get_rates(SYMBOL, mt5.TIMEFRAME_H1))
    df_m15 = calculate_statistical_features(get_rates(SYMBOL, mt5.TIMEFRAME_M15))
    
    if df_h4.empty or df_m15.empty or df_h1.empty :
        print(f"[{datetime.now().strftime('%H:%M:%S')}] [WARNING] Data tidak cukup, skip cycle ini.")
        return True
    
    last_h4 = df_h4.iloc[-1]
    last_h1 = df_h1.iloc[-1]
    last_m15 = df_m15.iloc[-1]
    
    # 4. LOGIKA ENTRY
    trend_bullish = last_h4['lr_slope'] > 0
    trend_bearish = last_h4['lr_slope'] < 0
    
    signal = None
    entry_price = 0
    tick = mt5.symbol_info_tick(SYMBOL)
    
    if tick is None:
        return True

    if trend_bullish and last_m15['bb_zscore'] <= -ZSCORE_ENTRY_THRESHOLD:
        if last_m15['vol_zscore'] >= VOLUME_ZSCORE_MIN:
            signal = "BUY"
            entry_price = tick.ask
    
    elif trend_bearish and last_m15['bb_zscore'] >= ZSCORE_ENTRY_THRESHOLD:
        if last_m15['vol_zscore'] >= VOLUME_ZSCORE_MIN:
            signal = "SELL"
            entry_price = tick.bid
    
    # 5. EKSEKUSI
    if signal:
        atr_val = last_m15['atr']
        sl_distance = min(MAX_RISK_USD, atr_val * 2.0)
        
        if signal == "BUY":
            sl = entry_price - sl_distance
            tp = entry_price + (sl_distance * 2.0)
        else:
            sl = entry_price + sl_distance
            tp = entry_price - (sl_distance * 2.0)
            
        execute_trade(signal, entry_price, sl, tp)
    else:
        print(f"[{datetime.now().strftime('%H:%M:%S')}] [SCAN] No signal | H4 Slope: {last_h4['lr_slope']:.4f} | M15 Z-Score: {last_m15['bb_zscore']:.2f}")
        
    return True # Lanjut ke siklus berikutnya


# ==============================================================================
# MAIN LOOP (REALTIME ENGINE)
# ==============================================================================
if __name__ == "__main__":
    print("=" * 70)
    print(f"🤖 STATISTICAL EDGE BOT | Interval: {CHECK_INTERVAL_SECONDS} detik")
    print("=" * 70)

    # 1. Inisialisasi MT5 HANYA SEKALI di awal
    if not mt5.initialize():
        print("❌ Gagal connect ke MT5. Pastikan terminal MT5 sudah terbuka.")
        quit()
    
    print("✅ Terhubung ke MT5. Memulai pemantauan realtime...\n")

    try:
        # 2. Loop Tak Terhingga (Realtime)
        while True:
            # Jalankan satu siklus logika
            keep_running = run_bot_cycle()
            
            # Jika fungsi mengembalikan False (misal: daily loss tercapai), hentikan loop
            if not keep_running:
                break
                
            # 3. Jeda waktu sebelum siklus berikutnya (15 atau 60 detik)
            time.sleep(CHECK_INTERVAL_SECONDS)
            
    except KeyboardInterrupt:
        print("\n🛑 Bot dihentikan secara manual oleh user (Ctrl+C).")
    except Exception as e:
        print(f"\n❌ Error tidak terduga: {e}")
    finally:
        # 4. Pastikan koneksi ditutup dengan rapi saat bot berhenti
        mt5.shutdown()
        print("🔌 Koneksi MT5 ditutup dengan aman.")