import math

def crack_rsa_small(n):
    """
    Hanya berfungsi untuk angka N yang sangat kecil (contoh pembelajaran).
    Tidak akan pernah berhasil untuk RSA-2048.
    """
    print(f"Mencoba memfaktorkan N = {n}...")
    
    # Metode Brute Force sederhana (hanya untuk demo)
    for i in range(2, int(math.sqrt(n)) + 1):
        if n % i == 0:
            p = i
            q = n // i
            print(f"SUAKSES! Faktor primanya adalah: p={p}, q={q}")
            return p, q
            
    print("Gagal menemukan faktor.")
    return None

# Contoh dengan angka kecil
crack_rsa_small(3233) # 3233 = 53 * 61