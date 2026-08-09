# 1. Impor objek parameter Dilithium2 dari top-level package
from dilithium_py.dilithium import Dilithium2

# 2. Generate Kunci
public_key, secret_key = Dilithium2.keygen()

# 3. Tanda Tangan Digital
message = b"Halo Dunia Kuantum!"
signature = Dilithium2.sign(secret_key, message)

# 4. Verifikasi Tanda Tangan
is_valid = Dilithium2.verify(public_key, message, signature)

if is_valid:
    print("Dilithium ML-DSA Berhasil! Tanda tangan valid.")
    print(f"Panjang Tanda Tangan: {len(signature)} bytes")
else:
    print("Verifikasi gagal.")
