import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime, timedelta
import sys

# ==============================================================================
# KONFIGURASI BOT (Samakan dengan Input di MQL5)
# ==============================================================================
class Config:
    # General
    SYMBOLS_STR = "BTCUSD.vx"   
    CHECK_INTERVAL = 15
    ENTRY_SCORE_THRESHOLD = 25
    MAX_DAILY_LOSS = 500.0
    MAGIC = 20260809
    COOLDOWN = 900           
    PRINT_LOGS = True

    # Trade Settings
    DEFAULT_LOT = 0.01
    RISK_PERCENT = 15.0     
    DEFAULT_MAX_SPREAD = 20
    DEFAULT_SL_DIST = 5.0     
    BTC_SL_DIST = 150.0   
    BTC_MAX_SPREAD = 10000
    MARGIN_BUFFER = 15.0
    SLIPPAGE = 20

    # SL/TP Multipliers
    SL_MULT = 12.0   
    TP_MULT = 20.0   

    # Data Settings
    TF_ENTRY = mt5.TIMEFRAME_M15
    TF_TREND = mt5.TIMEFRAME_H1
    BARS = 500

    # Candlestick Patterns
    USE_MARUBOZU = True
    USE_ENGULFING = True
    USE_MORNING_EVENING_STAR = True
    USE_DOJI = False
    REQUIRE_PATTERN = False

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================
def log(msg):
    if Config.PRINT_LOGS:
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}")

def parse_symbols(text):
    return [s.strip() for s in text.split(',') if s.strip()]

def diagnose_account():
    log("========== DIAGNOSA AKUN MT5 ==========")
    terminal_info = mt5.terminal_info()
    if not terminal_info.connected: 
        log("Terminal tidak terhubung."); return False
    if not terminal_info.trade_allowed: 
        log("Algo Trading mati di Terminal."); return False
        
    acc_info = mt5.account_info()
    if not acc_info.trade_allowed: 
        log("Account trade allowed = false."); return False
    if not acc_info.trade_expert: 
        log("Expert/EA trading tidak diizinkan."); return False

    log(f"Login   : {acc_info.login}")
    log(f"Server  : {acc_info.server}")
    log(f"Balance : {acc_info.balance:.2f}")
    log(f"Equity  : {acc_info.equity:.2f}")
    log("Semua izin trading terpenuhi. Bot siap berjalan.")
    log("=======================================")
    return True

def get_filling_type(symbol):
    """Mengambil mode filling yang didukung broker untuk menghindari Invalid Filling Mode."""
    info = mt5.symbol_info(symbol)
    filling_mode = info.filling_mode
    if filling_mode == mt5.ORDER_FILLING_FOK: return mt5.ORDER_FILLING_FOK
    if filling_mode == mt5.ORDER_FILLING_IOC: return mt5.ORDER_FILLING_IOC
    return mt5.ORDER_FILLING_RETURN

def get_smart_lot(symbol, sl_distance_price):
    balance = mt5.account_info().balance
    risk_amount = balance * (Config.RISK_PERCENT / 100.0)
    
    info = mt5.symbol_info(symbol)
    tick_value = info.trade_tick_value
    tick_size = info.trade_tick_size
    point = info.point
    
    if tick_value <= 0 or tick_size <= 0 or sl_distance_price <= 0 or point <= 0: 
        return Config.DEFAULT_LOT
        
    value_per_point = (tick_value / tick_size) * point
    sl_points = sl_distance_price / point
    calc_lot = risk_amount / (sl_points * value_per_point)
    
    calc_lot = np.floor(calc_lot / info.volume_step) * info.volume_step
    calc_lot = max(info.volume_min, min(info.volume_max, calc_lot))
    
    margin_req = mt5.order_calc_margin(mt5.ORDER_TYPE_BUY, symbol, calc_lot, info.ask)
    if margin_req is not None:
        free_margin = mt5.account_info().margin_free
        if margin_req > free_margin * 0.8:
            calc_lot = info.volume_min
            
    return round(calc_lot, 2)

def get_max_spread_points(symbol): 
    return Config.BTC_MAX_SPREAD if "BTCUSD" in symbol else Config.DEFAULT_MAX_SPREAD

def get_sl_distance(symbol): 
    return Config.BTC_SL_DIST if "BTCUSD" in symbol else Config.DEFAULT_SL_DIST

def has_open_position(symbol):
    positions = mt5.positions_get(symbol=symbol)
    return positions is not None and len(positions) > 0

def get_daily_loss():
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    deals = mt5.history_deals_get(today, datetime.now())
    if deals is None: return 0.0
    
    loss = 0.0
    for deal in deals:
        if deal.profit < 0 and deal.magic == Config.MAGIC:
            loss += abs(deal.profit)
    return loss

# ==============================================================================
# DATA RATES & INDICATORS
# Catatan Penting: Data di-reverse agar index 0 = candle saat ini (shift 0),
# index 1 = candle sebelumnya (shift 1), persis seperti array di MQL5.
# ==============================================================================
def get_rates(symbol, timeframe, count):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    if rates is None or len(rates) < count:
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    # Reverse dataframe: index 0 adalah candle terbaru (Current Bar)
    df = df.iloc[::-1].reset_index(drop=True)
    return df

def sma(df, period, shift):
    if shift + period > len(df): return np.nan
    return df['close'].iloc[shift : shift + period].mean()

def std_dev_close(df, period, shift):
    if shift + period > len(df): return np.nan
    return df['close'].iloc[shift : shift + period].std(ddof=1)

def bollinger(df, period, mult, shift):
    mid = sma(df, period, shift)
    std = std_dev_close(df, period, shift)
    if pd.isna(mid) or pd.isna(std): return np.nan, np.nan, np.nan
    return mid + mult * std, mid, mid - mult * std

def rsi_simple(df, period, shift):
    if shift + period + 1 > len(df): return np.nan
    closes = df['close'].iloc[shift : shift + period + 1].values
    changes = np.diff(closes)
    gains = np.where(changes > 0, changes, 0)
    losses = np.where(changes < 0, -changes, 0)
    avg_gain = np.mean(gains)
    avg_loss = np.mean(losses)
    if avg_loss == 0: return 100.0 if avg_gain > 0 else 50.0
    rs = avg_gain / avg_loss
    return 100.0 - (100.0 / (1.0 + rs))

def build_ad(df):
    # Reversing back to chronological order for cumulative sum
    df_chron = df.iloc[::-1].copy()
    range_ = df_chron['high'] - df_chron['low']
    clv = ((df_chron['close'] - df_chron['low']) - (df_chron['high'] - df_chron['close'])) / (range_ + 1e-10)
    mfv = clv * df_chron['tick_volume']
    ad = mfv.cumsum()
    return ad.iloc[::-1].reset_index(drop=True).values

def volume_average(df, period, shift):
    if shift + period > len(df): return np.nan
    return df['tick_volume'].iloc[shift : shift + period].mean()

def min_close(df, count, start_shift):
    if start_shift + count > len(df): return np.nan
    return df['close'].iloc[start_shift : start_shift + count].min()

def max_close(df, count, start_shift):
    if start_shift + count > len(df): return np.nan
    return df['close'].iloc[start_shift : start_shift + count].max()

def min_double(arr, count, start_shift):
    if start_shift + count > len(arr): return np.nan
    return np.min(arr[start_shift : start_shift + count])

def max_double(arr, count, start_shift):
    if start_shift + count > len(arr): return np.nan
    return np.max(arr[start_shift : start_shift + count])

def check_h1_trend(df_h1):
    ma50 = sma(df_h1, 50, 1)
    ma200 = sma(df_h1, 200, 1)
    if pd.isna(ma50) or pd.isna(ma200): return 0
    close1 = df_h1.iloc[1]['close']
    if close1 > ma50 and ma50 > ma200: return 1
    if close1 < ma50 and ma50 < ma200: return -1
    return 0

# ==============================================================================
# CANDLESTICK PATTERNS
# ==============================================================================
def get_body(df, shift): return abs(df.iloc[shift]['close'] - df.iloc[shift]['open'])
def get_range(df, shift): return df.iloc[shift]['high'] - df.iloc[shift]['low'] + 1e-10
def get_upper_shadow(df, shift):
    row = df.iloc[shift]
    return row['high'] - row['close'] if row['close'] > row['open'] else row['high'] - row['open']
def get_lower_shadow(df, shift):
    row = df.iloc[shift]
    return row['open'] - row['low'] if row['close'] > row['open'] else row['close'] - row['low']

def is_bullish_marubozu(df, shift):
    if df.iloc[shift]['close'] <= df.iloc[shift]['open']: return False
    r = get_range(df, shift); 
    if r == 0: return False
    return (get_body(df, shift)/r > 0.90) and (get_upper_shadow(df, shift)/r < 0.05) and (get_lower_shadow(df, shift)/r < 0.05)

def is_bearish_marubozu(df, shift):
    if df.iloc[shift]['close'] >= df.iloc[shift]['open']: return False
    r = get_range(df, shift); 
    if r == 0: return False
    return (get_body(df, shift)/r > 0.90) and (get_upper_shadow(df, shift)/r < 0.05) and (get_lower_shadow(df, shift)/r < 0.05)

def is_bullish_engulfing(df, shift):
    curr = df.iloc[shift]; prev = df.iloc[shift+1]
    if curr['close'] <= curr['open'] or prev['close'] >= prev['open']: return False
    return (curr['close'] > prev['open']) and (curr['open'] < prev['close']) and (get_body(df, shift) > get_body(df, shift+1))

def is_bearish_engulfing(df, shift):
    curr = df.iloc[shift]; prev = df.iloc[shift+1]
    if curr['close'] >= curr['open'] or prev['close'] <= prev['open']: return False
    return (curr['close'] < prev['open']) and (curr['open'] > prev['close']) and (get_body(df, shift) > get_body(df, shift+1))

# def is_doji(df, shift):
#     r = get_range(df, shift)
#     return (get_body(df, shift) / r) < 0.15 if r > 0 else False

# def is_morning_star(df, shift):
#     if shift + 2 >= len(df): return False
#     third, second, first = df.iloc[shift], df.iloc[shift+1], df.iloc[shift+2]
#     if not (first['close'] < first['open'] and get_body(df, shift+2)/get_range(df, shift+2) >= 0.5): return False
#     if not (is_doji(df, shift+1) or get_body(df, shift+1)/get_range(df, shift+1) < 0.3): return False
#     if not (third['close'] > third['open'] and get_body(df, shift)/get_range(df, shift) >= 0.5): return False
#     return third['close'] > (first['open'] + first['close']) / 2.0

# def is_evening_star(df, shift):
#     if shift + 2 >= len(df): return False
#     third, second, first = df.iloc[shift], df.iloc[shift+1], df.iloc[shift+2]
#     if not (first['close'] > first['open'] and get_body(df, shift+2)/get_range(df, shift+2) >= 0.5): return False
#     if not (is_doji(df, shift+1) or get_body(df, shift+1)/get_range(df, shift+1) < 0.3): return False
#     if not (third['close'] < third['open'] and get_body(df, shift)/get_range(df, shift) >= 0.5): return False
#     return third['close'] < (first['open'] + first['close']) / 2.0

# ==============================================================================
# SCORING & EXECUTION
# ==============================================================================
def calculate_entry_score(df_m15, df_h1, dir):
    if len(df_m15) < 60 or len(df_h1) < 210: return 0

    score = 0
    close1 = df_m15.iloc[1]['close']
    ma20_1 = sma(df_m15, 20, 1)
    ma50_1 = sma(df_m15, 50, 1)
    if pd.isna(ma20_1) or pd.isna(ma50_1): return 0

    bb_u, bb_m, bb_l = bollinger(df_m15, 20, 2.0, 1)
    if pd.isna(bb_u): return 0

    in_ma_zone, touch_bb = False, False
    if dir > 0:
        in_ma_zone = (ma50_1 <= close1 <= ma20_1)
        touch_bb = (df_m15.iloc[1]['low'] <= bb_l)
    else:
        in_ma_zone = (ma20_1 <= close1 <= ma50_1)
        touch_bb = (df_m15.iloc[1]['high'] >= bb_u)
    if in_ma_zone or touch_bb: score += 30

    rsi1 = rsi_simple(df_m15, 14, 1)
    if pd.isna(rsi1): return 0
    rsi_ok = (30.0 <= rsi1 <= 65.0) if dir > 0 else (35.0 <= rsi1 <= 70.0)
    
    ad_m15 = build_ad(df_m15)
    divergence = False
    if dir > 0:
        min_c, min_ad = min_close(df_m15, 9, 2), min_double(ad_m15, 9, 2)
        if not pd.isna(min_c) and not pd.isna(min_ad):
            divergence = (close1 < min_c and ad_m15[1] > min_ad)
    else:
        max_c, max_ad = max_close(df_m15, 9, 2), max_double(ad_m15, 9, 2)
        if not pd.isna(max_c) and not pd.isna(max_ad):
            divergence = (close1 > max_c and ad_m15[1] < max_ad)
            
    if (dir > 0 and (rsi_ok or divergence)) or (dir < 0 and (rsi_ok or divergence)): score += 25

    ad_h1 = build_ad(df_h1)
    ad_slope_h1 = sum(ad_h1[i] - ad_h1[i+1] for i in range(1, 6)) / 5.0 if len(ad_h1) >= 7 else 0.0
    
    vol_avg = volume_average(df_m15, 20, 1)
    vol_confirmed = False if pd.isna(vol_avg) else (df_m15.iloc[1]['tick_volume'] > vol_avg)
    if (dir > 0 and ad_slope_h1 >= 0.0 and vol_confirmed) or (dir < 0 and ad_slope_h1 <= 0.0 and vol_confirmed): score += 25

    pattern_triggered, pattern_name = False, ""
    if dir > 0:
        if Config.USE_MARUBOZU and is_bullish_marubozu(df_m15, 1): pattern_triggered, pattern_name = True, "Bullish Marubozu"
        elif Config.USE_ENGULFING and is_bullish_engulfing(df_m15, 1): pattern_triggered, pattern_name = True, "Bullish Engulfing"
        # elif Config.USE_MORNING_EVENING_STAR and is_morning_star(df_m15, 1): pattern_triggered, pattern_name = True, "Morning Star"
        # elif Config.USE_DOJI and is_doji(df_m15, 1): pattern_triggered, pattern_name = True, "Doji"
    else:
        if Config.USE_MARUBOZU and is_bearish_marubozu(df_m15, 1): pattern_triggered, pattern_name = True, "Bearish Marubozu"
        elif Config.USE_ENGULFING and is_bearish_engulfing(df_m15, 1): pattern_triggered, pattern_name = True, "Bearish Engulfing"
        # elif Config.USE_MORNING_EVENING_STAR and is_evening_star(df_m15, 1): pattern_triggered, pattern_name = True, "Evening Star"
        # elif Config.USE_DOJI and is_doji(df_m15, 1): pattern_triggered, pattern_name = True, "Doji"

    if Config.REQUIRE_PATTERN and not pattern_triggered: return 0
    if pattern_triggered:
        score += 30
        log(f"[CANDLE PATTERN] {pattern_name} terdeteksi pada M15 (Shift 1)")
    else:
        r = get_range(df_m15, 1)
        body_ratio = get_body(df_m15, 1) / r
        bullish_candle = df_m15.iloc[1]['close'] > df_m15.iloc[1]['open']
        if (dir > 0 and bullish_candle and body_ratio > 0.3) or (dir < 0 and not bullish_candle and body_ratio > 0.3):
            score += 20
    return score

def execute_trade(symbol, dir):
    tick = mt5.symbol_info_tick(symbol)
    if tick is None: return False
    
    info = mt5.symbol_info(symbol)
    point, digits = info.point, info.digits
    if point <= 0.0: return False

    entry = tick.ask if dir > 0 else tick.bid
    if entry <= 0.0: return False

    spread = tick.ask - tick.bid
    sl_dist = get_sl_distance(symbol)
    min_stop = (info.trade_stops_level * point) if info.trade_stops_level > 0 else 10.0 * point
    actual_sl_dist = max(sl_dist, spread + min_stop + 10.0 * point)

    if dir > 0:
        sl, tp = entry - (actual_sl_dist * Config.SL_MULT), entry + (actual_sl_dist * Config.TP_MULT)
    else:
        sl, tp = entry + (actual_sl_dist * Config.SL_MULT), entry - (actual_sl_dist * Config.TP_MULT)

    if sl <= 0.0 or tp <= 0.0: return False

    # Adjust stops
    if dir > 0:
        if entry - sl < min_stop: sl = entry - min_stop
        if tp - entry < min_stop: tp = entry + min_stop
    else:
        if sl - entry < min_stop: sl = entry + min_stop
        if entry - tp < min_stop: tp = entry - min_stop

    entry, sl, tp = round(entry, digits), round(sl, digits), round(tp, digits)
    lot = get_smart_lot(symbol, abs(entry - sl))
    
    margin_req = mt5.order_calc_margin(mt5.ORDER_TYPE_BUY if dir > 0 else mt5.ORDER_TYPE_SELL, symbol, lot, entry)
    if margin_req is None or mt5.account_info().margin_free < margin_req + Config.MARGIN_BUFFER: return False

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": lot,
        "type": mt5.ORDER_TYPE_BUY if dir > 0 else mt5.ORDER_TYPE_SELL,
        "price": entry,
        "sl": sl,
        "tp": tp,
        "deviation": Config.SLIPPAGE,
        "magic": Config.MAGIC,
        "comment": "Confluence_BUY" if dir > 0 else "Confluence_SELL",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": get_filling_type(symbol),
    }

    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        log(f"[ERROR] {symbol}: retcode={result.retcode}, comment={result.comment}")
        return False
        
    log(f"[SUCCESS] {symbol} {'BUY' if dir>0 else 'SELL'} @ {entry} | SL:{sl} TP:{tp}")
    return True

# ==============================================================================
# MAIN LOOP & SMART EXIT
# ==============================================================================
last_entry_time = {}
last_m15_bar_time = {}

def process_symbol(symbol):
    log(f"=== {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | Cek {symbol} ===")
    if has_open_position(symbol): return
    
    now = time.time()
    if symbol in last_entry_time and (now - last_entry_time[symbol] < Config.COOLDOWN): return

    df_m15 = get_rates(symbol, Config.TF_ENTRY, Config.BARS)
    df_h1 = get_rates(symbol, Config.TF_TREND, Config.BARS)
    if df_m15 is None or df_h1 is None: return

    current_bar_time = df_m15.iloc[0]['time']
    if last_m15_bar_time.get(symbol) == current_bar_time: return
    last_m15_bar_time[symbol] = current_bar_time

    trend = check_h1_trend(df_h1)
    if trend == 0: return

    ma20_1 = sma(df_m15, 20, 1)
    ma50_1 = sma(df_m15, 50, 1)
    if pd.isna(ma20_1) or pd.isna(ma50_1): return

    close1 = df_m15.iloc[1]['close']
    m15_trend_ok = False
    if trend > 0 and close1 > ma20_1 and ma20_1 > ma50_1: m15_trend_ok = True
    if trend < 0 and close1 < ma20_1 and ma20_1 < ma50_1: m15_trend_ok = True
    if not m15_trend_ok: return

    signal = 0
    if trend > 0:
        score = calculate_entry_score(df_m15, df_h1, 1)
        if score >= Config.ENTRY_SCORE_THRESHOLD: signal = 1
    else:
        score = calculate_entry_score(df_m15, df_h1, -1)
        if score >= Config.ENTRY_SCORE_THRESHOLD: signal = -1

    if signal != 0 and execute_trade(symbol, signal):
        last_entry_time[symbol] = time.time()

def manage_smart_exit():
    positions = mt5.positions_get()
    if positions is None: return

    for pos in positions:
        if pos.magic != Config.MAGIC: continue
        symbol = pos.symbol
        
        df_m15 = get_rates(symbol, Config.TF_ENTRY, 60)
        if df_m15 is None: continue

        ma20 = sma(df_m15, 20, 0)
        ma50 = sma(df_m15, 50, 0)
        if pd.isna(ma20) or pd.isna(ma50): continue

        close0 = df_m15.iloc[0]['close']
        m15_bullish = close0 > ma20 and ma20 > ma50
        m15_bearish = close0 < ma20 and ma20 < ma50

        should_close = False
        if pos.type == mt5.POSITION_TYPE_BUY and m15_bearish: should_close = True
        elif pos.type == mt5.POSITION_TYPE_SELL and m15_bullish: should_close = True

        if should_close:
            request = {
                "action": mt5.TRADE_ACTION_DEAL,
                "symbol": symbol,
                "volume": pos.volume,
                "type": mt5.ORDER_TYPE_SELL if pos.type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY,
                "position": pos.ticket,
                "price": mt5.symbol_info_tick(symbol).bid if pos.type == mt5.POSITION_TYPE_BUY else mt5.symbol_info_tick(symbol).ask,
                "deviation": Config.SLIPPAGE,
                "magic": Config.MAGIC,
                "comment": "Smart Exit",
                "type_time": mt5.ORDER_TIME_GTC,
                "type_filling": get_filling_type(symbol),
            }
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                log(f"[SMART EXIT] {symbol} | Posisi ditutup. Profit: {pos.profit}")

def main():
    if not mt5.initialize():
        print(f"initialize() failed, error code = {mt5.last_error()}")
        sys.exit()

    if not diagnose_account():
        mt5.shutdown()
        sys.exit()

    symbols = parse_symbols(Config.SYMBOLS_STR)
    for sym in symbols:
        mt5.symbol_select(sym, True)

    log(f"Bot running... Symbols: {Config.SYMBOLS_STR}")

    try:
        while True:
            manage_smart_exit()
            daily_loss = get_daily_loss()
            
            if daily_loss >= Config.MAX_DAILY_LOSS:
                log(f"DAILY LOSS LIMIT: {daily_loss}. Bot istirahat.")
            else:
                for sym in symbols:
                    process_symbol(sym)

            time.sleep(Config.CHECK_INTERVAL)
            
    except KeyboardInterrupt:
        log("Bot stopped by user.")
    finally:
        mt5.shutdown()

if __name__ == "__main__":
    main()