import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ================= KONFIGURASI =================
SYMBOLS = [
    # "XAUUSD.vx",
    "BTCUSD.vx"
]

CHECK_INTERVAL_SECONDS = 15

ENTRY_SCORE_THRESHOLD = 70
MAX_DAILY_LOSS = 5.0

MAGIC = 20260809
COOLDOWN_SECONDS = 15 * 60  # 15 menit cooldown setelah entry sukses

DEFAULT_SETTINGS = {
    "lot": 0.01,
    "max_spread_points": 20,
    "sl_distance": 3.0,
}

SYMBOL_SETTINGS = {
    "XAUUSD.vx": {
        "lot": 0.01,
        "max_spread_points": 20,
        "sl_distance": 3.0,
    },
    "BTCUSD.vx": {
        "lot": 0.01,
        "max_spread_points": 100,
        "sl_distance": 3.0,  # Untuk BTC biasanya perlu lebih besar, misalnya 50/100/200
    },
}

last_entry_time = {}

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


# ================= HELPER SETTING =================
def get_setting(symbol, key):
    symbol_setting = SYMBOL_SETTINGS.get(symbol, {})
    if key in symbol_setting:
        return symbol_setting[key]
    return DEFAULT_SETTINGS[key]


# ================= AMBIL DATA =================
def get_rates(symbol, timeframe, count=500):
    """
    Ambil data candle dari MT5 dengan validasi.
    """
    if not mt5.symbol_select(symbol, True):
        print(f"[WARN] {symbol}: symbol_select gagal. last_error={mt5.last_error()}")
        return pd.DataFrame()

    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)

    if rates is None:
        print(f"[WARN] {symbol}: copy_rates_from_pos gagal. last_error={mt5.last_error()}")
        return pd.DataFrame()

    if len(rates) == 0:
        print(f"[WARN] {symbol}: data rates kosong.")
        return pd.DataFrame()

    df = pd.DataFrame(rates)

    required_columns = {'time', 'open', 'high', 'low', 'close', 'tick_volume'}
    missing_columns = required_columns.difference(df.columns)

    if missing_columns:
        print(f"[WARN] {symbol}: kolom hilang {missing_columns}")
        print("Columns:", df.columns.tolist())
        return pd.DataFrame()

    return df


# ================= INDIKATOR =================
def calculate_all_indicators(df):
    """
    Hitung semua indikator dalam satu pass.
    """
    if df is None or df.empty:
        return pd.DataFrame()

    required_columns = {'open', 'high', 'low', 'close', 'tick_volume'}
    missing_columns = required_columns.difference(df.columns)

    if missing_columns:
        print("[WARN] Kolom indikator tidak lengkap:", missing_columns)
        return pd.DataFrame()

    df = df.copy()

    # Moving Averages
    for period in [20, 50, 100, 200]:
        df[f'ma{period}'] = df['close'].rolling(window=period).mean()

    # Bollinger Bands
    df['bb_middle'] = df['close'].rolling(window=20).mean()
    std = df['close'].rolling(window=20).std()
    df['bb_upper'] = df['bb_middle'] + (2.0 * std)
    df['bb_lower'] = df['bb_middle'] - (2.0 * std)

    # RSI
    delta = df['close'].diff()
    gain = delta.where(delta > 0, 0).rolling(window=14).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=14).mean()
    df['rsi'] = 100 - (100 / (1 + gain / loss.replace(0, np.nan)))

    # A/D Line
    clv = ((df['close'] - df['low']) - (df['high'] - df['close'])) / (df['high'] - df['low'] + 1e-10)
    df['ad_line'] = (clv * df['tick_volume']).cumsum()

    # Volume Average
    df['vol_avg'] = df['tick_volume'].rolling(window=20).mean()

    return df.dropna()


# ================= TREND H1 =================
def check_h1_trend_alignment(df_h1):
    """
    Cek alignment MA di H1.
    """
    if df_h1 is None or df_h1.empty:
        return "RANGING"

    last = df_h1.iloc[-1]

    required = ['ma20', 'ma50', 'ma100', 'ma200']
    for col in required:
        if col not in last or pd.isna(last[col]):
            return "RANGING"

    if last['ma20'] > last['ma50'] > last['ma100'] > last['ma200']:
        return "BULLISH"
    elif last['ma20'] < last['ma50'] < last['ma100'] < last['ma200']:
        return "BEARISH"

    return "RANGING"


# ================= SCORING ENTRY =================
def calculate_entry_score(df_m15, df_h1, direction):
    """
    Sistem scoring konfluensi multi-indikator.
    """
    if df_m15 is None or df_h1 is None:
        return 0

    if len(df_m15) < 10 or len(df_h1) < 5:
        return 0

    score = 0
    last = df_m15.iloc[-1]
    prev = df_m15.iloc[-2]

    # 1. ZONA VALUE (Max 30)
    in_ma_zone = (last['ma50'] <= last['close'] <= last['ma20']) if direction == "BUY" \
                 else (last['ma20'] <= last['close'] <= last['ma50'])

    touch_bb = (prev['low'] <= prev['bb_lower']) if direction == "BUY" \
               else (prev['high'] >= prev['bb_upper'])

    if in_ma_zone or touch_bb:
        score += 30

    # 2. MOMENTUM RSI (Max 25)
    rsi_ok = (40 <= last['rsi'] <= 50) if direction == "BUY" else (50 <= last['rsi'] <= 60)

    div_bullish = (
        last['close'] < df_m15['close'].iloc[-10:].min() and
        last['ad_line'] > df_m15['ad_line'].iloc[-10:].min()
    )

    div_bearish = (
        last['close'] > df_m15['close'].iloc[-10:].max() and
        last['ad_line'] < df_m15['ad_line'].iloc[-10:].max()
    )

    if (direction == "BUY" and (rsi_ok or div_bullish)) or \
       (direction == "SELL" and (rsi_ok or div_bearish)):
        score += 25

    # 3. VALIDASI VOLUME & A/D (Max 25)
    ad_slope_h1 = df_h1['ad_line'].diff().tail(5).mean()
    vol_confirmed = last['tick_volume'] > last['vol_avg']

    if (direction == "BUY" and ad_slope_h1 >= 0 and vol_confirmed) or \
       (direction == "SELL" and ad_slope_h1 <= 0 and vol_confirmed):
        score += 25

    # 4. CANDLE TRIGGER (Max 20)
    body_ratio = abs(last['close'] - last['open']) / (last['high'] - last['low'] + 1e-10)
    bullish_candle = last['close'] > last['open']

    if (direction == "BUY" and bullish_candle and body_ratio > 0.6) or \
       (direction == "SELL" and not bullish_candle and body_ratio > 0.6):
        score += 20

    return score


# ================= CEK POSISI TERBUKA =================
def has_open_position(symbol):
    """
    Cek apakah masih ada posisi terbuka pada symbol.
    Ini penting supaya bot tidak entry berulang-ulang.
    """
    positions = mt5.positions_get(symbol=symbol)

    if positions is None:
        return False

    return len(positions) > 0


# ================= DAILY LOSS =================
def get_daily_loss():
    """
    Hitung total loss hari ini.
    """
    start_today = datetime.today().replace(hour=0, minute=0, second=0, microsecond=0)
    deals = mt5.history_deals_get(start_today)

    if deals is None:
        return 0.0

    loss = 0.0

    for deal in deals:
        if deal.profit < 0:
            loss += deal.profit

    return abs(loss)


# ================= EKSEKUSI ORDER =================
def execute_trade(symbol, direction, entry_price, sl, tp):
    """
    Eksekusi order dengan validasi spread, margin, dan order send.
    """
    tick = mt5.symbol_info_tick(symbol)
    info = mt5.symbol_info(symbol)

    if tick is None or info is None:
        print(f"[ERROR] {symbol}: gagal ambil tick / symbol info.")
        return False

    point = info.point

    if point <= 0:
        print(f"[ERROR] {symbol}: point tidak valid.")
        return False

    lot = get_setting(symbol, "lot")
    max_spread_points = get_setting(symbol, "max_spread_points")

    # Validasi spread
    spread = tick.ask - tick.bid
    if spread > max_spread_points * point:
        print(f"[SKIP] {symbol}: spread lebar {spread / point:.1f} points")
        return False

    order_type = mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL

    # Validasi margin
    margin_req = mt5.order_calc_margin(
        order_type,
        symbol,
        lot,
        entry_price
    )

    if margin_req is None:
        print(f"[ERROR] {symbol}: order_calc_margin gagal.")
        return False

    account = mt5.account_info()

    if account is None:
        print("[ERROR] account_info gagal.")
        return False

    if account.margin_free < margin_req + 15:
        print(f"[SKIP] {symbol}: free margin kurang. Free margin=${account.margin_free:.2f}, margin_req=${margin_req:.2f}")
        return False

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": lot,
        "type": order_type,
        "price": entry_price,
        "sl": round(sl, info.digits),
        "tp": round(tp, info.digits),
        "deviation": 20,
        "magic": MAGIC,
        "comment": f"Confluence_{direction}",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }

    result = mt5.order_send(request)

    if result is None:
        print(f"[ERROR] {symbol}: order_send None. last_error={mt5.last_error()}")
        return False

    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"[ERROR] {symbol}: retcode={result.retcode}, comment={result.comment}")
        return False

    print(f"[SUCCESS] {symbol} {direction} @ {entry_price} | SL:{sl} TP:{tp}")
    return True


# ================= PROSES SATU SYMBOL =================
def process_symbol(symbol):
    print(f" === {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | Cek {symbol} ===")

    # Skip jika masih ada posisi terbuka
    if has_open_position(symbol):
        print(f"[SKIP] {symbol}: masih ada posisi terbuka.")
        return

    # Cooldown setelah entry sukses
    now = time.time()
    if symbol in last_entry_time:
        elapsed = now - last_entry_time[symbol]
        if elapsed < COOLDOWN_SECONDS:
            print(f"[SKIP] {symbol}: cooldown aktif, baru entry {elapsed:.0f} detik lalu.")
            return

    # Ambil data M15 dan H1
    df_m15 = calculate_all_indicators(get_rates(symbol, mt5.TIMEFRAME_M15, 500))
    df_h1 = calculate_all_indicators(get_rates(symbol, mt5.TIMEFRAME_H1, 500))

    if df_m15.empty or df_h1.empty:
        print(f"[SKIP] {symbol}: data tidak cukup.")
        return

    # Cek trend H1
    trend = check_h1_trend_alignment(df_h1)
    print(f"Trend H1 {symbol}: {trend}")

    if trend == "RANGING":
        print(f"[SKIP] {symbol}: market ranging.")
        return

    tick = mt5.symbol_info_tick(symbol)

    if tick is None:
        print(f"[ERROR] {symbol}: tick None.")
        return

    signal_dir = None
    entry = None
    score = 0

    if trend == "BULLISH":
        score = calculate_entry_score(df_m15, df_h1, "BUY")
        print(f"Score BUY {symbol}: {score}")

        if score >= ENTRY_SCORE_THRESHOLD:
            signal_dir = "BUY"
            entry = tick.ask

    elif trend == "BEARISH":
        score = calculate_entry_score(df_m15, df_h1, "SELL")
        print(f"Score SELL {symbol}: {score}")

        if score >= ENTRY_SCORE_THRESHOLD:
            signal_dir = "SELL"
            entry = tick.bid

    if signal_dir is None or entry is None:
        print(f"No signal untuk {symbol} (Score threshold {ENTRY_SCORE_THRESHOLD} not met)")
        return

    sl_distance = get_setting(symbol, "sl_distance")

    if signal_dir == "BUY":
        sl = entry - sl_distance
        tp = entry + (sl_distance * 1.5)
    else:
        sl = entry + sl_distance
        tp = entry - (sl_distance * 1.5)

    success = execute_trade(symbol, signal_dir, entry, sl, tp)

    if success:
        last_entry_time[symbol] = time.time()


# ================= MAIN LOOP =================
def main():
    
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

    print("Bot running...")
    print("Symbols:", SYMBOLS)
    print(f"Interval cek: {CHECK_INTERVAL_SECONDS} detik")
    print("Tekan Ctrl+C untuk stop.")

    try:
        while True:
            daily_loss = get_daily_loss()

            if daily_loss >= MAX_DAILY_LOSS:
                print(f"DAILY LOSS LIMIT: ${daily_loss:.2f}. Bot istirahat, tidak cek entry dulu.")
            else:
                for symbol in SYMBOLS:
                    try:
                        process_symbol(symbol)
                    except Exception as e:
                        print(f"[EXCEPTION] {symbol}: {e}")

            print(f"Menunggu {CHECK_INTERVAL_SECONDS} detik...")
            time.sleep(CHECK_INTERVAL_SECONDS)

    except KeyboardInterrupt:
        print("Bot dihentikan manual oleh user.")

    finally:
        mt5.shutdown()
        print("MT5 shutdown selesai.")


if __name__ == "__main__":
    main()