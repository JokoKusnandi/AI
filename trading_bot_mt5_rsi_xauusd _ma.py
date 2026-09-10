import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ============================================================
# 1. KONFIGURASI STRATEGI
# ============================================================
SYMBOL = "XAUUSD.vx"          # Sesuaikan dengan simbol broker Anda
MAGIC_NUMBER = 20240520       # ID unik untuk mengenali order bot ini

# Timeframe
TF_H4 = mt5.TIMEFRAME_H4
TF_H1 = mt5.TIMEFRAME_H1
TF_M15 = mt5.TIMEFRAME_M15

# Parameter Indikator
RSI_PERIOD = 14
MA_FAST = 20
MA_MID = 50
MA_SLOW = 100
MA_TREND = 200

# Parameter Trigger RSI M15
RSI_BUY_CROSS_LEVEL = 40      # RSI cross up di atas 40
RSI_SELL_CROSS_LEVEL = 60     # RSI cross down di bawah 60

# Manajemen Risiko (DINAMIS BERBASIS ATR)
ATR_PERIOD = 14
ATR_SL_MULTIPLIER = 2.0       # SL = 2.0 x ATR (Menyesuaikan volatilitas XAUUSD)
ATR_TP_MULTIPLIER = 4.0       # TP = 4.0 x ATR (Risk:Reward 1:2)
MAX_RISK_PERCENT = 2.0        # Maksimal 2% risiko per trade dari equity

# Filter Tambahan
MIN_TREND_SEPARATION_PCT = 0.001 # Minimal jarak 0.1% antara MA50 dan MA200 di H4 (Filter Sideways)

# ============================================================
# 2. FUNGSI INDICATOR (Pure Pandas, tanpa library tambahan)
# ============================================================

def get_data(symbol, timeframe, count=300):
    """Mengambil data candle dan mengonversinya ke DataFrame Pandas"""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    if rates is None or len(rates) == 0:
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    return df

def calculate_sma(df, period):
    """Menghitung Simple Moving Average"""
    return df['close'].rolling(window=period).mean()

def calculate_rsi(df, period=14):
    """Menghitung RSI (Wilder's Smoothing)"""
    delta = df['close'].diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=period).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=period).mean()
    rs = gain / loss
    return 100 - (100 / (1 + rs))

def calculate_atr(df, period=14):
    """Menghitung Average True Range (ATR) untuk volatilitas dinamis"""
    high_low = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close = np.abs(df['low'] - df['close'].shift())
    ranges = pd.concat([high_low, high_close, low_close], axis=1)
    true_range = np.max(ranges, axis=1)
    return true_range.rolling(period).mean()

# ============================================================
# 3. LOGIKA BUSINESS (Multi-Timeframe Analysis)
# ============================================================

def analyze_market():
    """Menganalisis kondisi pasar berdasarkan logika bisnis yang ditetapkan"""
    # Ambil data
    df_h4 = get_data(SYMBOL, TF_H4, 300)
    df_h1 = get_data(SYMBOL, TF_H1, 300)
    df_m15 = get_data(SYMBOL, TF_M15, 300)
    
    if df_h4 is None or df_h1 is None or df_m15 is None:
        print("❌ Gagal mengambil data pasar.")
        return None

    # --- Hitung Indikator ---
    df_h4['ma50'] = calculate_sma(df_h4, 50)
    df_h4['ma200'] = calculate_sma(df_h4, 200)
    
    df_h1['ma50'] = calculate_sma(df_h1, 50)
    
    df_m15['ma20'] = calculate_sma(df_m15, 20)
    df_m15['ma50'] = calculate_sma(df_m15, 50)
    df_m15['rsi'] = calculate_rsi(df_m15, RSI_PERIOD)
    df_m15['atr'] = calculate_atr(df_m15, ATR_PERIOD)

    # Ambil nilai terbaru (index -1) dan sebelumnya (index -2) untuk deteksi cross
    current_h4 = df_h4.iloc[-1]
    current_h1 = df_h1.iloc[-1]
    current_m15 = df_m15.iloc[-1]
    prev_m15 = df_m15.iloc[-2]

    # --- 1. Filter H4: Macro Trend & Sideways Check ---
    trend_separation = abs(current_h4['ma50'] - current_h4['ma200']) / current_h4['ma200']
    if trend_separation < MIN_TREND_SEPARATION_PCT:
        return {'signal': None, 'reason': 'H4 Sideways (MA terlalu rapat)'}

    if current_h4['close'] > current_h4['ma200'] and current_h4['ma50'] > current_h4['ma200']:
        h4_bias = 'BULLISH'
    elif current_h4['close'] < current_h4['ma200'] and current_h4['ma50'] < current_h4['ma200']:
        h4_bias = 'BEARISH'
    else:
        return {'signal': None, 'reason': 'H4 Trend Tidak Jelas'}

    # --- 2. Filter H1: Intermediate Trend ---
    if h4_bias == 'BULLISH' and current_h1['close'] < current_h1['ma50']:
        return {'signal': None, 'reason': 'H1 Koreksi Terlalu Dalam (Close < MA50)'}
    if h4_bias == 'BEARISH' and current_h1['close'] > current_h1['ma50']:
        return {'signal': None, 'reason': 'H1 Rally Terlalu Kuat (Close > MA50)'}

    # --- 3. Trigger M15: Pullback & RSI Cross ---
    current_price = current_m15['close']
    current_rsi = current_m15['rsi']
    prev_rsi = prev_m15['rsi']
    current_atr = current_m15['atr']
    
    # Toleransi jarak harga ke MA (misal: dalam jangkauan 1x ATR)
    tolerance = current_atr * 1.0 

    # Skenario BUY
    if h4_bias == 'BULLISH':
        # Harga mendekati MA20 atau MA50
        near_ma = (abs(current_price - current_m15['ma20']) <= tolerance) or \
                  (abs(current_price - current_m15['ma50']) <= tolerance)
        # RSI Cross Up melewati level 40
        rsi_cross_up = (prev_rsi <= RSI_BUY_CROSS_LEVEL) and (current_rsi > RSI_BUY_CROSS_LEVEL)
        
        if near_ma and rsi_cross_up:
            return {
                'signal': 'BUY',
                'atr': current_atr,
                'price': current_price,
                'rsi': current_rsi,
                'reason': f"BULLISH H4/H1 + Pullback MA + RSI Cross Up ({prev_rsi:.1f} -> {current_rsi:.1f})"
            }

    # Skenario SELL
    if h4_bias == 'BEARISH':
        # Harga mendekati MA20 atau MA50
        near_ma = (abs(current_price - current_m15['ma20']) <= tolerance) or \
                  (abs(current_price - current_m15['ma50']) <= tolerance)
        # RSI Cross Down melewati level 60
        rsi_cross_down = (prev_rsi >= RSI_SELL_CROSS_LEVEL) and (current_rsi < RSI_SELL_CROSS_LEVEL)
        
        if near_ma and rsi_cross_down:
            return {
                'signal': 'SELL',
                'atr': current_atr,
                'price': current_price,
                'rsi': current_rsi,
                'reason': f"BEARISH H4/H1 + Pullback MA + RSI Cross Down ({prev_rsi:.1f} -> {current_rsi:.1f})"
            }

    return {'signal': None, 'reason': 'Menunggu setup M15 yang valid'}

# ============================================================
# 4. MANAJEMEN RISIKO & EKSEKUSI
# ============================================================

def calculate_dynamic_sl_tp(entry_price, order_type, atr_value):
    """Menghitung SL dan TP berbasis ATR (Menyesuaikan volatilitas XAUUSD)"""
    symbol_info = mt5.symbol_info(SYMBOL)
    digits = symbol_info.digits
    
    sl_distance = atr_value * ATR_SL_MULTIPLIER
    tp_distance = atr_value * ATR_TP_MULTIPLIER
    
    # Cek Stops Level broker
    stops_level = symbol_info.trade_stops_level
    min_distance = (stops_level + 10) * symbol_info.point if stops_level > 0 else 0
    
    if order_type == mt5.ORDER_TYPE_BUY:
        sl = entry_price - max(sl_distance, min_distance)
        tp = entry_price + max(tp_distance, min_distance)
    else:
        sl = entry_price + max(sl_distance, min_distance)
        tp = entry_price - max(tp_distance, min_distance)
        
    return round(sl, digits), round(tp, digits)

def calculate_lot_size(sl_distance, entry_price):
    """Menghitung lot berdasarkan risiko persentase dari equity"""
    account = mt5.account_info()
    if account is None:
        return 0.01
        
    symbol_info = mt5.symbol_info(SYMBOL)
    tick_value = symbol_info.trade_tick_value
    tick_size = symbol_info.trade_tick_size
    
    # Hitung nilai risiko dalam USD
    risk_usd = account.balance * (MAX_RISK_PERCENT / 100)
    
    # Hitung lot: Risk / (Jarak SL dalam poin * Nilai per poin)
    # Catatan: Ini adalah penyederhanaan. Untuk akurasi sempurna, gunakan mt5.order_calc_margin atau kalkulasi tick yang presisi.
    point = symbol_info.point
    distance_in_points = abs(entry_price - (entry_price - sl_distance if True else entry_price + sl_distance)) / point
    value_per_point_per_lot = (tick_value / tick_size) * point if tick_size > 0 else 1.0
    
    lot = risk_usd / (distance_in_points * value_per_point_per_lot)
    
    # Batasi sesuai aturan broker
    min_lot = symbol_info.volume_min
    max_lot = symbol_info.volume_max
    step = symbol_info.volume_step
    
    lot = max(min_lot, min(max_lot, lot))
    lot = round(lot / step) * step
    
    return round(lot, 2)

def send_order(order_type, volume, sl, tp, comment):
    """Mengirim order dengan mekanisme fallback jika ditolak broker"""
    tick = mt5.symbol_info_tick(SYMBOL)
    price = tick.ask if order_type == mt5.ORDER_TYPE_BUY else tick.bid
    
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": SYMBOL,
        "volume": volume,
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": 30,
        "magic": MAGIC_NUMBER,
        "comment": comment,
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_FOK, # Coba FOK dulu
    }
    
    result = mt5.order_send(request)
    
    # Fallback jika Invalid Stops (10016)
    if result.retcode == 10016:
        print("   ⚠️ Ditolak (10016). Mencoba buka posisi dulu, baru modifikasi SL/TP...")
        request["sl"] = 0.0
        request["tp"] = 0.0
        request["type_filling"] = mt5.ORDER_FILLING_IOC # Ganti filling mode untuk fallback
        
        open_result = mt5.order_send(request)
        if open_result.retcode == mt5.TRADE_RETCODE_DONE:
            time.sleep(1.5) # Tunggu server broker
            modify_request = {
                "action": mt5.TRADE_ACTION_SLTP,
                "symbol": SYMBOL,
                "sl": sl,
                "tp": tp,
                "position": open_result.order,
            }
            mod_result = mt5.order_send(modify_request)
            if mod_result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"✅ Fallback SUKSES! Ticket: {open_result.order}")
                return True
            else:
                print(f"🚨 PERINGATAN: Posisi terbuka TANPA SL/TP! Ticket: {open_result.order}")
                return True
        else:
            print(f"❌ Fallback Gagal: {open_result.comment}")
            return False
            
    elif result.retcode == mt5.TRADE_RETCODE_DONE:
        print(f"✅ Order SUKSES! Ticket: {result.order} | Price: {price} | SL: {sl} | TP: {tp}")
        return True
    else:
        print(f"❌ Order Gagal: {result.retcode} - {result.comment}")
        return False

# ============================================================
# 5. MAIN LOOP
# ============================================================

def main():
    print("="*70)
    print("🤖 XAUUSD TREND FOLLOWING BOT (MA + RSI + ATR)")
    print("="*70)
    
    if not mt5.initialize():
        print("❌ Gagal inisialisasi MT5")
        return
        
    if not mt5.symbol_select(SYMBOL, True):
        print(f"❌ Gagal memilih simbol {SYMBOL}")
        mt5.shutdown()
        return
        
    print(f"✅ Terhubung ke MT5. Monitoring {SYMBOL}...")
    print(f"⚙️  SL: {ATR_SL_MULTIPLIER}x ATR | TP: {ATR_TP_MULTIPLIER}x ATR | Risk: {MAX_RISK_PERCENT}%")
    print("-"*70)
    
    last_action_time = 0
    
    try:
        while True:
            # Batasi eksekusi agar tidak spam (cek setiap 15 detik)
            if time.time() - last_action_time < 15:
                time.sleep(1)
                continue
                
            # 1. Cek apakah sudah ada posisi terbuka dari bot ini
            positions = mt5.positions_get(symbol=SYMBOL)
            has_position = False
            if positions:
                for pos in positions:
                    if pos.magic == MAGIC_NUMBER:
                        has_position = True
                        break
            
            if not has_position:
                # 2. Analisis Pasar
                analysis = analyze_market()
                
                if analysis['signal'] in ['BUY', 'SELL']:
                    print(f"\n🚀 SINYAL DITEMUKAN: {analysis['signal']}")
                    print(f"   Alasan: {analysis['reason']}")
                    
                    order_type = mt5.ORDER_TYPE_BUY if analysis['signal'] == 'BUY' else mt5.ORDER_TYPE_SELL
                    entry_price = analysis['price']
                    atr = analysis['atr']
                    
                    # 3. Hitung SL, TP, dan Lot Dinamis
                    sl, tp = calculate_dynamic_sl_tp(entry_price, order_type, atr)
                    lot = calculate_lot_size(abs(entry_price - sl), entry_price)
                    
                    print(f"   📊 Entry: {entry_price} | SL: {sl} | TP: {tp}")
                    print(f"   💰 Lot yang dihitung: {lot} (Berdasarkan {MAX_RISK_PERCENT}% risk)")
                    
                    # 4. Eksekusi
                    comment = f"TF_M15_{analysis['signal']}_RSI{analysis['rsi']:.0f}"
                    if send_order(order_type, lot, sl, tp, comment):
                        last_action_time = time.time() # Reset timer setelah order
                        
            else:
                print(f"[{datetime.now().strftime('%H:%M:%S')}] Posisi sudah terbuka. Monitoring untuk exit...", end='\r')
                
            time.sleep(5)
            
    except KeyboardInterrupt:
        print("\n\n🛑 Bot dihentikan oleh pengguna.")
    finally:
        mt5.shutdown()
        print("🔌 Koneksi MT5 ditutup.")

if __name__ == "__main__":
    main()