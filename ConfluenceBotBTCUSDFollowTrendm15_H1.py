import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
import math
from datetime import datetime, timedelta

# +------------------------------------------------------------------+
# | Konfigurasi Bot (Pengganti 'input' di MQL5)                      |
# +------------------------------------------------------------------+
class Config:
    SYMBOLS_STR = "BTCUSD.vx"
    CHECK_INTERVAL = 15
    ENTRY_SCORE_THRESHOLD = 45      # Turunkan dari 70 ke 45/50 agar lebih sering entry
    MAX_DAILY_LOSS = 500.0         # Naikkan ke 500 agar tidak stop saat testing
    MAGIC = 20260809
    COOLDOWN = 900
    PRINT_LOGS = True
    
    DEFAULT_LOT = 0.01
    RISK_PERCENT = 15.0             # Risiko per trade %
    DEFAULT_MAX_SPREAD = 20
    DEFAULT_SL_DISTANCE = 5.0       
    BTC_SL_DISTANCE = 150.0         
    BTC_MAX_SPREAD = 10000          # Spread BTC bisa sangat lebar
    MARGIN_BUFFER = 15.0
    SLIPPAGE = 20
    
    TF_ENTRY = mt5.TIMEFRAME_M15
    TF_TREND = mt5.TIMEFRAME_H1
    BARS = 500

# +------------------------------------------------------------------+
# | Logging helper                                                   |
# +------------------------------------------------------------------+
def log(message):
    if Config.PRINT_LOGS:
        print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}")

# +------------------------------------------------------------------+
# | Parse comma-separated symbols                                    |
# +------------------------------------------------------------------+
def parse_symbols(text):
    return [s.strip() for s in text.split(',') if s.strip()]

# +------------------------------------------------------------------+
# | Diagnose account and terminal                                    |
# +------------------------------------------------------------------+
def diagnose_account():
    log("========== DIAGNOSA AKUN MT5 ==========")
    terminal_info = mt5.terminal_info()
    if not terminal_info:
        log("Terminal tidak terhubung.")
        return False
    
    acc_info = mt5.account_info()
    if not acc_info:
        log("Gagal mengambil info akun.")
        return False
        
    if not acc_info.trade_allowed:
        log("Algo Trading mati atau Account trade not allowed. Pastikan AutoTrading aktif.")
        return False
        
    log(f"Login   : {acc_info.login}")
    log(f"Server  : {acc_info.server}")
    log(f"Name    : {acc_info.name}")
    log(f"Balance : {acc_info.balance:.2f}")
    log(f"Equity  : {acc_info.equity:.2f}")
    log("Semua izin trading terpenuhi. Bot siap berjalan.")
    log("=======================================")
    return True

# +------------------------------------------------------------------+
# | Smart Lot Calculator                                             |
# +------------------------------------------------------------------+
def get_smart_lot(symbol, sl_distance_price):
    acc_info = mt5.account_info()
    balance = acc_info.balance
    risk_amount = balance * (Config.RISK_PERCENT / 100.0)
    
    sym_info = mt5.symbol_info(symbol)
    if not sym_info: return Config.DEFAULT_LOT
        
    tick_value = sym_info.trade_tick_value
    tick_size = sym_info.trade_tick_size
    point = sym_info.point
    
    if tick_value <= 0 or tick_size <= 0 or sl_distance_price <= 0 or point <= 0:
        return Config.DEFAULT_LOT
        
    value_per_point = (tick_value / tick_size) * point
    sl_points = sl_distance_price / point
    
    calculated_lot = risk_amount / (sl_points * value_per_point)
    
    min_lot = sym_info.volume_min
    max_lot = sym_info.volume_max
    step_lot = sym_info.volume_step
    
    calculated_lot = math.floor(calculated_lot / step_lot) * step_lot
    calculated_lot = max(min_lot, min(calculated_lot, max_lot))
    
    # Proteksi margin
    current_price = sym_info.ask
    margin_req = mt5.order_calc_margin(mt5.ORDER_TYPE_BUY, symbol, calculated_lot, current_price)
    
    if margin_req is not None:
        free_margin = acc_info.margin_free
        if margin_req > free_margin * 0.8:
            calculated_lot = min_lot
            
    return round(calculated_lot, 2)

# +------------------------------------------------------------------+
# | Ambil rates dan konversi ke Pandas DataFrame                     |
# +------------------------------------------------------------------+
def get_rates(symbol, timeframe, count):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    if rates is None or len(rates) < count:
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    return df

# +------------------------------------------------------------------+
# | Kalkulasi Indikator (SMA, BB, RSI, AD, Volume)                   |
# +------------------------------------------------------------------+
def calculate_indicators(df):
    # Moving Averages
    df['ma20'] = df['close'].rolling(window=20).mean()
    df['ma50'] = df['close'].rolling(window=50).mean()
    df['ma200'] = df['close'].rolling(window=200).mean()
    
    # Bollinger Bands (ddof=1 agar sample std dev seperti MQL5/pandas default)
    df['std20'] = df['close'].rolling(window=20).std(ddof=1)
    df['bb_upper'] = df['ma20'] + (df['std20'] * 2.0)
    df['bb_lower'] = df['ma20'] - (df['std20'] * 2.0)
    
        # RSI (DIPERBAIKI: Hindari chained assignment inplace)
    delta = df['close'].diff()
    gain = delta.where(delta > 0, 0).rolling(window=14).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=14).mean()
    
    # Mengisi NaN dengan 50.0 secara langsung ke kolom df['rsi']
    df['rsi'] = (100 - (100 / (1 + gain / loss.replace(0, np.nan)))).fillna(50.0)

    
    # Accumulation/Distribution (AD)
    hl_range = (df['high'] - df['low']).replace(0, 1e-10)
    clv = ((df['close'] - df['low']) - (df['high'] - df['close'])) / hl_range
    df['ad'] = (clv * df['tick_volume']).cumsum()
    
    # Volume Average
    df['vol_avg'] = df['tick_volume'].rolling(window=20).mean()
    
    return df

# +------------------------------------------------------------------+
# | Cek trend H1                                                     |
# +------------------------------------------------------------------+
def check_h1_trend(h1_df):
    if h1_df is None or len(h1_df) < 200: return 0
    last = h1_df.iloc[-1]
    if pd.isna(last['ma50']) or pd.isna(last['ma200']): return 0
        
    if last['close'] > last['ma50'] and last['ma50'] > last['ma200']: return 1 # BULLISH
    if last['close'] < last['ma50'] and last['ma50'] < last['ma200']: return -1 # BEARISH
    return 0 # RANGING

# +------------------------------------------------------------------+
# | Hitung score entry                                               |
# +------------------------------------------------------------------+
def calculate_entry_score(m15_df, h1_df, dir):
    if m15_df is None or len(m15_df) < 60 or h1_df is None or len(h1_df) < 210: return 0
    score = 0
    
    # iloc[-1] adalah bar terbaru (shift 0), iloc[-2] adalah bar sebelumnya (shift 1)
    close0 = m15_df.iloc[-1]['close']
    ma20_0 = m15_df.iloc[-1]['ma20']
    ma50_0 = m15_df.iloc[-1]['ma50']
    bb_upper_1 = m15_df.iloc[-2]['bb_upper']
    bb_lower_1 = m15_df.iloc[-2]['bb_lower']
    prev_low = m15_df.iloc[-2]['low']
    prev_high = m15_df.iloc[-2]['high']
    
    # 1. ZONA VALUE (Max 30)
    in_ma_zone = False
    touch_bb = False
    if dir > 0:
        in_ma_zone = (ma50_0 <= close0 <= ma20_0)
        touch_bb = (prev_low <= bb_lower_1)
    else:
        in_ma_zone = (ma20_0 <= close0 <= ma50_0)
        touch_bb = (prev_high >= bb_upper_1)
    if in_ma_zone or touch_bb: score += 30
        
    # 2. MOMENTUM RSI (Max 25)
    rsi0 = m15_df.iloc[-1]['rsi']
    rsi_ok = (30.0 <= rsi0 <= 65.0) if dir > 0 else (35.0 <= rsi0 <= 70.0)
    
    divergence = False
    if dir > 0:
        min_close_prev = m15_df['close'].iloc[-10:-1].min()
        min_ad_prev = m15_df['ad'].iloc[-10:-1].min()
        divergence = (close0 < min_close_prev and m15_df.iloc[-1]['ad'] > min_ad_prev)
    else:
        max_close_prev = m15_df['close'].iloc[-10:-1].max()
        max_ad_prev = m15_df['ad'].iloc[-10:-1].max()
        divergence = (close0 > max_close_prev and m15_df.iloc[-1]['ad'] < max_ad_prev)
        
    if rsi_ok or divergence: score += 25
        
    # 3. VALIDASI VOLUME & A/D (Max 25)
    ad_slope_h1 = 0.0
    if len(h1_df) >= 6:
        diffs = h1_df['ad'].iloc[-5:].values - h1_df['ad'].iloc[-6:-1].values
        ad_slope_h1 = np.sum(diffs) / 5.0
        
    vol_confirmed = m15_df.iloc[-1]['tick_volume'] > m15_df.iloc[-1]['vol_avg']
    if (dir > 0 and ad_slope_h1 >= 0.0 and vol_confirmed) or \
       (dir < 0 and ad_slope_h1 <= 0.0 and vol_confirmed):
        score += 25
        
    # 4. CANDLE TRIGGER (Max 20)
    curr = m15_df.iloc[-1]
    range_candle = curr['high'] - curr['low'] + 1e-10
    body_ratio = abs(curr['close'] - curr['open']) / range_candle
    bullish_candle = curr['close'] > curr['open']
    
    if (dir > 0 and bullish_candle and body_ratio > 0.3) or \
       (dir < 0 and not bullish_candle and body_ratio > 0.3):
        score += 20
        
    return score

# +------------------------------------------------------------------+
# | Eksekusi Order                                                   |
# +------------------------------------------------------------------+
def execute_trade(symbol, dir, entry, sl, tp):
    tick = mt5.symbol_info_tick(symbol)
    sym_info = mt5.symbol_info(symbol)
    point = sym_info.point
    digits = sym_info.digits
    
    if not tick or point <= 0.0:
        log(f"[ERROR] {symbol}: Data tick/point tidak valid.")
        return False
        
    max_spread_points = Config.BTC_MAX_SPREAD if "BTCUSD" in symbol else Config.DEFAULT_MAX_SPREAD
    spread = tick.ask - tick.bid
    
    if spread > max_spread_points * point:
        log(f"[WARNING] {symbol}: spread sangat lebar {spread/point:.1f} points, EA tetap entry karena SL disesuaikan.")
        
    sl_distance_price = abs(entry - sl)
    lot = get_smart_lot(symbol, sl_distance_price)
    log(f"[LOT INFO] {symbol} | Modal: {mt5.account_info().balance:.2f} | Risiko: {Config.RISK_PERCENT}% | Lot: {lot}")
    
    order_type = mt5.ORDER_TYPE_BUY if dir > 0 else mt5.ORDER_TYPE_SELL
    price = tick.ask if dir > 0 else tick.bid
    
    margin_req = mt5.order_calc_margin(order_type, symbol, lot, price)
    if margin_req is None or mt5.account_info().margin_free < margin_req + Config.MARGIN_BUFFER:
        log(f"[SKIP] {symbol}: Free margin tidak mencukupi.")
        return False
        
    # Adjust stops
    stops_level = sym_info.trade_stops_level
    min_stop_distance = (stops_level * point) if stops_level > 0 else 10 * point
    if dir > 0:
        if entry - sl < min_stop_distance: sl = entry - min_stop_distance
        if tp - entry < min_stop_distance: tp = entry + min_stop_distance
    else:
        if sl - entry < min_stop_distance: sl = entry + min_stop_distance
        if entry - tp < min_stop_distance: tp = entry - min_stop_distance
        
    entry, sl, tp = round(entry, digits), round(sl, digits), round(tp, digits)
    
    # Filling mode adjustment
    filling_mode = sym_info.filling_mode
    fill_type = mt5.ORDER_FILLING_FOK
    if filling_mode == mt5.ORDER_FILLING_IOC: fill_type = mt5.ORDER_FILLING_IOC
    elif filling_mode == mt5.ORDER_FILLING_RETURN: fill_type = mt5.ORDER_FILLING_RETURN
    
    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": lot,
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": Config.SLIPPAGE,
        "magic": Config.MAGIC,
        "comment": "Confluence_BUY" if dir > 0 else "Confluence_SELL",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": fill_type,
    }
    
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        log(f"[ERROR] {symbol}: retcode={result.retcode}, comment={result.comment}")
        return False
        
    log(f"[SUCCESS] {symbol} {'BUY' if dir > 0 else 'SELL'} @ {price} | SL:{sl} TP:{tp}")
    return True

# +------------------------------------------------------------------+
# | Proses satu symbol                                               |
# +------------------------------------------------------------------+
def process_symbol(symbol, last_entry_time):
    log(f"=== {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | Cek {symbol} ===")
    
    # Cek posisi terbuka & cooldown
    positions = mt5.positions_get(symbol=symbol)
    if positions:
        for p in positions:
            if p.magic == Config.MAGIC:
                log(f"[SKIP] {symbol}: masih ada posisi terbuka.")
                return last_entry_time
                
    if time.time() - last_entry_time < Config.COOLDOWN:
        log(f"[SKIP] {symbol}: cooldown aktif.")
        return last_entry_time
        
    m15_df = get_rates(symbol, Config.TF_ENTRY, Config.BARS)
    h1_df = get_rates(symbol, Config.TF_TREND, Config.BARS)
    
    if m15_df is None or h1_df is None:
        log(f"[SKIP] {symbol}: data history tidak cukup.")
        return last_entry_time
        
    m15_df = calculate_indicators(m15_df)
    h1_df = calculate_indicators(h1_df)
    
    trend = check_h1_trend(h1_df)
    if trend == 0:
        log(f"[SKIP] {symbol}: market ranging.")
        return last_entry_time
        
    # Filter Trend M15
    last_m15 = m15_df.iloc[-1]
    m15_trend_ok = False
    if trend > 0 and last_m15['close'] > last_m15['ma20'] and last_m15['ma20'] > last_m15['ma50']: m15_trend_ok = True
    if trend < 0 and last_m15['close'] < last_m15['ma20'] and last_m15['ma20'] < last_m15['ma50']: m15_trend_ok = True
    
    if not m15_trend_ok:
        log(f"[SKIP] {symbol}: Trend M15 belum searah dengan H1.")
        return last_entry_time
        
    tick = mt5.symbol_info_tick(symbol)
    if not tick: return last_entry_time
    
    signal, score, entry = 0, 0, 0.0
    if trend > 0:
        score = calculate_entry_score(m15_df, h1_df, 1)
        log(f"Score BUY {symbol}: {score}")
        if score >= Config.ENTRY_SCORE_THRESHOLD: signal, entry = 1, tick.ask
    else:
        score = calculate_entry_score(m15_df, h1_df, -1)
        log(f"Score SELL {symbol}: {score}")
        if score >= Config.ENTRY_SCORE_THRESHOLD: signal, entry = -1, tick.bid
        
    if signal == 0:
        log(f"No signal untuk {symbol}")
        return last_entry_time
        
    # Hitung SL/TP Dinamis
    sym_info = mt5.symbol_info(symbol)
    point, digits = sym_info.point, sym_info.digits
    sl_distance = Config.BTC_SL_DISTANCE if "BTCUSD" in symbol else Config.DEFAULT_SL_DISTANCE
    stops_level = sym_info.trade_stops_level
    min_stop = (stops_level * point) if stops_level > 0 else 10 * point
    
    spread = tick.ask - tick.bid
    actual_sl_distance = max(sl_distance, spread + min_stop + 10 * point)
    
    if signal > 0:
        sl = entry - (actual_sl_distance * 11)
        tp = entry + (actual_sl_distance * 13)
    else:
        sl = entry + (actual_sl_distance * 11)
        tp = entry - (actual_sl_distance * 13)
        
    log(f"[FINAL SL/TP] {symbol} | Arah: {'BUY' if signal > 0 else 'SELL'} | Entry: {entry:.{digits}f} | Final SL: {sl:.{digits}f} | Final TP: {tp:.{digits}f}")
    
    if execute_trade(symbol, signal, entry, sl, tp):
        return time.time()
    return last_entry_time

# +------------------------------------------------------------------+
# | SMART EXIT: Tutup posisi otomatis jika trend M15 berbalik arah   |
# +------------------------------------------------------------------+
def manage_smart_exit():
    positions = mt5.positions_get()
    if not positions: return
    
    for pos in positions:
        if pos.magic != Config.MAGIC or pos.symbol not in Config.SYMBOLS: continue
        
        m15_df = get_rates(pos.symbol, Config.TF_ENTRY, 60)
        if m15_df is None or len(m15_df) < 60: continue
        
        m15_df = calculate_indicators(m15_df)
        last = m15_df.iloc[-1]
        m15_bullish = (last['close'] > last['ma20'] and last['ma20'] > last['ma50'])
        m15_bearish = (last['close'] < last['ma20'] and last['ma20'] < last['ma50'])
        
        should_close = False
        if pos.type == mt5.POSITION_TYPE_BUY and m15_bearish: should_close = True
        elif pos.type == mt5.POSITION_TYPE_SELL and m15_bullish: should_close = True
            
        if should_close:
            tick = mt5.symbol_info_tick(pos.symbol)
            close_price = tick.bid if pos.type == mt5.POSITION_TYPE_BUY else tick.ask
            close_type = mt5.ORDER_TYPE_SELL if pos.type == mt5.POSITION_TYPE_BUY else mt5.ORDER_TYPE_BUY
            
            request = {
                "action": mt5.TRADE_ACTION_DEAL, "symbol": pos.symbol, "volume": pos.volume,
                "type": close_type, "position": pos.ticket, "price": close_price,
                "deviation": Config.SLIPPAGE, "magic": Config.MAGIC, "comment": "Smart Exit",
                "type_time": mt5.ORDER_TIME_GTC, "type_filling": mt5.ORDER_FILLING_FOK,
            }
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                log(f"[SMART EXIT] {pos.symbol} | Posisi ditutup karena trend M15 berbalik. Profit: {pos.profit:.2f}")

# +------------------------------------------------------------------+
# | Run periodic checks                                              |
# +------------------------------------------------------------------+
def run_checks(last_entry_times):
    # Cek Daily Loss
    today = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0)
    deals = mt5.history_deals_get(today, datetime.now())
    daily_loss = sum(abs(d.profit) for d in deals if d.magic == Config.MAGIC and d.profit < 0) if deals else 0.0
    
    if daily_loss >= Config.MAX_DAILY_LOSS:
        log(f"DAILY LOSS LIMIT: {daily_loss:.2f}. Bot istirahat.")
        return last_entry_times
        
    manage_smart_exit()
    
    for i, symbol in enumerate(Config.SYMBOLS):
        last_entry_times[i] = process_symbol(symbol, last_entry_times[i])
    return last_entry_times

# +------------------------------------------------------------------+
# | Main Loop                                                        |
# +------------------------------------------------------------------+
def main():
    if not mt5.initialize():
        print("initialize() failed, error code =", mt5.last_error())
        return
        
    Config.SYMBOLS = parse_symbols(Config.SYMBOLS_STR)
    last_entry_times = [0.0] * len(Config.SYMBOLS)
    
    for symbol in Config.SYMBOLS:
        mt5.symbol_select(symbol, True)
        
    if not diagnose_account():
        mt5.shutdown()
        return
        
    log("Bot running...")
    log(f"Symbols: {Config.SYMBOLS}")
    log(f"Interval cek: {Config.CHECK_INTERVAL} detik")
    
    try:
        while True:
            last_entry_times = run_checks(last_entry_times)
            time.sleep(Config.CHECK_INTERVAL)
    except KeyboardInterrupt:
        log("Bot stopped by user.")
    finally:
        mt5.shutdown()

if __name__ == "__main__":
    main()