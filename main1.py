import os
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'  # Senyapkan log TensorFlow

import MetaTrader5 as mt5
import pandas as pd
import ta
from datetime import datetime
import time

# --- KONFIGURASI ---
SYMBOLS_TO_TRADE = ["BTCUSD.vx", "XAUUSD.vx","EURUSD.vx"]
TIMEFRAMES = {
    "H4": mt5.TIMEFRAME_H4,
    "H1": mt5.TIMEFRAME_H1,
    "M15": mt5.TIMEFRAME_M15,
    "M5": mt5.TIMEFRAME_M5
}

# --- 1. Inisialisasi MetaTrader 5 ---
print("🔄 Menghubungkan ke MetaTrader 5...")
if not mt5.initialize():
    print(f"❌ Gagal terhubung ke MT5. Error: {mt5.last_error()}")
    quit()

account_info = mt5.account_info()
if account_info is not None:
    print(f"✅ Terhubung! Akun: {account_info.login} | Server: {account_info.server} | Saldo: ${account_info.balance:.2f}")
else:
    print("❌ Gagal mendapatkan info akun.")
    mt5.shutdown()
    quit()

# --- 2. Fungsi Mengambil Data & Menghitung Semua Indikator ---
def get_market_data_with_indicators(symbol, timeframe, bars=200):
    # Pastikan simbol terdaftar di Market Watch
    mt5.symbol_select(symbol, True)
    
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)
    if rates is None or len(rates) == 0:
        return None
    
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    # --- HITUNG INDIKATOR ---
    # 1. Moving Averages (EMA)
    df['ema_20'] = ta.trend.ema_indicator(df['close'], window=20)
    df['ema_50'] = ta.trend.ema_indicator(df['close'], window=50)
    df['ema_100'] = ta.trend.ema_indicator(df['close'], window=100)
    
    # 2. RSI (Period 14)
    df['rsi_14'] = ta.momentum.rsi(df['close'], window=14)
    
    # 3. Bollinger Bands (Period 20, Deviasi default 2)
    df['bb_mid'] = ta.volatility.bollinger_mavg(df['close'], window=20)
    df['bb_upper'] = ta.volatility.bollinger_hband(df['close'], window=20)
    df['bb_lower'] = ta.volatility.bollinger_lband(df['close'], window=20)
    
    # 4. MACD (Fast=12, Slow=26, Signal=9)
    df['macd'] = ta.trend.macd(df['close'], window_fast=12, window_slow=26)
    df['macd_signal'] = ta.trend.macd_signal(df['close'], window_fast=12, window_slow=26, window_sign=9)
    df['macd_diff'] = df['macd'] - df['macd_signal'] # Histogram MACD
    
    return df

# --- 3. Fungsi Analisis Multi-Timeframe (MTF) ---
def check_mtf_signal(symbol):
    # Ambil data dari semua timeframe (gunakan iloc[-2] untuk candle yang SUDAH CLOSE, menghindari repainting)
    data_h4 = get_market_data_with_indicators(symbol, TIMEFRAMES["H4"])
    data_h1 = get_market_data_with_indicators(symbol, TIMEFRAMES["H1"])
    data_m15 = get_market_data_with_indicators(symbol, TIMEFRAMES["M15"])
    data_m5 = get_market_data_with_indicators(symbol, TIMEFRAMES["M5"])
    
    # Pastikan semua data terisi dan tidak NaN
    if any(df is None or df.iloc[-2].isna().any() for df in [data_h4, data_h1, data_m15, data_m5]):
        return "HOLD", None

    # Ambil candle terakhir yang sudah close (index -2)
    h4 = data_h4.iloc[-2]
    h1 = data_h1.iloc[-2]
    m15 = data_m15.iloc[-2]
    m5 = data_m5.iloc[-2]
    
    # ==========================================
    # LOGIKA SINYAL (Bisa Anda sesuaikan sendiri)
    # ==========================================
    
    # --- KONDISI BUY ---
    # 1. Tren H4 & H1 Naik (Harga > EMA 50 & EMA 100)
    h4_uptrend = h4['close'] > h4['ema_50'] and h4['ema_50'] > h4['ema_100']
    h1_uptrend = h1['close'] > h1['ema_50'] and h1['ema_50'] > h1['ema_100']
    
    # 2. Momentum M15 Positif (MACD > Signal dan RSI > 50)
    m15_momentum = m15['macd_diff'] > 0 and m15['rsi_14'] > 50
    
    # 3. Trigger M5 (Harga menembus EMA 20 ke atas, atau MACD baru crossover)
    m5_trigger = m5['close'] > m5['ema_20'] and m5['macd_diff'] > 0
    
    if h4_uptrend and h1_uptrend and m15_momentum and m5_trigger:
        return "BUY", m5
    
    # --- KONDISI SELL ---
    # 1. Tren H4 & H1 Turun (Harga < EMA 50 & EMA 100)
    h4_downtrend = h4['close'] < h4['ema_50'] and h4['ema_50'] < h4['ema_100']
    h1_downtrend = h1['close'] < h1['ema_50'] and h1['ema_50'] < h1['ema_100']
    
    # 2. Momentum M15 Negatif (MACD < Signal dan RSI < 50)
    m15_momentum_neg = m15['macd_diff'] < 0 and m15['rsi_14'] < 50
    
    # 3. Trigger M5 (Harga menembus EMA 20 ke bawah)
    m5_trigger_neg = m5['close'] < m5['ema_20'] and m5['macd_diff'] < 0
    
    if h4_downtrend and h1_downtrend and m15_momentum_neg and m5_trigger_neg:
        return "SELL", m5
        
    return "HOLD", m5

# --- 4. Loop Utama Bot ---
print("\n🤖 Bot Multi-Timeframe Scalper dimulai. Tekan Ctrl+C untuk berhenti.\n")

try:
    while True:
        for symbol in SYMBOLS_TO_TRADE:
            signal, trigger_candle = check_mtf_signal(symbol)
            
            if signal != "HOLD":
                print(f"🚨 [{datetime.now().strftime('%H:%M:%S')}] SINYAL {signal} pada {symbol}!")
                print(f"   📊 Trigger M5 -> Close: {trigger_candle['close']:.2f} | RSI: {trigger_candle['rsi_14']:.2f} | MACD Diff: {trigger_candle['macd_diff']:.5f}")
                print(f"   💡 BB Upper: {trigger_candle['bb_upper']:.2f} | BB Lower: {trigger_candle['bb_lower']:.2f}")
                # TODO: Di sini Anda bisa menambahkan fungsi mt5.order_send() untuk eksekusi otomatis
                
            else:
                # Opsional: Tampilkan status scan agar tahu bot masih hidup (uncomment baris di bawah jika ingin verbose)
                # print(f"⏳ [{datetime.now().strftime('%H:%M:%S')}] {symbol}: Memindai pasar (HOLD)...")
                pass
        
        # Tunggu 60 detik sebelum scan ulang (Cukup untuk timeframe terkecil M5, menghemat resource CPU)
        time.sleep(60)

except KeyboardInterrupt:
    print("\n🛑 Bot dihentikan oleh pengguna.")
finally:
    mt5.shutdown()
    print("🔌 Koneksi ke MetaTrader 5 ditutup.")