import MetaTrader5 as mt5
import pandas as pd
import pandas_ta as ta
import time
import logging

# ================= KONFIGURASI (INPUT PARAMETERS) =================
SYMBOL = "XAUUSD.vx"
LOT_SIZE = 0.01
MAGIC_NUMBER = 123456
SHOW_LOGS = True
RISK_AMOUNT_USD = 25.0
REWARD_AMOUNT_USD = 0.8  # ⚠️ PERHATIAN: Reward $0.8 untuk Risk $25 sangat kecil (RR 1:0.03). Pastikan ini disengaja.

# Mapping Timeframe MQL5 ke MT5 Python
TF_M5 = mt5.TIMEFRAME_M5
TF_M15 = mt5.TIMEFRAME_M15
TF_H1 = mt5.TIMEFRAME_H1
TF_H4 = mt5.TIMEFRAME_H4

# State Tracking
last_candle_time_m5 = 0

# ================= HELPER FUNCTIONS =================

def get_data(timeframe, bars=100):
    """Mengambil data OHLCV dari MT5"""
    rates = mt5.copy_rates_from_pos(SYMBOL, timeframe, 0, bars)
    if rates is None or len(rates) == 0:
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    return df

def calculate_indicators(df):
    """Menghitung RSI, MA, dan MACD menggunakan pandas_ta"""
    # RSI 14
    df['rsi'] = ta.rsi(df['close'], length=14)
    # MA 20 & 50 (SMA)
    df['ma20'] = ta.sma(df['close'], length=20)
    df['ma50'] = ta.sma(df['close'], length=50)
    # MACD 12, 26, 9 (Kita hanya butuh main line seperti di kode MQL5)
    macd_df = ta.macd(df['close'], fast=12, slow=26, signal=9)
    df['macd'] = macd_df['MACD_12_26_9']
    return df

def calculate_sl_tp(is_buy):
    """Menghitung SL dan TP berdasarkan nominal USD (sama seperti logika MQL5)"""
    symbol_info = mt5.symbol_info(SYMBOL)
    if symbol_info is None:
        return 0.0, 0.0

    tick_size = symbol_info.trade_tick_size
    tick_value = symbol_info.trade_tick_value
    point = symbol_info.point
    lot = LOT_SIZE

    if tick_size <= 0 or tick_value <= 0 or lot <= 0:
        return 0.0, 0.0

    # Hitung jarak harga
    sl_distance = (RISK_AMOUNT_USD * tick_size) / (tick_value * lot)
    tp_distance = (REWARD_AMOUNT_USD * tick_size) / (tick_value * lot)

    # Normalisasi ke point terdekat
    sl_distance = round(sl_distance / point) * point
    tp_distance = round(tp_distance / point) * point

    current_price = mt5.symbol_info_tick(SYMBOL).ask if is_buy else mt5.symbol_info_tick(SYMBOL).bid

    if is_buy:
        sl = round(current_price - sl_distance, symbol_info.digits)
        tp = round(current_price + tp_distance, symbol_info.digits)
    else:
        sl = round(current_price + sl_distance, symbol_info.digits)
        tp = round(current_price - tp_distance, symbol_info.digits)

    # Cek Stop Level minimum dari broker
    stop_level_points = symbol_info.trade_stops_level
    if stop_level_points > 0:
        stop_level_distance = stop_level_points * point
        if is_buy:
            if current_price - sl < stop_level_distance:
                sl = round(current_price - stop_level_distance, symbol_info.digits)
            if tp - current_price < stop_level_distance:
                tp = round(current_price + stop_level_distance, symbol_info.digits)
        else:
            if sl - current_price < stop_level_distance:
                sl = round(current_price + stop_level_distance, symbol_info.digits)
            if current_price - tp < stop_level_distance:
                tp = round(current_price - stop_level_distance, symbol_info.digits)

    return sl, tp

def send_order(order_type, price, sl, tp, comment):
    """Mengirim order ke MT5"""
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": SYMBOL,
        "volume": LOT_SIZE,
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": 20,
        "magic": MAGIC_NUMBER,
        "comment": comment,
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC, # atau ORDER_FILLING_FOK tergantung broker
    }
    
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"❌ Order Failed: {result.retcode} - {result.comment}")
        return False
    else:
        print(f"✅ Order Success: {comment} at {price}, SL: {sl}, TP: {tp}")
        return True

# ================= MAIN LOGIC =================

def on_tick():
    global last_candle_time_m5

    # 1. Ambil Data Semua Timeframe
    df_m5 = get_data(TF_M5, 100)
    df_m15 = get_data(TF_M15, 100)
    df_h1 = get_data(TF_H1, 100)
    df_h4 = get_data(TF_H4, 100)

    if any(df is None for df in [df_m5, df_m15, df_h1, df_h4]):
        print("Gagal mengambil data. Cek koneksi MT5 atau simbol.")
        return

    # 2. Hitung Indikator
    df_m5 = calculate_indicators(df_m5)
    df_m15 = calculate_indicators(df_m15)
    df_h1 = calculate_indicators(df_h1)
    df_h4 = calculate_indicators(df_h4)

    # 3. Ambil Nilai Terbaru 
    # Catatan: MQL5 kode Anda menggunakan buf[1] untuk H4,H1,M15 (candle tertutup) 
    # dan buf[0] untuk M5 (candle berjalan). Kita ikuti pola yang sama.
    h4_rsi = df_h4['rsi'].iloc[-2]
    h1_rsi = df_h1['rsi'].iloc[-2]
    m15_rsi = df_m15['rsi'].iloc[-2]
    m5_rsi = df_m5['rsi'].iloc[-1] # Current candle

    ma20_m5 = df_m5['ma20'].iloc[-1]
    ma50_m5 = df_m5['ma50'].iloc[-1]
    ma20_m15 = df_m15['ma20'].iloc[-2]
    ma50_m15 = df_m15['ma50'].iloc[-2]
    ma20_h1 = df_h1['ma20'].iloc[-2]
    ma50_h1 = df_h1['ma50'].iloc[-2]

    macd_m5 = df_m5['macd'].iloc[-2]
    macd_m15 = df_m15['macd'].iloc[-2]
    macd_h1 = df_h1['macd'].iloc[-2]

    # Logging
    if SHOW_LOGS:
        print(f"📊 RSI: H4={h4_rsi:.2f}, H1={h1_rsi:.2f}, M15={m15_rsi:.2f}, M5(Curr)={m5_rsi:.2f}")
        print(f"📈 MA: M5(20/50)={ma20_m5:.2f}/{ma50_m5:.2f}, M15(20/50)={ma20_m15:.2f}/{ma50_m15:.2f}, H1(20/50)={ma20_h1:.2f}/{ma50_h1:.2f}")
        print(f"📉 MACD: M5={macd_m5:.4f}, M15={macd_m15:.4f}, H1={macd_h1:.4f}")

   

    # 4. Cek Kondisi Tren
    is_bullish_trend = (
        h4_rsi > 53 and h1_rsi > 53 and m15_rsi > 53 and m5_rsi > 53 and
        ma20_m5 > ma50_m5 and ma20_m15 > ma50_m15 and ma20_h1 > ma50_h1 and
        macd_m5 > 0 and macd_m15 > 0 and macd_h1 > 0
    )

    is_bearish_trend = (
        h4_rsi < 47 and h1_rsi < 47 and m15_rsi < 47 and m5_rsi < 47 and
        ma20_m5 < ma50_m5 and ma20_m15 < ma50_m15 and ma20_h1 < ma50_h1 and
        macd_m5 < 0 and macd_m15 < 0 and macd_h1 < 0
    )

    # ==========================================
    # 🆕 5. PRINT DETAIL NILAI & VALIDASI (DEBUG)
    # ==========================================
    if SHOW_LOGS:
        print("\n" + "="*65)
        print(" 🔍 [DEBUG] MULTI-TIMEFRAME TREND CHECKLIST")
        print("-" * 65)
        
        # --- BULLISH CHECKLIST ---
        print(" 🟢 SYARAT BULLISH:")
        print(f"  [{'✅' if h4_rsi > 53 else '❌'}] H4 RSI > 53    : {h4_rsi:.2f}")
        print(f"  [{'✅' if h1_rsi > 53 else '❌'}] H1 RSI > 53    : {h1_rsi:.2f}")
        print(f"  [{'✅' if m15_rsi > 53 else '❌'}] M15 RSI > 53   : {m15_rsi:.2f}")
        print(f"  [{'✅' if m5_rsi > 53 else '❌'}] M5 RSI > 53    : {m5_rsi:.2f}")
        print(f"  [{'✅' if ma20_m5 > ma50_m5 else '❌'}] MA M5 (20>50)  : {ma20_m5:.2f} > {ma50_m5:.2f}")
        print(f"  [{'✅' if ma20_m15 > ma50_m15 else '❌'}] MA M15 (20>50) : {ma20_m15:.2f} > {ma50_m15:.2f}")
        print(f"  [{'✅' if ma20_h1 > ma50_h1 else '❌'}] MA H1 (20>50)  : {ma20_h1:.2f} > {ma50_h1:.2f}")
        print(f"  [{'✅' if macd_m5 > 0 else '❌'}] MACD M5 > 0    : {macd_m5:.4f}")
        print(f"  [{'✅' if macd_m15 > 0 else '❌'}] MACD M15 > 0   : {macd_m15:.4f}")
        print(f"  [{'✅' if macd_h1 > 0 else '❌'}] MACD H1 > 0    : {macd_h1:.4f}")
        print(f"  👉 HASIL AKHIR BULLISH : {is_bullish_trend}")
        print("-" * 65)

        # --- BEARISH CHECKLIST ---
        print(" 🔴 SYARAT BEARISH:")
        print(f"  [{'✅' if h4_rsi < 47 else '❌'}] H4 RSI < 47    : {h4_rsi:.2f}")
        print(f"  [{'✅' if h1_rsi < 47 else '❌'}] H1 RSI < 47    : {h1_rsi:.2f}")
        print(f"  [{'✅' if m15_rsi < 47 else '❌'}] M15 RSI < 47   : {m15_rsi:.2f}")
        print(f"  [{'✅' if m5_rsi < 47 else '❌'}] M5 RSI < 47    : {m5_rsi:.2f}")
        print(f"  [{'✅' if ma20_m5 < ma50_m5 else '❌'}] MA M5 (20<50)  : {ma20_m5:.2f} < {ma50_m5:.2f}")
        print(f"  [{'✅' if ma20_m15 < ma50_m15 else '❌'}] MA M15 (20<50) : {ma20_m15:.2f} < {ma50_m15:.2f}")
        print(f"  [{'✅' if ma20_h1 < ma50_h1 else '❌'}] MA H1 (20<50)  : {ma20_h1:.2f} < {ma50_h1:.2f}")
        print(f"  [{'✅' if macd_m5 < 0 else '❌'}] MACD M5 < 0    : {macd_m5:.4f}")
        print(f"  [{'✅' if macd_m15 < 0 else '❌'}] MACD M15 < 0   : {macd_m15:.4f}")
        print(f"  [{'✅' if macd_h1 < 0 else '❌'}] MACD H1 < 0    : {macd_h1:.4f}")
        print(f"  👉 HASIL AKHIR BEARISH : {is_bearish_trend}")
        print("="*65 + "\n")

    # 5. Cek Candle Baru M5 (Opsional, tapi bagus untuk menghindari spam sinyal)
    current_candle_time_m5 = df_m5['time'].iloc[-1].timestamp()
    is_new_candle = (current_candle_time_m5 != last_candle_time_m5)
    if is_new_candle:
        last_candle_time_m5 = current_candle_time_m5

    # 6. Cek Posisi Terbuka
    positions = mt5.positions_get(symbol=SYMBOL, magic=MAGIC_NUMBER)
    if positions and len(positions) > 0:
        if SHOW_LOGS:
            print("⏸️ Posisi sudah terbuka. Menunggu penutupan...")
        return

    # 7. Eksekusi Sinyal
    tick = mt5.symbol_info_tick(SYMBOL)
    ask = tick.ask
    bid = tick.bid
    prev_m5_high = df_m5['high'].iloc[-2]
    prev_m5_low = df_m5['low'].iloc[-2]

    # --- BUY LOGIC ---
    if is_bullish_trend:
        m5_buy_signal = (m5_rsi > 50) and (ma20_m5 > ma50_m5)
        if m5_buy_signal and ask > prev_m5_high:
            print("🟢 >>> SIGNAL BUY DETECTED <<<")
            sl, tp = calculate_sl_tp(is_buy=True)
            send_order(mt5.ORDER_TYPE_BUY, ask, sl, tp, "Trend Buy")

    # --- SELL LOGIC ---
    elif is_bearish_trend:
        m5_sell_signal = (m5_rsi < 50) and (ma20_m5 < ma50_m5)
        if m5_sell_signal and bid < prev_m5_low:
            print("🔴 >>> SIGNAL SELL DETECTED <<<")
            sl, tp = calculate_sl_tp(is_buy=False)
            send_order(mt5.ORDER_TYPE_SELL, bid, sl, tp, "Trend Sell")


# ================= INITIALIZATION =================
if __name__ == "__main__":
    print("🔄 Menghubungkan ke MetaTrader 5...")
    if not mt5.initialize():
        print(f"❌ initialize() gagal, error code: {mt5.last_error()}")
        quit()
    
    # Pilih akun (opsional, hapus komentar jika perlu login spesifik)
    # mt5.login(12345678, "password", "ServerName")

    print(f"✅ Terhubung ke MT5. Akun: {mt5.account_info().login}")
    print(f"🚀 Memulai monitoring {SYMBOL}... (Tekan Ctrl+C untuk berhenti)")

    try:
        while True:
            on_tick()
            time.sleep(180) #tunggu 1 detik sebelum cek lagi(mencegah CPU overload)
    except KeyboardInterrupt:
        print("\n🛑 Program dihentikan oleh pengguna.")
    finally:
        mt5.shutdown()
        print("🔌 Koneksi MT5 ditutup.")