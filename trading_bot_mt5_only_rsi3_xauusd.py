import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ============================================================
# KONFIGURASI
# ============================================================
SYMBOL = "XAUUSD.vx"           # Simbol XAUUSD (Gold)
RSI_PERIOD = 14
MAGIC_NUMBER = 654321

# Parameter SL & TP (dalam POINTS)
# PERHATIAN: 1 point di XAUUSD biasanya = 0.01 atau 0.1 tergantung broker.
# SL 15 points = 0.15 atau 1.5 pips. TP 1 point = 0.01 atau 0.1 pips.
# Jika broker menolak (Error 10016), itu karena Stops Level broker lebih besar dari nilai ini.
SL_POINTS = 15
TP_POINTS = 1
MAX_RISK_PERCENT = 30

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

# ============================================================
# KONFIGURASI MULTI-TRADE
# ============================================================
TRADE_BALANCE_STEP = 10000.0  
LOT_PER_TRADE = 0.01          # Setiap trade selalu 0.01 lot

# ============================================================
# FUNGSI UTILITY
# ============================================================

def diagnose_account():
    """Diagnosa detail status akun dan login."""
    print("\n🔍 DIAGNOSA AKUN MT5:")
    print("-" * 50)
    
    account_info = mt5.account_info()
    if account_info is None:
        print("❌ TIDAK ADA AKUN YANG LOGIN!")
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
        
    terminal_info = mt5.terminal_info()
    if terminal_info:
        print(f"\n✅ Terminal Info:")
        print(f"   Trade API Disabled: {terminal_info.tradeapi_disabled}")
        print(f"   Trade Allowed: {terminal_info.trade_allowed}")
        print(f"   Connected: {terminal_info.connected}")
        
    print("-" * 50 + "\n")
    
    if not account_info.trade_allowed:
        print("❌ MASALAH DITEMUKAN:")
        print("   1. Anda login dengan INVESTOR PASSWORD (read-only)")
        print("   2. Atau akun belum diverifikasi/diaktifkan")
        print("\n✅ SOLUSI: Login ulang di MT5 dengan MAIN PASSWORD.")
        return False
        
    return True

BASE_BALANCE = 0.0

def init_mt5():
    global BASE_BALANCE
    if not mt5.initialize():
        print("❌ Gagal inisialisasi MT5")
        return False
        
    print("✅ Terhubung ke MT5")

    account_info = mt5.account_info()
    if account_info:
        BASE_BALANCE = account_info.balance
        print(f"💰 Base Balance (Acuan Lot) ditetapkan: ${BASE_BALANCE:.2f}")
    
    terminal_info = mt5.terminal_info()
    if terminal_info is None:
        print("⚠️ Tidak bisa membaca info terminal.")
        return False

    if terminal_info.tradeapi_disabled:
        print("❌ AutoTrading MASIH MATI! Aktifkan tombol 'Algo Trading' di toolbar MT5.")
        mt5.shutdown()
        return False
    else:
        print("✅ AutoTrading AKTIF di terminal MT5")
            
    if not terminal_info.trade_allowed:
        print("❌ Trading TIDAK DIIZINKAN untuk akun ini.")
        mt5.shutdown()
        return False
        
    print("🟢 Semua izin trading terpenuhi. Bot siap berjalan!")
    return True


def get_account_info():
    account = mt5.account_info()
    if account is None:
        print("❌ Gagal ambil info akun")
        return None
    return account


def calculate_dynamic_lot(symbol, current_equity):
    """Menghitung lot dinamis berdasarkan KELIPATAN modal awal (BASE_BALANCE)."""
    if current_equity <= 0 or BASE_BALANCE <= 0:
        return 0.01
        
    multiplier = max(1, int(current_equity // BASE_BALANCE))
    lot = multiplier * 0.01

    symbol_info = mt5.symbol_info(symbol)
    if symbol_info:
        min_lot = symbol_info.volume_min or 0.01
        max_lot = symbol_info.volume_max or 100.0
        step = symbol_info.volume_step or 0.01
        
        lot = max(min_lot, min(max_lot, lot))
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


def calculate_sl_tp(entry, order_type, sl_points=5, tp_points=1.5):
    """
    Menghitung SL dan TP berbasis POINTS sesuai permintaan (SL: 15, TP: 1).
    """
    symbol_info = mt5.symbol_info(SYMBOL)
    if symbol_info is None or entry is None:
        print(f"❌ Gagal mendapatkan info simbol atau harga entry tidak valid")
        return None, None
        
    point = symbol_info.point
    digits = symbol_info.digits
    stops_level = symbol_info.trade_stops_level
    
    print(f"   [DEBUG CALC] point: {point} | digits: {digits} | stops_level: {stops_level}")
    
    # Peringatan jika stops level broker lebih besar dari SL/TP yang diminta
    if stops_level > 0:
        if sl_points < stops_level:
            print(f"   ⚠️ PERINGATAN: SL Points ({sl_points}) < Stops Level broker ({stops_level}). Broker mungkin menolak (Error 10016).")
        if tp_points < stops_level:
            print(f"   ⚠️ PERINGATAN: TP Points ({tp_points}) < Stops Level broker ({stops_level}). Broker mungkin menolak (Error 10016).")

    # Hitung jarak dalam harga
    sl_dist = sl_points * point * 100
    tp_dist = tp_points * point * 100

    # Hitung Harga SL dan TP
    if order_type == mt5.ORDER_TYPE_BUY:
        sl = entry - sl_dist
        tp = entry + tp_dist  
    else: # SELL
        sl = entry + sl_dist
        tp = entry - tp_dist
        
    # Normalisasi ketat ke desimal broker (Wajib untuk menghindari error 10016)
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
        
        if result.retcode == mt5.TRADE_RETCODE_DONE:
            print(f"✅ Order {comment} SUKSES! | Price: {price} | Lot: {current_lot} | SL: {sl} | TP: {tp}")
            return True
            
        if result.retcode == 10016:
            print(f"   ⚠️ Broker menolak SL/TP di order awal (10016). Mencoba metode Fallback (Open then Modify)...")
            return send_order_fallback(order_type, current_lot, sl, tp, comment, price)
            
        if result.retcode == 10030:
            continue 
            
        print(f"❌ Order gagal: {result.retcode} - {result.comment} (Filling Mode: {fill_mode})")
        return False
        
    print(f"❌ Order gagal total: Broker tidak mendukung FOK, RETURN, maupun IOC.")
    return False


def send_order_fallback(order_type, current_lot, sl, tp, comment, entry_price):
    """
    Fallback Method: Buka posisi TANPA SL/TP dulu, lalu modify.
    """
    filling_modes_to_try = [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_RETURN, mt5.ORDER_FILLING_IOC]
    
    for fill_mode in filling_modes_to_try:
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
            
            time.sleep(2.0)
            
            request_modify = {
                "action": mt5.TRADE_ACTION_SLTP,
                "symbol": SYMBOL,
                "sl": sl,
                "tp": tp,
                "position": ticket,
            }
            
            for retry in range(3):
                result_modify = mt5.order_send(request_modify)
                if result_modify.retcode == mt5.TRADE_RETCODE_DONE:
                    print(f"✅ Order {comment} SUKSES (Fallback)! | Ticket: {ticket} | Price: {entry_price} | Lot: {current_lot} | SL: {sl} | TP: {tp}")
                    return True
                else:
                    print(f"   ⚠️ Gagal menambahkan SL/TP (Attempt {retry+1}/3): {result_modify.retcode} - {result_modify.comment}")
                    time.sleep(1.5)
            
            print(f"   🚨 PERINGATAN KRITIS: Posisi tetap terbuka TANPA SL/TP (Ticket: {ticket}). Harap monitor manual!")
            return True
            
        elif result_open.retcode == 10030:
            continue
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
        "type_filling": mt5.ORDER_FILLING_FOK,
    }
    result = mt5.order_send(request)
    if result.retcode == mt5.TRADE_RETCODE_DONE:
        print(f"✅ Closed | Profit: {position.profit:.2f}")
        return True
    print(f"❌ Gagal close: {result.retcode}")
    return False


# ============================================================
# MULTI-TIMEFRAME LOGIC (Follow The Trend)
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
    if avg < 45:
        return 'BUY'
    elif avg > 55:
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
    Entry di M15, konfirmasi M5, filter H4+H1+M30 (Follow The Trend)
    """
    data = get_all_tf_data()
    
    if any(d['rsi'] is None for d in data.values()):
        return None, None
    
    htf_bias = get_htf_bias()
    
    m15_rsi = data['M15']['rsi']
    m15_hist = data['M15']['history']
    m5_rsi = data['M5']['rsi']
    h1_rsi = data['H1']['rsi']
    
    print(f"[{datetime.now().strftime('%H:%M:%S')}] "
          f"H4:{data['H4']['rsi']:.1f} H1:{data['H1']['rsi']:.1f} M30:{data['M30']['rsi']:.1f} | "
          f"M15:{m15_rsi:.1f} M5:{m5_rsi:.1f} M1:{data['M1']['rsi']:.1f} | "
          f"Bias:{htf_bias}")

    allow_sell_scaling = h1_rsi > 70
    allow_buy_scaling = h1_rsi < 30
    
    # =================== SINYAL BUY ===================
    if m15_rsi < RSI_OVERSOLD and m5_rsi < 45:
        if htf_bias != 'SELL' and (allow_buy_scaling or not has_open_position(mt5.ORDER_TYPE_BUY)):
            return mt5.ORDER_TYPE_BUY, "BUY_OVERSOLD"
    
    if is_rsi_flat(m15_hist, RSI_FLAT_30_ZONE, RSI_FLAT_TOLERANCE, RSI_FLAT_THRESHOLD):
         if m5_rsi < 45 and htf_bias != 'SELL' and (allow_buy_scaling or not has_open_position(mt5.ORDER_TYPE_BUY)):
            return mt5.ORDER_TYPE_BUY, "BUY_FLAT_30"
    
    # =================== SINYAL SELL ===================
    if m15_rsi > RSI_OVERBOUGHT and m5_rsi > 55:
        if htf_bias != 'BUY' and (allow_sell_scaling or not has_open_position(mt5.ORDER_TYPE_SELL)):
            return mt5.ORDER_TYPE_SELL, "SELL_OVERBOUGHT"
    
    if is_rsi_flat(m15_hist, RSI_FLAT_70_ZONE, RSI_FLAT_TOLERANCE, RSI_FLAT_THRESHOLD):
        if m5_rsi > 55 and htf_bias != 'BUY' and (allow_sell_scaling or not has_open_position(mt5.ORDER_TYPE_SELL)):
            return mt5.ORDER_TYPE_SELL, "SELL_FLAT_70"
    
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
        
        if pos.type == mt5.ORDER_TYPE_BUY:
            if "OVERSOLD" in pos.comment and m15_rsi >= TP_RSI_BUY_OVERSOLD:
                print(f"📊 M15 RSI {m15_rsi:.1f} >= {TP_RSI_BUY_OVERSOLD} → TUTUP BUY")
                close_position(pos)
            elif "FLAT_30" in pos.comment and m15_rsi >= TP_RSI_BUY_FLAT_30:
                print(f"📊 M15 RSI {m15_rsi:.1f} >= {TP_RSI_BUY_FLAT_30} → TUTUP BUY_FLAT_30")
                close_position(pos)
        
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
    print("🤖 XAUUSD.vx RSI MULTI-TF TRADER | SL:15 | TP:1 | Follow Trend")
    print("=" * 70)

    if not mt5.initialize():
        print("❌ Gagal inisialisasi MT5")
        quit()
        
    if not diagnose_account():
        print("\n Bot dihentikan. Perbaiki masalah login terlebih dahulu.")
        mt5.shutdown()
        quit()
    
    if not init_mt5():
        print(" Bot dihentikan karena inisialisasi MT5 gagal.")
        mt5.shutdown()
        quit()
        
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
            
            current_equity = acc.equity
            max_allowed_trades = max(1, int(current_equity // TRADE_BALANCE_STEP))
            current_open_trades = get_open_trades_count()

            print(f"💰 Equity: ${current_equity:.2f} | Max Trade: {max_allowed_trades} | Terbuka: {current_open_trades} | Lot/Trade: {LOT_PER_TRADE}")
                        
            manage_open_positions()
            
            if current_open_trades < max_allowed_trades:
                signal, signal_name = check_signals()
                
                if signal is not None:
                    entry_price = get_current_price(signal)
                    sl, tp = calculate_sl_tp(entry_price, signal, SL_POINTS, TP_POINTS)
                    
                    if sl is not None and tp is not None:
                        symbol_info = mt5.symbol_info(SYMBOL)
                        point = symbol_info.point
                        tick_value = symbol_info.trade_tick_value or 1.0
                        tick_size = symbol_info.trade_tick_size or point
                        
                        value_per_point = (tick_value / tick_size) * point if tick_size > 0 else 1.0
                        distance_in_points = abs(entry_price - sl) / point if point > 0 else 0
                        risk_usd = LOT_PER_TRADE * distance_in_points * value_per_point
                        risk_pct = (risk_usd / current_equity) * 100 if current_equity > 0 else 0
                        
                        print(f"🎯 SINYAL: {signal_name} | Est.Risk per trade: {risk_pct:.2f}%")
                        
                        if risk_pct <= MAX_RISK_PERCENT:
                            if send_order(signal, LOT_PER_TRADE, sl, tp, signal_name):
                                print(f"   📋 Entry: {entry_price} | SL: {sl} | TP: {tp}")
                        else:
                            print(f"⚠️  Risk {risk_pct:.2f}% > {MAX_RISK_PERCENT}%, trade dilewatkan")
            else:
                print(f"⏳ Slot trade penuh ({current_open_trades}/{max_allowed_trades}). Menunggu posisi ditutup...")

            time.sleep(30)
            
    except KeyboardInterrupt:
        print("\n🛑 Trading dihentikan oleh user")
    finally:
        mt5.shutdown()
        print("🔌 Koneksi MT5 ditutup")

if __name__ == "__main__":
    main()