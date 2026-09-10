import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from datetime import datetime

# --- KONFIGURASI MODAL $30 & PARAMETER INDIKATOR ---
SYMBOL = "XAUUSD.vx"
LOT_SIZE = 0.01
MAX_DAILY_LOSS = 15.0
MAX_SPREAD_POINTS = 20
RISK_PER_TRADE_USD = 3.0
ENTRY_SCORE_THRESHOLD = 70  # Minimal skor untuk entry

def get_rates(symbol, timeframe, count=300):
    """Helper ambil data rates MT5"""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, count)
    return pd.DataFrame(rates) if rates is not None else pd.DataFrame()

def calculate_all_indicators(df):
    """Hitung semua indikator dalam satu pass"""
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

def check_h1_trend_alignment(df_h1):
    """Cek alignment MA di H1"""
    last = df_h1.iloc[-1]
    if last['ma20'] > last['ma50'] > last['ma100'] > last['ma200']:
        return "BULLISH"
    elif last['ma20'] < last['ma50'] < last['ma100'] < last['ma200']:
        return "BEARISH"
    return "RANGING"

def calculate_entry_score(df_m15, df_h1, direction):
    """Sistem scoring konfluensi multi-indikator"""
    score = 0
    last = df_m15.iloc[-1]
    prev = df_m15.iloc[-2]
    h1_last = df_h1.iloc[-1]
    
    # 1. ZONA VALUE (Max 30)
    in_ma_zone = (last['ma50'] <= last['close'] <= last['ma20']) if direction == "BUY" \
                 else (last['ma20'] <= last['close'] <= last['ma50'])
    touch_bb = (prev['low'] <= prev['bb_lower']) if direction == "BUY" \
               else (prev['high'] >= prev['bb_upper'])
    if in_ma_zone or touch_bb:
        score += 30
    
    # 2. MOMENTUM RSI (Max 25)
    rsi_ok = (40 <= last['rsi'] <= 50) if direction == "BUY" else (50 <= last['rsi'] <= 60)
    # Simplified divergence check
    div_bullish = (last['close'] < df_m15['close'].iloc[-10:].min() and 
                   last['ad_line'] > df_m15['ad_line'].iloc[-10:].min())
    div_bearish = (last['close'] > df_m15['close'].iloc[-10:].max() and 
                   last['ad_line'] < df_m15['ad_line'].iloc[-10:].max())
    
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

def execute_trade(direction, entry_price, sl, tp):
    """Eksekusi order dengan validasi lengkap"""
    tick = mt5.symbol_info_tick(SYMBOL)
    point = mt5.symbol_info(SYMBOL).point
    
    # Validasi Spread
    if (tick.ask - tick.bid) > MAX_SPREAD_POINTS * point:
        print(f"[SKIP] Spread lebar: {(tick.ask-tick.bid)/point:.1f} pts")
        return False
    
    # Validasi Margin
    margin_req = mt5.order_calc_margin(
        mt5.ORDER_TYPE_BUY if direction=="BUY" else mt5.ORDER_TYPE_SELL,
        SYMBOL, LOT_SIZE, entry_price
    )
    account = mt5.account_info()
    if account.margin_free < margin_req + 15:
        print(f"[SKIP] Free margin kurang: ${account.margin_free:.2f}")
        return False

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": SYMBOL,
        "volume": LOT_SIZE,
        "type": mt5.ORDER_TYPE_BUY if direction=="BUY" else mt5.ORDER_TYPE_SELL,
        "price": entry_price,
        "sl": round(sl, 2),
        "tp": round(tp, 2),
        "deviation": 20,
        "magic": 20260803,
        "comment": f"Confluence_{direction}",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    
    result = mt5.order_send(request)
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"[ERROR] {result.comment}")
        return False
    print(f"[SUCCESS] {direction} @ {entry_price} | SL:{sl} TP:{tp}")
    return True

def main_logic():
    if not mt5.initialize():
        print("Gagal connect MT5"); return

    # Ambil & proses data
    df_m15 = calculate_all_indicators(get_rates(SYMBOL, mt5.TIMEFRAME_M15))
    df_h1 = calculate_all_indicators(get_rates(SYMBOL, mt5.TIMEFRAME_H1))
    
    if df_m15.empty or df_h1.empty:
        print("Data tidak cukup"); mt5.shutdown(); return

    # Cek Daily Loss
    history = mt5.history_deals_get(datetime.today().replace(hour=0))
    daily_loss = sum(d.profit for d in history if d.profit < 0) if history else 0
    if abs(daily_loss) >= MAX_DAILY_LOSS:
        print(f"DAILY LOSS LIMIT: ${abs(daily_loss)}"); mt5.shutdown(); return

    # Tentukan Bias Tren H1
    trend = check_h1_trend_alignment(df_h1)
    if trend == "RANGING":
        print("Market ranging, bot istirahat."); mt5.shutdown(); return

    # Evaluasi Scoring
    current_ask = mt5.symbol_info_tick(SYMBOL).ask
    current_bid = mt5.symbol_info_tick(SYMBOL).bid
    
    signal_dir = None
    if trend == "BULLISH":
        score = calculate_entry_score(df_m15, df_h1, "BUY")
        if score >= ENTRY_SCORE_THRESHOLD:
            signal_dir = "BUY"
            entry = current_ask
    elif trend == "BEARISH":
        score = calculate_entry_score(df_m15, df_h1, "SELL")
        if score >= ENTRY_SCORE_THRESHOLD:
            signal_dir = "SELL"
            entry = current_bid
            
    if signal_dir:
        sl_dist = RISK_PER_TRADE_USD
        sl = entry - sl_dist if signal_dir == "BUY" else entry + sl_dist
        tp = entry + (sl_dist * 1.5) if signal_dir == "BUY" else entry - (sl_dist * 1.5)
        execute_trade(signal_dir, entry, sl, tp)
    else:
        print(f"No signal (Score threshold {ENTRY_SCORE_THRESHOLD} not met)")
        
    mt5.shutdown()

if __name__ == "__main__":
    main_logic()
