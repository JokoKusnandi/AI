import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ============================================================
# KONFIGURASI
# ============================================================
SYMBOL = "BTCUSD.vx"           # Ganti jika broker pakai simbol lain
RSI_PERIOD = 14             # Periode RSI standar
MAGIC_NUMBER = 123456       # ID unik EA ini

# Timeframes untuk analisis (sesuai permintaan)
TIMEFRAMES = {
    'H4': mt5.TIMEFRAME_H4,
    'H1': mt5.TIMEFRAME_H1,
    'M30': mt5.TIMEFRAME_M30,
    'M15': mt5.TIMEFRAME_M15,
    'M5': mt5.TIMEFRAME_M5,
    'M1': mt5.TIMEFRAME_M1,
}

# Timeframe utama untuk entry (M5 direkomendasikan untuk BTC)
ENTRY_TIMEFRAME = mt5.TIMEFRAME_M5
FILTER_TIMEFRAME = mt5.TIMEFRAME_H1  # Filter trend dari H1

# Parameter RSI
RSI_OVERSOLD = 35
RSI_OVERBOUGHT = 65
RSI_FLAT_30_ZONE = 30       # Zona flat 30 (28-32)
RSI_FLAT_70_ZONE = 70       # Zona flat 70 (68-72)
RSI_FLAT_TOLERANCE = 2      # Toleransi zona (±2)
RSI_FLAT_THRESHOLD = 0.5    # Dianggap flat jika perubahan < 0.5

# TP dinamis RSI target
TP_RSI_BUY_OVERSOLD = 60
TP_RSI_BUY_FLAT_30 = 50 # buy flat 30 -> TP saat RSI 50
TP_RSI_SELL_OVERBOUGHT = 40
TP_RSI_SELL_FLAT_70 = 50 # sell flat 70 -> TP saat RSI 50

# SL/TP
SL_POINTS = 150              # SL = entry ± 15 points (sesuai permintaan detail)
MAX_RISK_PERCENT = 30       # Batasan 30% modal (sebagai safety check)

# ============================================================
# FUNGSI UTILITY
# ============================================================

def init_mt5():
    """Inisialisasi koneksi ke MT5"""
    if not mt5.initialize():
        print("❌ Gagal inisialisasi MT5")
        mt5.shutdown()
        return False
    print("✅ Terhubung ke MT5")
    return True

def get_account_info():
    """Ambil info akun"""
    account = mt5.account_info()
    if account is None:
        print("❌ Gagal ambil info akun")
        return None
    return account

def calculate_dynamic_lot(equity):
    """
    Dynamic lot sizing:
    - Modal <= 100: 0.01 lot
    - 100 < Modal <= 200: 0.02 lot
    - dst (kelipatan 100)
    """
    if equity <= 0:
        return 0.01
    
    lot = (int(equity) // 100) * 0.01
    if lot < 0.01:
        lot = 0.01
    
    # Batasi ke lot maksimal broker (biasanya 100 atau 200)
    # Cek volume maksimal simbol
    symbol_info = mt5.symbol_info(SYMBOL)
    if symbol_info:
        max_lot = symbol_info.volume_max
        if lot > max_lot:
            lot = max_lot
    
    # Round ke step volume broker (biasanya 0.01)
    volume_step = symbol_info.volume_step if symbol_info else 0.01
    lot = round(lot / volume_step) * volume_step
    
    return round(lot, 2)

def get_rsi(symbol, timeframe, period=14, count=100):
    """Hitung RSI manual menggunakan Wilder's Smoothing"""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count + 50)
    if rates is None or len(rates) == 0:
        return None, None
    
    df = pd.DataFrame(rates)
    df['close'] = df['close'].astype(float)
    
    # Hitung perubahan harga
    delta = df['close'].diff()
    
    # Pisah gain dan loss
    gain = delta.where(delta > 0, 0.0)
    loss = (-delta.where(delta < 0, 0.0))
    
    # Rata-rata eksponensial (Wilder's)
    avg_gain = gain.ewm(alpha=1/period, min_periods=period, adjust=False).mean()
    avg_loss = loss.ewm(alpha=1/period, min_periods=period, adjust=False).mean()
    
    # RS dan RSI
    rs = avg_gain / avg_loss
    rsi = 100 - (100 / (1 + rs))
    
    return rsi.iloc[-1], rsi.tail(5).tolist()  # Return RSI terakhir + 5 nilai terakhir

def is_rsi_flat(rsi_values, near_level, tolerance=2, flat_threshold=0.5):
    """
    Cek apakah RSI mendatar di sekitar level tertentu
    - near_level: level target (30 atau 70)
    - tolerance: toleransi zona (±2)
    - flat_threshold: dianggap flat jika perubahan antar candle < 0.5
    """
    if len(rsi_values) < 3:
        return False
    
    # Cek apakah RSI berada di zona target
    current = rsi_values[-1]
    if not (near_level - tolerance <= current <= near_level + tolerance):
        return False
    
    # Cek apakah mendatar (perubahan kecil)
    changes = [abs(rsi_values[i] - rsi_values[i-1]) for i in range(1, len(rsi_values))]
    avg_change = sum(changes) / len(changes)
    
    return avg_change <= flat_threshold

def get_point_value():
    """Ambil nilai 1 point untuk simbol"""
    symbol_info = mt5.symbol_info(SYMBOL)
    if symbol_info is None:
        return 0.01  # Default
    return symbol_info.point

def get_current_price(order_type):
    """Ambil harga ask/bid saat ini"""
    tick = mt5.symbol_info_tick(SYMBOL)
    if tick is None:
        return None
    return tick.ask if order_type == mt5.ORDER_TYPE_BUY else tick.bid

def calculate_sl_tp(entry, order_type, points=150):
    """
    Menghitung SL dan TP dengan proteksi ganda:
    1. Mematuhi Stops Level broker.
    2. Memaksa jarak minimal dalam DOLLAR (Safety Net Crypto).
    3. Pembulatan desimal yang presisi.
    """
    symbol_info = mt5.symbol_info(SYMBOL)
    if symbol_info is None:
        print(f"❌ Gagal mendapatkan info simbol {SYMBOL}")
        return None, None
        
    point = symbol_info.point
    digits = symbol_info.digits
    
    # 1. Hitung jarak berdasarkan points
    dist = points * point
    
    # 2. SAFETY NET KHUSUS CRYPTO (PENTING!)
    # Paksa jarak SL minimal $20.00 dari harga entry, apapun nilai 'points'-nya.
    # Ini mencegah error 10016 karena SL terlalu sempit untuk volatilitas BTC.
    min_price_distance = 20.0 
    
    if dist < min_price_distance:
        dist = min_price_distance
        print(f"⚠️ Safety Net Aktif: Jarak SL disesuaikan ke minimal ${min_price_distance}")

    # 3. Cek Stops Level resmi dari broker
    min_stops_level = symbol_info.trade_stops_level * point
    if min_stops_level > dist:
        dist = min_stops_level + (point * 10) # Tambah buffer kecil
        
    # 4. Hitung Harga SL dan TP (Risk:Reward 1:2)
    if order_type == mt5.ORDER_TYPE_BUY:
        sl = entry - dist
        tp = entry + (dist * 2.0)  
    else: # SELL
        sl = entry + dist
        tp = entry - (dist * 2.0)
        
    # 5. WAJIB: Bulatkan harga ke jumlah desimal yang diizinkan broker
    sl = round(sl, digits)
    tp = round(tp, digits)
    
    return sl, tp

def get_open_positions():
    """Ambil semua posisi terbuka untuk simbol ini"""
    positions = mt5.positions_get(symbol=SYMBOL)
    if positions is None:
        return []
    return list(positions)

def has_open_position(position_type=None):
    """Cek apakah sudah ada posisi terbuka (buy/sell/any)"""
    positions = get_open_positions()
    if position_type is None:
        return len(positions) > 0
    return any(pos.type == position_type for pos in positions)

def send_order(order_type, lot, sl, tp, comment=""):
    """Kirim order ke MT5"""
    price = get_current_price(order_type)
    if price is None:
        print("❌ Gagal ambil harga")
        return False
    
    # Cek margin
    margin_required = mt5.order_calc_margin(order_type, SYMBOL, lot, price)
    account = get_account_info()
    if margin_required and account:
        if margin_required > account.margin_free:
            print(f"❌ Margin tidak cukup. Butuh: {margin_required}, Free: {account.margin_free}")
            return False
    
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": SYMBOL,
        "volume": lot,
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": 50,  # Slippage 50 points
        "magic": MAGIC_NUMBER,
        "comment": comment,
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"❌ Order gagal: {result.retcode} - {result.comment}")
        return False
    
    print(f"✅ Order {comment} sukses! Price: {price}, Lot: {lot}, SL: {sl}")
    return True

def close_position(position):
    """Tutup posisi yang terbuka"""
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
        "comment": "Close by RSI",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    
    result = mt5.order_send(request)
    if result.retcode == mt5.TRADE_RETCODE_DONE:
        print(f"✅ Posisi ditutup. Profit: {position.profit}")
        return True
    else:
        print(f"❌ Gagal tutup posisi: {result.retcode}")
        return False

# ============================================================
# LOGIKA TRADING
# ============================================================

def check_signals():
    """Cek sinyal trading berdasarkan RSI multi-timeframe"""
    
    # Ambil RSI dari timeframe entry (M5) dan filter (H1)
    rsi_entry_current, rsi_entry_history = get_rsi(SYMBOL, ENTRY_TIMEFRAME, RSI_PERIOD)
    rsi_filter_current, _ = get_rsi(SYMBOL, FILTER_TIMEFRAME, RSI_PERIOD)
    
    if rsi_entry_current is None or rsi_filter_current is None:
        return None, None
    
    print(f"[{datetime.now().strftime('%H:%M:%S')}] "
          f"RSI Entry(M5): {rsi_entry_current:.1f} | "
          f"RSI Filter(H1): {rsi_filter_current:.1f}")
    
    # --- SINYAL BUY OVERSOLD ---
    # Buy jika RSI < 35 (timeframe entry), filter H1 tidak overbought
    if rsi_entry_current < RSI_OVERSOLD and rsi_filter_current < 50:
        if not has_open_position(mt5.ORDER_TYPE_BUY):
            return mt5.ORDER_TYPE_BUY, "BUY_OVERSOLD"
    
    # --- SINYAL BUY FLAT DEKAT 30 ---
    # Jika RSI mendatar dekat 30 → Sell (counter-trend, sesuai permintaan)
    if is_rsi_flat(rsi_entry_history, RSI_FLAT_30_ZONE, RSI_FLAT_TOLERANCE, RSI_FLAT_THRESHOLD):
        if not has_open_position(mt5.ORDER_TYPE_BUY):
            return mt5.ORDER_TYPE_BUY, "BUY_FLAT_30"
    
    # --- SINYAL SELL OVERBOUGHT ---
    # Sell jika RSI > 65
    if rsi_entry_current > RSI_OVERBOUGHT and rsi_filter_current > 50:
        if not has_open_position(mt5.ORDER_TYPE_SELL):
            return mt5.ORDER_TYPE_SELL, "SELL_OVERBOUGHT"
    
    # --- SINYAL SELL FLAT DEKAT 70 ---
    # Jika RSI mendatar dekat 70 → Sell
    if is_rsi_flat(rsi_entry_history, RSI_FLAT_70_ZONE, RSI_FLAT_TOLERANCE, RSI_FLAT_THRESHOLD):
        if not has_open_position(mt5.ORDER_TYPE_SELL):
            return mt5.ORDER_TYPE_SELL, "SELL_FLAT_70"
    
    return None, None

def manage_open_positions():
    """
    Monitor posisi terbuka dan tutup berdasarkan target RSI
    """
    positions = get_open_positions()
    if not positions:
        return
    
    # Ambil RSI terkini
    rsi_current, _ = get_rsi(SYMBOL, ENTRY_TIMEFRAME, RSI_PERIOD)
    if rsi_current is None:
        return
    
    for pos in positions:
        # Cek magic number (hanya kelola posisi dari EA ini)
        if pos.magic != MAGIC_NUMBER:
            continue
        
        comment = pos.comment
        
        # BUY: TP ketika RSI >= 60
        if pos.type == mt5.ORDER_TYPE_BUY:
            if rsi_current >= TP_RSI_BUY_OVERSOLD and "BUY" in comment:
                print(f"📊 RSI {rsi_current:.1f} >= {TP_RSI_BUY_OVERSOLD}, tutup BUY")
                close_position(pos)
                continue
        # buy Flat 30: TP ketika RSI >= 50 (konfirmasi bounce)
        elif pos.type == mt5.ORDER_TYPE_BUY and "FLAT_30" in comment:
            if rsi_current >= TP_RSI_BUY_FLAT_30:
                print(f"📊 RSI {rsi_current:.1f} >= {TP_RSI_BUY_FLAT_30}, tutup BUY_FLAT_30")
                close_position(pos)
                continue
        
        # SELL: TP berbeda berdasarkan jenis sinyal
        elif pos.type == mt5.ORDER_TYPE_SELL and "OVERBOUGHT" in comment:
            # Sell Overbought: TP ketika RSI <= 40
            if rsi_current <= TP_RSI_SELL_OVERBOUGHT:
                print(f"📊 RSI {rsi_current:.1f} <= {TP_RSI_SELL_OVERBOUGHT}, tutup SELL_OVERBOUGHT")
                close_position(pos)
                continue
            
            # Sell Flat 70: TP ketika RSI <= 50
        elif pos.type == mt5.ORDER_TYPE_SELL and "FLAT_70" in comment:
            if rsi_current <= TP_RSI_SELL_FLAT_70:
                print(f"📊 RSI {rsi_current:.1f} <= {TP_RSI_SELL_FLAT_70}, tutup SELL_FLAT_70")
                close_position(pos)
                continue
            
            

def main():
    print("=" * 60)
    print("🤖 BTCUSD RSI MULTI-TIMEFRAME TRADER")
    print("=" * 60)
    
    if not init_mt5():
        return
    
    # Subscribe simbol
    if not mt5.symbol_select(SYMBOL, True):
        print(f"❌ Gagal subscribe {SYMBOL}")
        return
    
    print(f"📈 Simbol: {SYMBOL}")
    print(f"⏱️  Entry TF: M5 | Filter TF: H1")
    print("-" * 60)
    
    try:
        while True:
            # 1. Cek info akun dan hitung lot
            account = get_account_info()
            if account is None:
                time.sleep(5)
                continue
            
            equity = account.equity
            lot = calculate_dynamic_lot(equity)
            
            print(f"\n💰 Equity: ${equity:.2f} | Lot: {lot:.2f}")
            
            # 2. Kelola posisi terbuka (TP dinamis berbasis RSI)
            manage_open_positions()
            
            # 3. Cek sinyal baru (hanya jika tidak ada posisi terbuka)
            if not has_open_position():
                signal, signal_name = check_signals()
                
                if signal is not None:
                    entry_price = get_current_price(signal)
                    sl, tp = calculate_sl_tp(entry_price, signal, SL_POINTS)
                    
                    # Validasi risk 30% modal (safety check)
                    # Hitung risk monetary dari SL 15 points
                    tick_value = mt5.symbol_info(SYMBOL).trade_tick_value
                    point = get_point_value()
                    risk_monetary = lot * (SL_POINTS * point / point) * tick_value
                    risk_percent = (risk_monetary / equity) * 100
                    
                    print(f"🎯 SINYAL: {signal_name} | Risk: {risk_percent:.1f}% modal")
                    
                    if risk_percent <= MAX_RISK_PERCENT:
                        success = send_order(signal, lot, sl, tp, signal_name)
                        if success:
                            print(f"   📋 Entry: {entry_price}, SL: {sl}, TP: [RSI Target]")
                    else:
                        print(f"⚠️  Risk {risk_percent:.1f}% melebihi batas 30%, trade dilewatkan")
            
            # Tunggu 1 menit sebelum cek lagi
            time.sleep(60)
            
    except KeyboardInterrupt:
        print("\n🛑 Trading dihentikan oleh user")
    finally:
        mt5.shutdown()
        print("🔌 Koneksi MT5 ditutup")

if __name__ == "__main__":
    main()
