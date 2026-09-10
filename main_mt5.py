import os
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'  # Senyapkan log TensorFlow

import MetaTrader5 as mt5
import pandas as pd
import ta
from datetime import datetime
import time

# --- 1. Inisialisasi MetaTrader 5 ---
print("🔄 Menghubungkan ke MetaTrader 5...")
if not mt5.initialize():
    print(f"❌ Gagal terhubung ke MT5. Error: {mt5.last_error()}")
    quit()

account_info = mt5.account_info()
if account_info is not None:
    print(f"✅ Terhubung! Akun: {account_info.login} | Server: {account_info.server}")
else:
    print("❌ Gagal mendapatkan info akun.")
    mt5.shutdown()
    quit()

# --- 2. Fungsi Mengambil Data & Indikator ---
def get_market_data(symbol="BTCUSD.vx", timeframe=mt5.TIMEFRAME_M5, bars=100):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)
    if rates is None or len(rates) == 0:
        return None
    
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    # Hitung Indikator sesuai JSON Anda
    df['ema_fast'] = ta.trend.ema_indicator(df['close'], window=20)
    df['ema_slow'] = ta.trend.ema_indicator(df['close'], window=50)
    df['rsi'] = ta.momentum.rsi(df['close'], window=14)
    df['atr'] = ta.volatility.average_true_range(df['high'], df['low'], df['close'], window=14)
    
    return df

# --- 3. Fungsi Cek Sinyal Trading ---
def check_signal(df):
    # Ambil data candle terakhir yang sudah close (index -2)
    last_close = df.iloc[-2]
    
    ema_fast = last_close['ema_fast']
    ema_slow = last_close['ema_slow']
    close_price = last_close['close']
    rsi = last_close['rsi']
    
    # Logika Buy
    if ema_fast > ema_slow and close_price > ema_fast and rsi > 55:
        return "BUY", last_close
    
    # Logika Sell
    elif ema_fast < ema_slow and close_price < ema_fast and rsi < 45:
        return "SELL", last_close
        
    return "HOLD", last_close

# --- 4. Loop Utama Bot ---
print("\n🤖 Bot M5 EMA Scalper dimulai. Tekan Ctrl+C untuk berhenti.\n")
symbol_to_trade = "BTCUSD.vx"

try:
    while True:
        # Cek apakah sudah ganti candle M5 baru (opsional, untuk efisiensi)
        df = get_market_data(symbol=symbol_to_trade)
        
        if df is not None:
            signal, last_candle = check_signal(df)
            
            if signal != "HOLD":
                print(f"🚨 SINYAL {signal} TERDETEKSI pada {last_candle['time']}!")
                print(f"   Close: {last_candle['close']} | RSI M5: {last_candle['rsi']:.2f} | ATR: {last_candle['atr']:.5f}")
                # TODO: Tambahkan logika eksekusi order di sini (mt5.order_send)
            else:
                print(f"⏳ Memindai pasar... (Candle terakhir: {last_candle['time'].strftime('%H:%M:%S')})")
        
        # Tunggu 10 detik sebelum cek lagi (agar tidak spam request ke MT5)
        time.sleep(10)

except KeyboardInterrupt:
    print("\n🛑 Bot dihentikan oleh pengguna.")
finally:
    mt5.shutdown()
    print("🔌 Koneksi ke MetaTrader 5 ditutup.")