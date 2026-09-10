import os
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '2'  # Senyapkan log TensorFlow

import MetaTrader5 as mt5
import pandas as pd
import ta
from datetime import datetime, date
import time

# ============================================================
# KONFIGURASI UTAMA
# ============================================================
SYMBOLS_TO_TRADE = ["BTCUSD.vx", "XAUUSD.vx"]
TIMEFRAMES = {
    "H4": mt5.TIMEFRAME_H4,
    "H1": mt5.TIMEFRAME_H1,
    "M15": mt5.TIMEFRAME_M15,
    "M5": mt5.TIMEFRAME_M5
}

# --- RISK MANAGEMENT ---
BASE_LOT = 0.01              # Lot dasar (akan dikalikan multiplier)
RISK_PER_TRADE = 1.0         # Risiko per trade dalam % (untuk referensi log)
MAX_DRAWDOWN_PERCENT = 20.0  # Stop bot jika DD mencapai 20%
DAILY_LOSS_PER_LOT = 1500.0  # Rumus: lot × 1500 = batas rugi harian (0.01→$15, 0.02→$30, dst)

# --- SL/TP BERBASIS ATR (Adaptif) ---
SL_ATR_MULTIPLIER = 1.5      # SL = 1.5 × ATR(M5)
TP_ATR_MULTIPLIER = 3.0      # TP = 3.0 × ATR(M5) → Risk:Reward 1:2

# --- MAGIC NUMBER (Identifikasi order bot) ---
MAGIC_NUMBER = 20260801

# ============================================================
# VARIABEL STATE (Tracking Harian & Drawdown)
# ============================================================
initial_balance = None
BASE_BALANCE = None          # ← Akan diisi otomatis dari initial_balance
last_loss_reset_date = None
daily_loss_accumulated = 0.0
last_equity_snapshot = 0.0

# ============================================================
# 1. INISIALISASI MT5
# ============================================================
print("🔄 Menghubungkan ke MetaTrader 5...")
if not mt5.initialize():
    print(f"❌ Gagal terhubung ke MT5. Error: {mt5.last_error()}")
    quit()

account_info = mt5.account_info()
if account_info is not None:
    initial_balance = account_info.balance
    BASE_BALANCE = initial_balance   # ← KUNCI: BASE_BALANCE = modal awal saat bot start
    last_equity_snapshot = account_info.equity
    
    print(f"✅ Terhubung! Akun: {account_info.login} | Server: {account_info.server}")
    print(f"💰 Modal Awal (BASE_BALANCE): ${BASE_BALANCE:.2f}")
    print(f"📊 Lot Dasar: {BASE_LOT} untuk setiap kelipatan ${BASE_BALANCE:.2f}")
    print(f"🛡️ Max Drawdown Protection: {MAX_DRAWDOWN_PERCENT}% (Stop jika modal < ${initial_balance * (1 - MAX_DRAWDOWN_PERCENT/100):.2f})")
else:
    print("❌ Gagal mendapatkan info akun.")
    mt5.shutdown()
    quit()

# ============================================================
# 2. FUNGSI RISK MANAGEMENT
# ============================================================
def calculate_dynamic_lot(balance):
    """
    Hitung lot dinamis berdasarkan kelipatan modal awal.
    Contoh jika BASE_BALANCE = $30:
      $30  → 30//30  = 1 → lot 0.01
      $59  → 59//30  = 1 → lot 0.01
      $60  → 60//30  = 2 → lot 0.02
      $90  → 90//30  = 3 → lot 0.03
      $120 → 120//30 = 4 → lot 0.04
    
    Contoh jika BASE_BALANCE = $100 (modal awal user):
      $100 → 100//100 = 1 → lot 0.01
      $200 → 200//100 = 2 → lot 0.02
      $300 → 300//100 = 3 → lot 0.03
    """
    multiplier = max(1, int(balance // BASE_BALANCE))
    lot = multiplier * BASE_LOT
    return round(lot, 2)

def get_daily_loss_limit(lot_size):
    """
    Hitung batas kerugian harian.
    0.01 → $15 | 0.02 → $30 | 0.03 → $45 | 0.04 → $60 | dst
    """
    return lot_size * (DAILY_LOSS_PER_LOT / 100)  # lot × 15

def reset_daily_loss_if_new_day():
    """Reset akumulasi loss harian jika sudah berganti hari."""
    global last_loss_reset_date, daily_loss_accumulated
    today = date.today()
    if last_loss_reset_date != today:
        daily_loss_accumulated = 0.0
        last_loss_reset_date = today
        print(f"📅 [{datetime.now().strftime('%H:%M:%S')}] Hari baru terdeteksi. Daily loss direset ke $0.")

def check_max_drawdown(current_balance):
    """Cek apakah drawdown sudah melebihi batas. Return True jika AMAN, False jika harus STOP."""
    min_allowed = initial_balance * (1 - MAX_DRAWDOWN_PERCENT / 100)
    if current_balance < min_allowed:
        print(f"🛑 🚨 MAX DRAWDOWN TERCAPAI! Balance: ${current_balance:.2f} | Batas: ${min_allowed:.2f}")
        print(f"🛑 Bot dihentikan permanen untuk melindungi modal.")
        return False
    return True

def check_daily_loss_limit(current_lot):
    """Cek apakah loss harian sudah melebihi batas untuk lot saat ini."""
    limit = get_daily_loss_limit(current_lot)
    if daily_loss_accumulated >= limit:
        print(f"⚠️ Daily loss limit tercapai untuk lot {current_lot}: ${daily_loss_accumulated:.2f} / ${limit:.2f}")
        return False
    return True

def track_daily_loss():
    """Lacak kerugian harian berdasarkan perubahan equity."""
    global daily_loss_accumulated, last_equity_snapshot
    account_info = mt5.account_info()
    if account_info is None:
        return
    
    current_equity = account_info.equity
    if current_equity < last_equity_snapshot:
        loss = last_equity_snapshot - current_equity
        daily_loss_accumulated += loss
    last_equity_snapshot = current_equity

# ============================================================
# 3. FUNGSI DATA & INDIKATOR
# ============================================================
def get_market_data_with_indicators(symbol, timeframe, bars=200):
    mt5.symbol_select(symbol, True)
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)
    if rates is None or len(rates) == 0:
        return None
    
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    
    # EMA
    df['ema_20'] = ta.trend.ema_indicator(df['close'], window=20)
    df['ema_50'] = ta.trend.ema_indicator(df['close'], window=50)
    df['ema_100'] = ta.trend.ema_indicator(df['close'], window=100)
    
    # RSI
    df['rsi_14'] = ta.momentum.rsi(df['close'], window=14)
    
    # Bollinger Bands
    df['bb_mid'] = ta.volatility.bollinger_mavg(df['close'], window=20)
    df['bb_upper'] = ta.volatility.bollinger_hband(df['close'], window=20)
    df['bb_lower'] = ta.volatility.bollinger_lband(df['close'], window=20)
    
    # MACD
    df['macd'] = ta.trend.macd(df['close'], window_fast=12, window_slow=26)
    df['macd_signal'] = ta.trend.macd_signal(df['close'], window_fast=12, window_slow=26, window_sign=9)
    df['macd_diff'] = df['macd'] - df['macd_signal']
    
    # ATR (untuk SL/TP)
    df['atr'] = ta.volatility.average_true_range(df['high'], df['low'], df['close'], window=14)
    
    return df

# ============================================================
# 4. FUNGSI ANALISIS SINYAL MTF
# ============================================================
def check_mtf_signal(symbol):
    data_h4 = get_market_data_with_indicators(symbol, TIMEFRAMES["H4"])
    data_h1 = get_market_data_with_indicators(symbol, TIMEFRAMES["H1"])
    data_m15 = get_market_data_with_indicators(symbol, TIMEFRAMES["M15"])
    data_m5 = get_market_data_with_indicators(symbol, TIMEFRAMES["M5"])
    
    if any(df is None or df.iloc[-2].isna().any() for df in [data_h4, data_h1, data_m15, data_m5]):
        return "HOLD", None, None

    h4 = data_h4.iloc[-2]
    h1 = data_h1.iloc[-2]
    m15 = data_m15.iloc[-2]
    m5 = data_m5.iloc[-2]
    atr_m5 = m5['atr']
    
    # --- KONDISI BUY ---
    h4_uptrend = h4['close'] > h4['ema_50'] and h4['ema_50'] > h4['ema_100'] and 10 <= h4['rsi_14'] <= 35
    h1_uptrend = h1['close'] > h1['ema_50'] and h1['ema_50'] > h1['ema_100'] and 10 <= h1['rsi_14'] <= 35
    m15_momentum = m15['macd_diff'] > 0 and 10 <= m15['rsi_14'] <= 35 and m15['close'] > m15['bb_mid'] and m15['close'] < m15['bb_upper']
    m5_trigger = m5['close'] > m5['ema_20'] and m5['macd_diff'] > 0 and 10 <= m5['rsi_14'] <= 35 and m5['close'] > m5['bb_mid'] and m5['close'] < m5['bb_upper']
    
    if h4_uptrend and h1_uptrend and m15_momentum and m5_trigger:
        return "BUY", m5, atr_m5
    
    # --- KONDISI SELL ---
    h4_downtrend = h4['close'] < h4['ema_50'] and h4['ema_50'] < h4['ema_100'] and h4['rsi_14'] > 65
    h1_downtrend = h1['close'] < h1['ema_50'] and h1['ema_50'] < h1['ema_100'] and h1['rsi_14'] > 65
    m15_momentum_neg = m15['macd_diff'] < 0 and 65 <= m15['rsi_14'] <= 120 and m15['close'] < m15['bb_mid'] and m15['close'] > m15['bb_lower']
    m5_trigger_neg = m5['close'] < m5['ema_20'] and m5['macd_diff'] < 0 and 65 <= m5['rsi_14'] <= 120 and m5['close'] < m5['bb_mid'] and m5['close'] > m5['bb_lower']
    
    if h4_downtrend and h1_downtrend and m15_momentum_neg and m5_trigger_neg:
        return "SELL", m5, atr_m5
        
    return "HOLD", m5, atr_m5

# ============================================================
# 5. FUNGSI CEK POSISI TERBUKA
# ============================================================
def has_open_position(symbol):
    """Cek apakah sudah ada posisi terbuka untuk symbol ini dari bot kita."""
    positions = mt5.positions_get(symbol=symbol)
    if positions is None:
        return False
    for pos in positions:
        if pos.magic == MAGIC_NUMBER:
            return True
    return False

# ============================================================
# 6. FUNGSI EKSEKUSI ORDER (OPEN BUY/SELL + SL/TP)
# ============================================================
def execute_trade(symbol, signal, atr_value):
    """Eksekusi order dengan SL & TP berbasis ATR."""
    if not mt5.symbol_select(symbol, True):
        print(f"❌ Simbol {symbol} tidak tersedia di Market Watch.")
        return False
    
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info is None:
        print(f"❌ Info simbol {symbol} tidak ditemukan.")
        return False
    
    if not symbol_info.visible:
        print(f"❌ Simbol {symbol} tidak visible.")
        return False
    
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        return False
    
    point = symbol_info.point
    digits = symbol_info.digits
    
    # Hitung SL & TP berdasarkan ATR
    sl_distance = atr_value * SL_ATR_MULTIPLIER
    tp_distance = atr_value * TP_ATR_MULTIPLIER
    
    # Normalisasi lot sesuai aturan broker
    account_info = mt5.account_info()
    current_lot = calculate_dynamic_lot(account_info.balance)
    
    # Sesuaikan dengan volume step broker
    lot_step = symbol_info.volume_step
    min_lot = symbol_info.volume_min
    max_lot = symbol_info.volume_max
    current_lot = max(min_lot, min(max_lot, current_lot))
    current_lot = round(round(current_lot / lot_step) * lot_step, 2)
    
    # Siapkan request order
    if signal == "BUY":
        price = tick.ask
        sl = price - sl_distance
        tp = price + tp_distance
        order_type = mt5.ORDER_TYPE_BUY
    else:  # SELL
        price = tick.bid
        sl = price + sl_distance
        tp = price - tp_distance
        order_type = mt5.ORDER_TYPE_SELL
    
    # Normalisasi harga SL/TP sesuai digits broker
    sl = round(sl, digits)
    tp = round(tp, digits)
    price = round(price, digits)
    
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": current_lot,
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": 20,
        "magic": MAGIC_NUMBER,
        "comment": f"MTF_Bot_{signal}",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    
    # Kirim order
    print(f"\n📤 Mengirim order {signal} {symbol}...")
    print(f"   📊 Lot: {current_lot} | Price: {price} | SL: {sl} | TP: {tp}")
    print(f"   📏 SL Distance: {sl_distance:.5f} | TP Distance: {tp_distance:.5f}")
    
    result = mt5.order_send(request)
    
    if result is None:
        print(f"❌ order_send gagal. Error: {mt5.last_error()}")
        return False
    
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"❌ Order ditolak. Retcode: {result.retcode} | Comment: {result.comment}")
        return False
    
    print(f"✅ ✅ ORDER BERHASIL! Ticket: {result.order} | {signal} {current_lot} lot {symbol} @ {price}")
    return True

# ============================================================
# 7. LOOP UTAMA BOT
# ============================================================
print("\n🤖 Bot Multi-Timeframe Scalper + Risk Management dimulai.")
print(f"💡 Lot dinamis aktif: {BASE_LOT} untuk setiap kelipatan modal awal (${BASE_BALANCE:.2f})")
print(f"💡 Tekan Ctrl+C untuk berhenti.\n")

bot_stopped = False

try:
    while not bot_stopped:
        # 1. Reset daily loss jika berganti hari
        reset_daily_loss_if_new_day()
        
        # 2. Ambil info akun terbaru
        account_info = mt5.account_info()
        if account_info is None:
            print("⚠️ Gagal mengambil info akun. Retry...")
            time.sleep(5)
            continue
        
        current_balance = account_info.balance
        
        # 3. Cek Max Drawdown
        if not check_max_drawdown(current_balance):
            bot_stopped = True
            break
        
        # 4. Hitung lot dinamis saat ini
        current_lot = calculate_dynamic_lot(current_balance)
        
        # 5. Cek Daily Loss Limit
        if not check_daily_loss_limit(current_lot):
            print(f"💤 Menunggu hari baru untuk reset daily loss...")
            time.sleep(300)
            continue
        
        # 6. Track loss harian
        track_daily_loss()
        
        # 7. Scan semua symbol
        for symbol in SYMBOLS_TO_TRADE:
            if has_open_position(symbol):
                continue
            
            signal, trigger_candle, atr_value = check_mtf_signal(symbol)
            
            if signal != "HOLD" and atr_value is not None and atr_value > 0:
                print(f"\n🚨 [{datetime.now().strftime('%H:%M:%S')}] SINYAL {signal} pada {symbol}!")
                print(f"   📊 Trigger M5 -> Close: {trigger_candle['close']:.2f} | RSI: {trigger_candle['rsi_14']:.2f}")
                print(f"   💰 Lot Dinamis: {current_lot} (Modal: ${current_balance:.2f} | BASE: ${BASE_BALANCE:.2f})")
                print(f"   📏 Daily Loss Terakumulasi: ${daily_loss_accumulated:.2f} / ${get_daily_loss_limit(current_lot):.2f}")
                
                execute_trade(symbol, signal, atr_value)
            else:
                pass
        
        time.sleep(60)

except KeyboardInterrupt:
    print("\n🛑 Bot dihentikan oleh pengguna.")
finally:
    mt5.shutdown()
    print("🔌 Koneksi ke MetaTrader 5 ditutup.")