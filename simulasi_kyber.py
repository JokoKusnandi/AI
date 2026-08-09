# 1. Impor objek parameter Kyber512 yang sudah matang dari library
from kyber_py.kyber import Kyber512

# 2. Pembuatan Kunci (Public Key & Secret Key)
public_key, secret_key = Kyber512.keygen()

# 3. Enkapsulasi / Enkripsi (Menghasilkan Shared Secret dan Ciphertext)
# CATATAN: Fungsi .encaps() mengembalikan (shared_secret, ciphertext) 
shared_secret_sender, ciphertext = Kyber512.encaps(public_key)

# 4. Dekapsulasi / Dekripsi (Memulihkan Shared Secret)
# URUTAN: Kyber512.decaps(secret_key, ciphertext)
shared_secret_receiver = Kyber512.decaps(secret_key, ciphertext)

# 5. Verifikasi Hasil Akhir
assert shared_secret_sender == shared_secret_receiver
print("Kyber ML-KEM Berhasil! Shared secret cocok.")
print(f"Shared Secret (Hex): {shared_secret_sender.hex()[:32]}...")
