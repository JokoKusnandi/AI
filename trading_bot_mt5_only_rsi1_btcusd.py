import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ============================================================
# KONFIGURASI
# ============================================================
SYMBOL = "BTCUSD.vx"           # Ganti jika broker pakai simbol lain (contoh: BTCUSDm)
RSI_PERIOD = 14
MAGIC_NUMBER = 123456

# Semua timeframe sesuai permintaan
TIMEFRAMES = {
    'H4':  mt5.TIMEFRAME_H4,
    'H1':  mt5.TIMEFRAME_H1,
    'M30': mt5.TIMEFRAME_M30,
    'M15': mt5.TIMEFRAME_M15,
    'M5':  mt5.TIMEFRAME_M5,
    'M1':  mt5.TIMEFRAME_M1,
}

# Higher TF untuk filter arah (trend)
HTF_TIMEFRAMES = ['H4', 'H1', 'M30']

# Entry utama di M15, konfirmasi di M5
ENTRY_TIMEFRAME = TIMEFRAMES['M15']
CONFIRM_TIMEFRAME = TIMEFRAMES['M5']

# Parameter RSI
RSI_OVERSOLD = 30
RSI_OVERBOUGHT = 70
RSI_FLAT_30_ZONE = 30
RSI_FLAT_70_ZONE = 70
RSI_FLAT_TOLERANCE = 2
RSI_FLAT_THRESHOLD = 0.5

# TP dinamis berbasis RSI M15
TP_RSI_BUY_OVERSOLD = 60
TP_RSI_BUY_FLAT_30 = 50
TP_RSI_SELL_OVERBOUGHT = 40
TP_RSI_SELL_FLAT_70 = 50

# Risk & Lot
SL_POINTS = 150
MAX_RISK_PERCENT = 30

# ============================================================
# KONFIGURASI MULTI-TRADE (BARU)
# ============================================================
# Setiap kelipatan nilai ini, bot diizinkan membuka 1 trade tambahan (0.01 lot)
# PERHATIAN: Karena modal Anda ~$100,000, jika Anda set ini ke 100.0, 
# bot akan mencoba membuka 1000 trade! Disarankan 10000.0 (1 trade per $10k).
TRADE_BALANCE_STEP = 30 
LOT_PER_TRADE = 0.01          # Setiap trade selalu 0.01 lot

# ============================================================
# FUNGSI UTILITY
# ============================================================

def diagnose_account():
    """Diagnosa detail status akun dan login."""
    print("\n🔍 DIAGNOSA AKUN MT5:")
    print("-" * 50)
    
    # 1. Info Akun
    account_info = mt5.account_info()
    if account_info is None:
        print(" TIDAK ADA AKUN YANG LOGIN!")
        print("   Solusi: Login ke MT5 dengan Main Password (bukan Investor Password)")
        return False
    else:
        print(f"✅ Akun Login: {account_info.login}")
        print(f"   Server: {account_info.server}")
        print(f"   Nama: {account_info.name}")
        print(f"   Balance: ${account_info.balance:.2f}")
        print(f"   Equity: ${account_info.equity:.2f}")
        print(f"   Trade Allowed: {account_info.trade_allowed}")
        print(f"   Trade Expert: {account_info.trade_expert}")
        print(f"   Limit Orders: {account_info.limit_orders}")
        
    # 2. Info Terminal
    terminal_info = mt5.terminal_info()
    if terminal_info:
        print(f"\n✅ Terminal Info:")
        print(f"   Trade API Disabled: {terminal_info.tradeapi_disabled}")
        print(f"   Trade Allowed: {terminal_info.trade_allowed}")
        print(f"   Connected: {terminal_info.connected}")
        
    # 3. Info Koneksi
    if mt5.last_error():
        print(f"\n⚠️ Last Error: {mt5.last_error()}")
        
    print("-" * 50 + "\n")
    
    # Cek apakah akun bisa trading
    if not account_info.trade_allowed:
        print("❌ MASALAH DITEMUKAN:")
        print("   1. Anda login dengan INVESTOR PASSWORD (read-only)")
        print("   2. Atau akun belum diverifikasi/diaktifkan")
        print("   3. Atau akun sudah expired")
        print("\n✅ SOLUSI:")
        print("   1. Di MT5, klik File → Login to Trade Account")
        print("   2. Masukkan nomor akun dan MAIN PASSWORD (bukan Investor Password)")
        print("   3. Jika tidak tahu Main Password, hubungi broker Valetax")
        return False
        
    return True

BASE_BALANCE = 0.0  # Akan diisi saat init_mt5()
def init_mt5():
    global BASE_BALANCE # Agar bisa mengubah variabel global
    if not mt5.initialize():
        print("❌ Gagal inisialisasi MT5")
        return False
        
    print("✅ Terhubung ke MT5")

     # 1. Ambil dan simpan BASE_BALANCE saat pertama kali jalan
    account_info = mt5.account_info()
    if account_info:
        BASE_BALANCE = account_info.balance
        print(f"💰 Base Balance (Acuan Lot) ditetapkan: ${BASE_BALANCE:.2f}")
    
    # Cek status terminal
    terminal_info = mt5.terminal_info()
    if terminal_info is None:
        print("⚠️ Tidak bisa membaca info terminal.")
        return False

    # 1. Cek apakah AutoTrading aktif
    if terminal_info.tradeapi_disabled:
        print("❌ AutoTrading MASIH MATI! Aktifkan tombol 'Algo Trading' di toolbar MT5.")
        mt5.shutdown()
        return False  # ← Hentikan bot di sini
    else:
        print("✅ AutoTrading AKTIF di terminal MT5")
            
    # 2. Cek apakah akun diizinkan trading
    if not terminal_info.trade_allowed:
        print("❌ Trading TIDAK DIIZINKAN untuk akun ini (mungkin akun read-only atau belum login).")
        mt5.shutdown()
        return False  # ← Hentikan bot di sini
        
    print("🟢 Semua izin trading terpenuhi. Bot siap berjalan!")
    return True


def get_account_info():
    account = mt5.account_info()
    if account is None:
        print("❌ Gagal ambil info akun")
        return None
    return account


def calculate_dynamic_lot(symbol, current_equity):
    """0.01 lot per $100 equity"""
    """
    Menghitung lot dinamis berdasarkan KELIPATAN modal awal (BASE_BALANCE).
    
    CONTOH AMAN (Jika BASE_BALANCE = $100,000):
    - Equity $100,000  -> multiplier 1 -> lot 0.01
    - Equity $199,000  -> multiplier 1 -> lot 0.01 (Belum naik)
    - Equity $200,000  -> multiplier 2 -> lot 0.02 (Naik!)
    - Equity $300,000  -> multiplier 3 -> lot 0.03 (Naik!)
    """
    if current_equity <= 0 or BASE_BALANCE <= 0:
        return 0.01
    # lot = (int(equity) // 100) * 0.01
    # Hitung berapa kali modal awal sudah tercapai
    multiplier = max(1, int(current_equity // BASE_BALANCE))

     # Lot dasar adalah 0.01 dikali multiplier
    lot = multiplier * 0.01

    # Validasi dengan aturan broker (Safety Check)
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info:
        min_lot = symbol_info.volume_min or 0.01
        max_lot = symbol_info.volume_max or 100.0
        step = symbol_info.volume_step or 0.01
        
        # 1. Pastikan lot tidak melebihi batas max/min broker
        lot = max(min_lot, min(max_lot, lot))
        
        # 2. Bulatkan lot agar sesuai dengan 'step' broker (misal: 0.01, 0.02, dst)
        lot = round(lot / step) * step
        
    return round(lot, 2)

def get_rsi(symbol, timeframe, period=14, count=100):
    """Hitung RSI manual (Wilder's Smoothing)"""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count + 50)
    if rates is None or len(rates) == 0:
        return None, None
    df = pd.DataFrame(rates)
    df['close'] = df['close'].astype(float)
    delta = df['close'].diff()
    gain = delta.where(delta > 0, 0.0)
    loss = (-delta.where(delta < 0, 0.0))
    avg_gain = gain.ewm(alpha=1/period, min_periods=period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1/period, min_periods=period, adjust=False).mean()
    rs = avg_gain / avg_loss
    rsi = 100 - (100 / (1 + rs))
    return rsi.iloc[-1], rsi.tail(5).tolist()

def is_rsi_flat(rsi_values, near_level, tolerance=2, flat_threshold=0.5):
    if len(rsi_values) < 3:
        return False
    current = rsi_values[-1]
    if not (near_level - tolerance <= current <= near_level + tolerance):
        return False
    changes = [abs(rsi_values[i] - rsi_values[i-1]) for i in range(1, len(rsi_values))]
    avg_change = sum(changes) / len(changes)
    return avg_change <= flat_threshold

def get_point_value():
    info = mt5.symbol_info(SYMBOL)
    return info.point if info else 0.01

def get_current_price(order_type):
    tick = mt5.symbol_info_tick(SYMBOL)
    if tick is None:
        return None
    return tick.ask if order_type == mt5.ORDER_TYPE_BUY else tick.bid

# def calculate_sl_tp(entry, order_type, points=15):
#     point = get_point_value()
#     dist = points * point
#     if order_type == mt5.ORDER_TYPE_BUY:
#         sl = entry - dist
#         tp = entry + (1000 * point)  # Safety TP jauh, real TP by RSI
#     else:
#         sl = entry + dist
#         tp = entry - (1000 * point)
#     return sl, tp

def calculate_sl_tp(entry, order_type, points=150):
    """
    Menghitung SL dan TP berbasis POINTS dengan buffer keamanan ketat.
    Mencegah error 10016 akibat spread melebar atau batas stops level broker.
    """
    symbol_info = mt5.symbol_info(SYMBOL)
    if symbol_info is None or entry is None:
        print(f"❌ Gagal mendapatkan info simbol atau harga entry tidak valid")
        return None, None
        
    point = symbol_info.point
    print(f"   [DEBUG CALC] point: {point}")
    digits = symbol_info.digits
    print(f"   [DEBUG CALC] digits: {digits}")
    stops_level = symbol_info.trade_stops_level  # Contoh: 2976
    print(f"   [DEBUG CALC] stops_level: {stops_level}")
    
    # ==========================================
    # LOGIKA KEAMANAN BERBASIS POINTS (Sesuai Analisis Anda)
    # ==========================================
    # Jika broker menetapkan batas (misal 2976), kita WAJIB melebihinya dengan buffer +500 points.
    # 2976 + 500 = 3476 points. 
    # 3476 points × 0.01 = $34.76 (Jarak aman yang tidak akan ditolak broker)
    if stops_level > 0:
        safe_min_points = stops_level + 500 
        print(f"   [DEBUG CALC] safe_min_points: {safe_min_points}")
    else:
        # Fallback jika broker tidak set stops_level (jarang terjadi di crypto)
        safe_min_points = 1500 
        print(f"   [DEBUG CALC] safe_min_points: {safe_min_points}")

    # Gunakan nilai points yang LEBIH BESAR: antara permintaan user atau batas aman broker
    final_points = max(points, safe_min_points)
    
    # Hitung jarak dalam harga
    dist = final_points * point * 3
    
    print(f"   [DEBUG] Stops Level Broker: {stops_level} points | final_points Dipakai: {final_points} | Jarak(distance): ${dist:.2f}")

    # Hitung Harga SL dan TP (Risk:Reward 2:1.5)
    if order_type == mt5.ORDER_TYPE_BUY:
        sl = entry - (dist*3)
        tp = entry + (dist * 0.7)  
    else: # SELL
        sl = entry + (dist*3)
        tp = entry - (dist * 0.7)
        
    # Normalisasi ketat ke desimal broker (Wajib untuk menghindari 10016)
    sl = round(sl, digits)
    tp = round(tp, digits)
    
    print(f"   [DEBUG CALC] Entry: {entry} | SL: {sl} | TP: {tp}")
    
    return sl, tp

def get_open_positions():
    positions = mt5.positions_get(symbol=SYMBOL)
    return list(positions) if positions else []

def has_open_position(position_type=None):
    positions = get_open_positions()
    if position_type is None:
        return len(positions) > 0
    return any(p.type == position_type for p in positions)

def get_open_trades_count():
    """Hitung berapa banyak posisi yang sedang terbuka oleh bot ini."""
    positions = mt5.positions_get(symbol=SYMBOL)
    if positions is None:
        return 0
    count = 0
    for pos in positions:
        if pos.magic == MAGIC_NUMBER:
            count += 1
    return count

def send_order(order_type, current_lot, sl, tp, comment=""):
    price = get_current_price(order_type)
    if price is None or sl is None or tp is None:
        print("❌ Harga, SL, atau TP tidak valid (None). Order dibatalkan.")
        return False
        
    margin = mt5.order_calc_margin(order_type, SYMBOL, current_lot, price)
    acc = get_account_info()
    if margin and acc and margin > acc.margin_free:
        print(f"❌ Margin tidak cukup (butuh {margin:.2f})")
        return False

    # ✅ SMART FALLBACK: Coba 3 mode filling secara berurutan
    filling_modes_to_try = [
        mt5.ORDER_FILLING_FOK,
        mt5.ORDER_FILLING_RETURN,
        mt5.ORDER_FILLING_IOC
    ]

    for fill_mode in filling_modes_to_try:
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": SYMBOL,
            "volume": current_lot,
            "type": order_type,
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 50,
            "magic": MAGIC_NUMBER,
            "comment": comment,
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": fill_mode,
        }
        
        result = mt5.order_send(request)
        
        # 1. Jika BERHASIL, hentikan loop dan return True
        if result.retcode == mt5.TRADE_RETCODE_DONE:
            print(f"✅ Order {comment} SUKSES! | Price: {price} | Lot: {current_lot} | SL: {sl} | TP: {tp}")
            return True
            
        # 2. Jika gagal karena Invalid Stops (10016), aktifkan metode Fallback
        if result.retcode == 10016:
            print(f"   ⚠️ Broker menolak SL/TP di order awal (10016). Mencoba metode Fallback (Open then Modify)...")
            return send_order_fallback(order_type, current_lot, sl, tp, comment, price)
            
        # 3. Jika gagal karena Unsupported filling mode (10030), lanjut coba mode berikutnya
        if result.retcode == 10030:
            continue 
            
        # 4. Jika gagal karena alasan LAIN, hentikan dan laporkan
        print(f"❌ Order gagal: {result.retcode} - {result.comment} (Filling Mode: {fill_mode})")
        return False
        
    print(f"❌ Order gagal total: Broker tidak mendukung FOK, RETURN, maupun IOC.")
    return False


def send_order_fallback(order_type, current_lot, sl, tp, comment, entry_price):
    """
    Fallback Method: Buka posisi TANPA SL/TP dulu, lalu modify dengan buffer waktu yang cukup.
    """
    filling_modes_to_try = [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_RETURN, mt5.ORDER_FILLING_IOC]
    
    for fill_mode in filling_modes_to_try:
        # Langkah 1: Buka posisi TANPA SL/TP
        request_open = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": SYMBOL,
            "volume": current_lot,
            "type": order_type,
            "price": entry_price,
            "deviation": 50,
            "magic": MAGIC_NUMBER,
            "comment": f"{comment}_NO_SLTP",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": fill_mode,
        }
        
        result_open = mt5.order_send(request_open)
        
        if result_open.retcode == mt5.TRADE_RETCODE_DONE:
            ticket = result_open.order
            print(f"   ✅ Posisi terbuka (Tanpa SL/TP). Ticket: {ticket}. Menunggu server broker stabil...")
            
            # ⚠️ PENTING: Tunggu 2.0 detik agar server broker benar-benar merekam posisi 
            # dan spread kembali normal sebelum dimodifikasi
            time.sleep(2.0)
            
            # Langkah 2: Modify posisi untuk menambahkan SL/TP
            request_modify = {
                "action": mt5.TRADE_ACTION_SLTP,
                "symbol": SYMBOL,
                "sl": sl,
                "tp": tp,
                "position": ticket,
            }
            
            # Retry modify hingga 3 kali jika server sedang sibuk atau validasi harga ketat
            for retry in range(3):
                result_modify = mt5.order_send(request_modify)
                if result_modify.retcode == mt5.TRADE_RETCODE_DONE:
                    print(f"✅ Order {comment} SUKSES (Fallback)! | Ticket: {ticket} | Price: {entry_price} | Lot: {current_lot} | SL: {sl} | TP: {tp}")
                    return True
                else:
                    print(f"   ⚠️ Gagal menambahkan SL/TP (Attempt {retry+1}/3): {result_modify.retcode} - {result_modify.comment}")
                    time.sleep(1.5) # Tunggu lebih lama sebelum retry
            
            print(f"   🚨 PERINGATAN KRITIS: Posisi tetap terbuka TANPA SL/TP (Ticket: {ticket}). Harap monitor manual atau tutup manual di MT5!")
            return True # Return True agar bot tahu posisi sudah terbuka dan tidak membuka posisi ganda
            
        elif result_open.retcode == 10030:
            continue # Coba filling mode berikutnya
        else:
            print(f"❌ Fallback Gagal Buka Posisi: {result_open.retcode} - {result_open.comment}")
            return False
            
    return False

def close_position(position):
    tick = mt5.symbol_info_tick(SYMBOL)
    if tick is None:
        return False
    price = tick.bid if position.type == mt5.ORDER_TYPE_BUY else tick.ask
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": SYMBOL,
        "volume": position.volume,
        "type": mt5.ORDER_TYPE_SELL if position.type == mt5.ORDER_TYPE_BUY else mt5.ORDER_TYPE_BUY,
        "position": position.ticket,
        "price": price,
        "deviation": 50,
        "magic": MAGIC_NUMBER,
        "comment": "Close by RSI M15",
        "type_time": mt5.ORDER_TIME_GTC,
        # "type_filling": mt5.ORDER_FILLING_IOC,
        "type_filling": mt5.ORDER_FILLING_FOK,  # ← UBAH INI MENJADI FOK
    }
    result = mt5.order_send(request)
    if result.retcode == mt5.TRADE_RETCODE_DONE:
        print(f"✅ Closed | Profit: {position.profit:.2f}")
        return True
    print(f"❌ Gagal close: {result.retcode}")
    return False

# ============================================================
# MULTI-TIMEFRAME LOGIC
# ============================================================

def get_htf_bias():
    """
    Higher Timeframe Bias dari H4 + H1 + M30
    < 45 = BULLISH BIAS (cari buy/reversal up)
    > 55 = BEARISH BIAS (cari sell/reversal down)
    """
    values = []
    for tf_name in HTF_TIMEFRAMES:
        rsi, _ = get_rsi(SYMBOL, TIMEFRAMES[tf_name], RSI_PERIOD)
        if rsi is not None:
            values.append(rsi)
    if not values:
        return 'NEUTRAL'
    avg = sum(values) / len(values)
    if avg < 35:
        return 'BUY'
    elif avg > 65:
        return 'SELL'
    return 'NEUTRAL'

def get_all_tf_data():
    """Ambil RSI dari semua 6 timeframe"""
    data = {}
    for name, tf in TIMEFRAMES.items():
        rsi, hist = get_rsi(SYMBOL, tf, RSI_PERIOD)
        data[name] = {'rsi': rsi, 'history': hist}
    return data

def check_signals():
    """
    Entry di M15, konfirmasi M5, filter H4+H1+M30
    """
    data = get_all_tf_data()
    
    # Cek data lengkap
    if any(d['rsi'] is None for d in data.values()):
        return None, None
    
    # HTF Bias
    htf_bias = get_htf_bias()
    
    # Entry data (M15)
    m15_rsi = data['M15']['rsi']
    m15_hist = data['M15']['history']
    
    # Confirmation data (M5)
    m5_rsi = data['M5']['rsi']
    h1_rsi = data['H1']['rsi']
    
    # Display semua TF
    print(f"[{datetime.now().strftime('%H:%M:%S')}] "
          f"H4:{data['H4']['rsi']:.1f} H1:{data['H1']['rsi']:.1f} M30:{data['M30']['rsi']:.1f} | "
          f"M15:{m15_rsi:.1f} M5:{m5_rsi:.1f} M1:{data['M1']['rsi']:.1f} | "
          f"Bias:{htf_bias}")

     # ==========================================
    # LOGIKA SCALING IN (TAMBAH TRADE BARU)
    # ==========================================
    # Tambah SELL jika RSI H1 > 70 (Sangat Overbought di H1)
    allow_sell_scaling = h1_rsi > 70
    # Tambah BUY jika RSI H1 < 30 (Sangat Oversold di H1)
    allow_buy_scaling = h1_rsi < 30
    
    # =================== SINYAL BUY ===================
    
    # 1. BUY OVERSOLD: M15 RSI < 40, M5 konfirmasi < 45, HTF tidak SELL
    if m15_rsi < RSI_OVERSOLD and m5_rsi < 35:
        # Izinkan jika belum ada posisi BUY, ATAU jika H1 RSI < 30 (scaling in)
        if htf_bias != 'SELL' and (allow_buy_scaling or not has_open_position(mt5.ORDER_TYPE_BUY)):
            return mt5.ORDER_TYPE_BUY, "BUY_OVERSOLD"
    
    # 2. BUY FLAT 30: M15 flat di 30, M5 konfirmasi < 45, HTF tidak SELL
    if is_rsi_flat(m15_hist, RSI_FLAT_30_ZONE, RSI_FLAT_TOLERANCE, RSI_FLAT_THRESHOLD):
         if m5_rsi < 35 and htf_bias != 'SELL' and (allow_buy_scaling or not has_open_position(mt5.ORDER_TYPE_BUY)):
            return mt5.ORDER_TYPE_BUY, "BUY_FLAT_30"
    
    # =================== SINYAL SELL ===================
    
    # 3. SELL OVERBOUGHT: M15 RSI > 60, M5 konfirmasi > 55, HTF tidak BUY
    if m15_rsi > RSI_OVERBOUGHT and m5_rsi > 65:
        # Izinkan jika belum ada posisi SELL, ATAU jika H1 RSI > 70 (scaling in)
        if htf_bias != 'BUY' and (allow_sell_scaling or not has_open_position(mt5.ORDER_TYPE_SELL)):
            return mt5.ORDER_TYPE_SELL, "SELL_OVERBOUGHT"
    
    
    # 4. SELL FLAT 70: M15 flat di 70, M5 konfirmasi > 55, HTF tidak BUY
    if is_rsi_flat(m15_hist, RSI_FLAT_70_ZONE, RSI_FLAT_TOLERANCE, RSI_FLAT_THRESHOLD):
        if m5_rsi > 65 and htf_bias != 'BUY' and (allow_sell_scaling or not has_open_position(mt5.ORDER_TYPE_SELL)):
            return mt5.ORDER_TYPE_SELL, "SELL_FLAT_70"
    
    return None, None

def check_scaling_signal(h1_rsi):
    """
    Logika untuk membuka trade tambahan (Trade ke-2, ke-3, dst) 
    berdasarkan RSI H1 yang ekstrem.
    """
    if h1_rsi is None:
        return None, None

    # Tambah SELL jika H1 Overbought parah (> 70)
    if h1_rsi > 70:
        return mt5.ORDER_TYPE_SELL, f"ADD_SELL_H1_{h1_rsi:.1f}"

    # Tambah BUY jika H1 Oversold parah (< 30)
    if h1_rsi < 30:
        return mt5.ORDER_TYPE_BUY, f"ADD_BUY_H1_{h1_rsi:.1f}"

    return None, None

def manage_open_positions():
    """TP dinamis berdasarkan RSI M15"""
    positions = get_open_positions()
    if not positions:
        return
    
    m15_rsi, _ = get_rsi(SYMBOL, ENTRY_TIMEFRAME, RSI_PERIOD)
    if m15_rsi is None:
        return
    
    for pos in positions:
        if pos.magic != MAGIC_NUMBER:
            continue
        
        # BUY
        if pos.type == mt5.ORDER_TYPE_BUY:
            if "OVERSOLD" in pos.comment and m15_rsi >= TP_RSI_BUY_OVERSOLD:
                print(f"📊 M15 RSI {m15_rsi:.1f} >= {TP_RSI_BUY_OVERSOLD} → TUTUP BUY")
                close_position(pos)
            elif "FLAT_30" in pos.comment and m15_rsi >= TP_RSI_BUY_FLAT_30:
                print(f"📊 M15 RSI {m15_rsi:.1f} >= {TP_RSI_BUY_FLAT_30} → TUTUP BUY_FLAT_30")
                close_position(pos)
        
        # SELL
        elif pos.type == mt5.ORDER_TYPE_SELL:
            if "OVERBOUGHT" in pos.comment and m15_rsi <= TP_RSI_SELL_OVERBOUGHT:
                print(f"📊 M15 RSI {m15_rsi:.1f} <= {TP_RSI_SELL_OVERBOUGHT} → TUTUP SELL")
                close_position(pos)
            elif "FLAT_70" in pos.comment and m15_rsi <= TP_RSI_SELL_FLAT_70:
                print(f"📊 M15 RSI {m15_rsi:.1f} <= {TP_RSI_SELL_FLAT_70} → TUTUP SELL_FLAT_70")
                close_position(pos)

# ============================================================
# MAIN LOOP
# ============================================================

def main():
    print("=" * 70)
    print("🤖 BTCUSD RSI MULTI-TF TRADER | Entry: M15 | Confirm: M5")
    print("=" * 70)

    if not mt5.initialize():
        print("❌ Gagal inisialisasi MT5")
        quit()
        
    # Diagnosa akun dulu
    if not diagnose_account():
        print("\n Bot dihentikan. Perbaiki masalah login terlebih dahulu.")
        mt5.shutdown()
        quit()
    
    if not init_mt5():
        print(" Bot dihentikan karena inisialisasi MT5 gagal.")
        mt5.shutdown()
        quit() # Keluar dari program
    if not mt5.symbol_select(SYMBOL, True):
        print(f"❌ Gagal subscribe {SYMBOL}")
        return
    
    print(f"📈 Simbol: {SYMBOL}")
    print(f"⏱️  Entry: M15 | Konfirmasi: M5 | Filter: H4+H1+M30")
    print("-" * 70)
    
    try:
        while True:
            acc = get_account_info()
            if acc is None:
                time.sleep(5)
                continue
            
            # equity = acc.equity
            # lot = calculate_dynamic_lot(equity)
            # print(f"\n💰 Equity: ${equity:.2f} | Lot: {lot:.2f}")

            # Di dalam loop utama trading Anda:
            current_equity = acc.equity

            # Panggil fungsi dengan menyertakan SYMBOL dan EQUITY
            # current_lot = calculate_dynamic_lot(SYMBOL, current_equity)

             # HITUNG MAKSIMAL TRADE YANG DIIZINKAN
            max_allowed_trades = max(1, int(current_equity // TRADE_BALANCE_STEP))
            current_open_trades = get_open_trades_count()

            print(f"💰 Equity: ${current_equity:.2f} | Max Trade: {max_allowed_trades} | Terbuka: {current_open_trades} | Lot/Trade: {LOT_PER_TRADE}")
                        
            # 1. Kelola posisi terbuka (TP by RSI M15)
            manage_open_positions()
            
            # 2. Cek sinyal baru (HANYA jika slot trade masih tersedia)
            if current_open_trades < max_allowed_trades:
                # signal, signal_name = check_signals()
                
                # Ambil data RSI H1 untuk logika scaling
                data = get_all_tf_data()
                h1_rsi = data['H1']['rsi']
                
                signal = None
                signal_name = ""

                # ==========================================
                # LOGIKA BERTINGKAT (TIERED LOGIC)
                # ==========================================
                if current_open_trades == 0:
                    # Trade PERTAMA: Gunakan logika M15/M5 standar (Oversold/Overbought)
                    signal, signal_name = check_signals()
                else:
                    # Trade KE-2, KE-3, dst: Gunakan logika RSI H1 ekstrem
                    signal, signal_name = check_scaling_signal(h1_rsi)

                # ==========================================
                # EKSEKUSI ORDER
                # ==========================================
                if signal is not None:
                    entry_price = get_current_price(signal)
                    sl, tp = calculate_sl_tp(entry_price, signal, SL_POINTS)
                    
                    # Safety check: risk 30% modal
                    tick_val = mt5.symbol_info(SYMBOL).trade_tick_value or 1
                    point = get_point_value()
                    
                    # Hitung risiko untuk 1 trade (0.01 lot)
                    risk_usd = LOT_PER_TRADE * (sl_points := (abs(entry_price - sl) / point)) * (tick_val / point) * point
                    risk_pct = (risk_usd / current_equity) * 100 if current_equity > 0 else 0
                    
                    print(f"🎯 SINYAL: {signal_name} | Est.Risk per trade: {risk_pct:.1f}%")
                    
                    if risk_pct <= MAX_RISK_PERCENT:
                        # KIRIM ORDER DENGAN LOT TETAP 0.01
                        if send_order(signal, LOT_PER_TRADE, sl, tp, signal_name):
                            print(f"   📋 Entry: {entry_price} | SL: {sl} | TP: {tp}")
                    else:
                        print(f"⚠️  Risk {risk_pct:.1f}% > 30%, trade dilewatkan")
            else:
                print(f"⏳ Slot trade penuh ({current_open_trades}/{max_allowed_trades}). Menunggu posisi ditutup...")

            print(f" [{datetime.now().strftime('%H:%M:%S')}] Scanning market...")
            time.sleep(15)
            
            
    except KeyboardInterrupt:
        print("\n🛑 Trading dihentikan oleh user")
    finally:
        mt5.shutdown()
        print("🔌 Koneksi MT5 ditutup")

if __name__ == "__main__":
    main()
