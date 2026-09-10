mengecek apakah versi package Python yang terinstal di sistem Anda sudah sesuai dengan daftar requirements :
Cara 1: Cek via Terminal (Command Line) - Paling Cepat
1. Mengecek satu per satu:
Gunakan perintah pip show diikuti nama package.
bash/cmd
```text
pip show MetaTrader5
pip show numpy
pip show tensorflow
```

2. Mengecek semua package yang terinstal sekaligus:
Gunakan pip freeze atau pip list, lalu cari (grep) package yang Anda butuhkan.
bash/cmd
```text
# Di Linux / Mac / Docker
pip freeze | grep -iE "MetaTrader5|numpy|pandas|ta|scikit-learn|xgboost|tensorflow|lightgbm|torch|transformers|sqlalchemy|python-dotenv|requests|schedule|joblib|matplotlib|scipy|aiohttp|loguru|opencv-python|pillow|pytest"
```

Pastikan Python Sudah Terinstal :
Buka Command Prompt (CMD) atau PowerShell, lalu ketik:
```text
python --version 
```
atau
```text
py --version 
```

Membuat Virtual Environment :
1. Buka Terminal di Folder Project
Misalkan project Anda ada di C:\ai\mt5-python-bot
 Via Command Prompt
 ```text
 cd C:\ai\mt5-python-bot
 ```
 2. Buat Virtual Environment
 Jalankan perintah ini di terminal cmd:
 ```text
 python -m venv venv atau py -m venv venv
 ```
 Tunggu beberapa detik. Akan muncul folder baru bernama venv di dalam folder project Anda.
3. Mengaktifkan Virtual Environment
Anda harus mengaktifkan venv setiap kali membuka terminal baru.
```text
cmd

venv\Scripts\activate
```
4. Verifikasi Aktivasi
Setelah aktif, Anda akan melihat (venv) di awal prompt terminal:
```text
(venv) C:\Users\joko_\Documents\ai\mt5-python-bot>
```
Cek Python yang aktif sekarang:
```text
python --version atau py --version
where python
```
Upgrade pip dulu
```text
cmd
python -m pip install --upgrade pip setuptools wheel
```
Install dari requirements.txt
```text
pip install -r requirements.txt 
atau 
py -m pip install -r requirements.txt
```

Cara Menonaktifkan Virtual Environment
Jika ingin kembali ke Python global:
```text
deactivate
```


| Aksi | Perintah (CMD) |
|------|----------------|
|Buat venv | python -m venv venv atau py -m venv venv |
| Aktifkan | venv\Scripts\activate |
| Nonaktifkan | deactivate | 
| Install requirements | pip install -r requirements.txt |
| Cek yang terinstal | pip list | 
| Freeze ke file | pip freeze > requirements.txt |